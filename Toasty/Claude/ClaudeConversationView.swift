import AppKit
import SwiftUI

/// A Claude Code conversation: the transcript and the composer at one
/// shared width, with prompts that need an answer above the composer. No
/// header bar: the tab row above is the only chrome.
struct ClaudeConversationView: View {
    @ObservedObject var conversation: ClaudeConversation
    var onRunInTerminal: (String) -> Void
    @State private var dropTargeted = false

    var body: some View {
        // The transcript scrolls under the composer and fades out above it.
        ClaudeTranscript(conversation: conversation, onRunInTerminal: onRunInTerminal)
            // And fades out under the tab row, as it does above the composer:
            // clipped to its own top edge (a scroll view otherwise draws up
            // into the safe area, past the fade) with the fade on that edge.
            .clipped()
            .overlay(alignment: .top) { HeaderFade() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ClaudeBottomArea(conversation: conversation)
                    .background(alignment: .top) { ComposerFade() }
            }
            .background(Color.claudeBackground)
            // Files dropped anywhere on the conversation are attached.
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadFileURLs(providers) { conversation.attach($0) }
                return true
            }
            .overlay { if dropTargeted || conversation.filesOverComposer { DropTargetOverlay() } }
        .onAppear { conversation.focusComposer() }
        // Esc anywhere in the conversation: deny a pending prompt or
        // interrupt, like the CLI.
        .onExitCommand {
            if let r = conversation.requests.first {
                conversation.respond(to: r, ["behavior": "deny", "message": "The user rejected this.", "interrupt": true])
            } else {
                conversation.interrupt()
            }
        }
    }
}

// MARK: - Transcript

private enum TranscriptRow: Identifiable {
    case item(ClaudeItem)
    /// Consecutive tool calls, shown together as one block of activity.
    case tools([ClaudeItem])

    var id: String {
        switch self {
        case .item(let i): i.id
        case .tools(let t): "tools-" + (t.first?.id ?? "")
        }
    }

    /// The same items (a run of tools grows as tools are added).
    func same(as other: TranscriptRow) -> Bool {
        switch (self, other) {
        case (.item(let a), .item(let b)): a === b
        case (.tools(let a), .tools(let b)): a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
        default: false
        }
    }

    var first: ClaudeItem? {
        switch self {
        case .item(let i): i
        case .tools(let t): t.first
        }
    }
}

struct ClaudeTranscript: View {
    @ObservedObject var conversation: ClaudeConversation
    var onRunInTerminal: (String) -> Void

    /// Only the most recent rows are laid out; earlier ones on request.
    @State private var limit = Self.initialLimit
    private static let initialLimit = 160
    /// The view is scrolled to (near) the end.
    @State private var atBottom = true
    /// Follow new output, like a terminal: on while at the bottom, off once
    /// the user scrolls up, back on when they return to the bottom.
    @State private var following = true
    /// The user is scrolling (trackpad, wheel, scroller): only that turns
    /// following off. Layout changes (the working line going away, the
    /// reply's actions appearing) never do.
    @State private var userScrolling = false
    /// Any wheel/trackpad scroll in the window, phase or not (a plain mouse
    /// wheel reports no scroll phase).
    private var isUserScrolling: Bool { userScrolling || WheelWatcher.shared.recentlyScrolled }
    /// A reply briefly highlighted after it was brought into view.
    @State private var highlighted: String?

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var atBottom: Bool
    }

    var body: some View {
        let all = rows
        let latestReply = latestReplyID
        let hidden = max(0, all.count - limit)
        let shown = Array(all.suffix(limit))

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let origin = conversation.forkOrigin {
                        ForkedFromLine(origin: origin)
                            .padding(.bottom, 28)
                    }
                    if conversation.items.isEmpty {
                        ClaudeEmptyState(conversation: conversation)
                    }
                    if hidden > 0 {
                        Button("Show \(hidden) Earlier") { limit += Self.initialLimit }
                            .buttonStyle(.link)
                            .font(.toasty(Theme.Size.meta))
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 20)
                    }
                    TranscriptRows(rows: shown, latestReply: latestReply, highlighted: highlighted,
                                   forkable: forkable(shown), conversation: conversation,
                                   onRun: onRunInTerminal)
                        .equatable()
                    // The end marker carries the space below the last message,
                    // so scrolling to it lands on the very end.
                    Color.clear.frame(height: 40).id("bottom")
                }
                // Exactly the composer's width and edges.
                .frame(maxWidth: ClaudeTypography.composerWidth, alignment: .leading)
                .padding(.horizontal, ClaudeStyle.horizontalPadding - 12)
                // Below the header's fade, so nothing is faded at rest.
                .padding(.top, HeaderFade.height + 4)
                .frame(maxWidth: .infinity)
            }
            .modifier(PinToBottom())
            .onScrollGeometryChange(for: ScrollState.self) { g in
                // The bottom of what's visible above the composer (the
                // bottom inset) against the end of the content.
                ScrollState(offset: g.contentOffset.y, contentHeight: g.contentSize.height,
                            atBottom: g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 60)
            } action: { old, new in
                if isUserScrolling, new.offset != old.offset {
                    // The user scrolled: follow only from the bottom.
                    following = new.atBottom
                } else if following, !new.atBottom, !isUserScrolling {
                    // Output grew or the layout changed while following:
                    // stay at the end.
                    proxy.scrollTo("bottom", anchor: .bottom)
                    return
                }
                if new.atBottom != atBottom { withAnimation(.easeOut(duration: 0.15)) { atBottom = new.atBottom } }
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: userScrolling = true
                default: userScrolling = false
                }
            }
            // A turn finishing changes the layout below the transcript
            // after the last output: land on the very end.
            .onChange(of: conversation.phase) { _, _ in
                guard following else { return }
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if following { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    JumpToLatestButton {
                        following = true
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onChange(of: all.count) { old, new in
                // Reading further up: new rows grow the laid out window
                // rather than slide it, so what's on screen stays put.
                if !following, new > old, conversation.items.last?.startsTurn != true { limit += new - old }
            }
            .onChange(of: conversation.items.count) { _, _ in
                // A new message: follow it, unless the user is reading
                // further up (a prompt they just sent always shows).
                guard following || conversation.items.last?.startsTurn == true else { return }
                if !following { limit = Self.initialLimit }
                following = true
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // A request card above the composer shortens the transcript:
            // keep the latest message in view.
            .onChange(of: conversation.requests.count) { _, _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    if conversation.revealItemID != nil { reveal(proxy) } else { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: conversation.revealItemID) { _, id in
                if id != nil { DispatchQueue.main.async { reveal(proxy) } }
            }
        }
    }

    /// Scroll to the reply the conversation asks to show, and highlight it.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = conversation.revealItemID else { return }
        conversation.revealItemID = nil
        let all = rows
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        // Lay out far enough back to include it.
        limit = max(limit, all.count - index)
        following = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            highlighted = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if highlighted == id { highlighted = nil }
            }
        }
    }

    /// Replies that can be forked (Claude Code's id for the reply and a
    /// saved session).
    private func forkable(_ rows: [TranscriptRow]) -> [String] {
        guard conversation.sessionID != nil, conversation.workspace != nil else { return [] }
        return rows.compactMap {
            guard case .item(let i) = $0, i.endsTurn, i.entryUUID != nil else { return nil }
            return i.id
        }
    }

    /// The latest turn's reply keeps its actions visible (others on hover).
    private var latestReplyID: String? {
        conversation.phase == .idle ? conversation.items.last { $0.endsTurn }?.id : nil
    }

    private var rows: [TranscriptRow] {
        var out: [TranscriptRow] = []
        var run: [ClaudeItem] = []
        func flush() {
            if !run.isEmpty { out.append(.tools(run)); run = [] }
        }
        for item in conversation.items {
            switch item.kind {
            case .tool where item.toolName == "ExitPlanMode":
                // A plan gets its own row, not a tool line.
                flush()
                out.append(.item(item))
            case .tool:
                run.append(item)
            case .thinking where item.text.isEmpty:
                // Nothing to show without visible thinking (while it runs,
                // the working line says "Thinking…").
                continue
            case .error, .warning, .notice:
                flush()
                // The same note or error again, right after itself (a
                // resume that fails the same way each time): shown once.
                if case .item(let last)? = out.last, last.kind == item.kind, last.text == item.text { continue }
                out.append(.item(item))
            default:
                flush()
                out.append(.item(item))
            }
        }
        flush()
        return out
    }
}

/// The transcript's rows. Redrawn only when they change, not whenever the
/// conversation does (typing a prompt, status and usage updates, focus).
private struct TranscriptRows: View, Equatable {
    let rows: [TranscriptRow]
    let latestReply: String?
    let highlighted: String?
    let forkable: [String]
    /// Not observed: the rows are what's shown.
    let conversation: ClaudeConversation
    let onRun: (String) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.conversation === b.conversation && a.latestReply == b.latestReply
            && a.highlighted == b.highlighted && a.forkable == b.forkable
            && a.rows.elementsEqual(b.rows) { $0.same(as: $1) }
    }

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
            // Tool lines and thoughts sit at the reply's left edge.
            rowView(row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, i == 0 ? 0 : spacing(before: row, after: rows[i - 1]))
        }
    }

    private func spacing(before row: TranscriptRow, after previous: TranscriptRow) -> CGFloat {
        if row.first?.startsTurn == true { return Theme.Space.xxl }
        return Theme.Space.l
    }

    private func forkAction(_ item: ClaudeItem) -> ((Bool) -> Void)? {
        guard forkable.contains(item.id), let workspace = conversation.workspace else { return nil }
        return { [weak conversation] background in
            guard let conversation else { return }
            workspace.fork(conversation, at: item, select: !background)
        }
    }

    @ViewBuilder private func rowView(_ row: TranscriptRow) -> some View {
        switch row {
        case .tools(let items):
            ClaudeToolGroup(items: items, cwd: conversation.cwd)
        case .item(let item):
            ClaudeItemView(item: item, cwd: conversation.cwd, onRun: onRun,
                           latest: item.id == latestReply, onFork: forkAction(item))
                .background {
                    RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(highlighted == item.id ? 0.1 : 0))
                        .padding(.horizontal, -12)
                        .padding(.vertical, -8)
                        .animation(.easeOut(duration: 0.6), value: highlighted)
                }
        }
    }
}

/// At the top of a forked conversation: where it came from. Click to go
/// to the reply it was forked from (when that conversation is open).
struct ForkedFromLine: View {
    let origin: ClaudeConversation.ForkOrigin
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var hovering = false

    private var source: ClaudeConversation? { Workspace.conversation(withSession: origin.sessionID) }

    var body: some View {
        let source = source
        let name = source?.title ?? origin.savedTitle ?? "another conversation"
        Button {
            guard let source, let workspace = source.workspace else { return }
            // The fork point, or the latest earlier message that is shown.
            let target = origin.messageUUIDs.reversed().lazy.compactMap { source.item(forEntry: $0) }.first
            source.revealItemID = target?.id
            WorkspaceStore.shared.activate(workspace.id)
            workspace.select(source)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.toasty(Theme.Size.caption, .medium))
                (Text("Forked from ") + Text(name).fontWeight(.medium).foregroundStyle(hovering && source != nil ? .primary : .secondary))
                    .font(.toasty(Theme.Size.meta))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(source != nil)
        .onHover { hovering = $0 }
        .tooltip("Forked From", detail: "Go to the reply this was forked from.")
        .frame(maxWidth: .infinity)
    }
}

/// A message from another Claude Code session: one quiet line with the
/// sender and the message's first line (like the CLI's "Message from
/// @name: …"); click to read all of it.
struct ClaudePeerMessage: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    @State private var expanded = false

    private var firstLine: String {
        item.text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClaudeDisclosureLine(expanded: $expanded) {
                HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                    Image(systemName: "bubble.left")
                    Text("Message from @\(item.sender ?? "another session")").fontWeight(.medium)
                    if !expanded, !firstLine.isEmpty { Text("· " + firstLine) }
                }
            }
            .tooltip("From Another Session", detail: "A message from another Claude Code session.")
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(ClaudeMarkdown.blocks(item.text, style: .init(cwd: cwd)).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let s): ClaudeRichText(text: s)
                        case .code(let l, let c): ClaudeCodeBlock(language: l, code: c)
                        case .table(let s): ClaudeTableBlock(text: s)
                        case .rule: Divider()
                        }
                    }
                }
                .claudeTranscriptCard()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A plan Claude presented (ExitPlanMode): one quiet line with what
/// happened to it and its title; click to read the whole plan.
struct ClaudePlanRow: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    @State private var expanded = false

    private var plan: String { item.input["plan"] as? String ?? "" }

    /// The plan's first heading, else its first line.
    private var title: String {
        let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.first { $0.hasPrefix("#") } ?? lines.first ?? ""
        return line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
    }

    private var status: (text: String, symbol: String, color: Color) {
        guard let result = item.result else {
            return ("Plan ready for review", "list.bullet.clipboard", Color(nsColor: .systemOrange))
        }
        if !item.resultIsError { return ("Plan approved", "checkmark.circle.fill", Color(nsColor: .systemGreen)) }
        return (result == "You rejected this." ? "Plan rejected" : "Kept planning", "xmark.circle", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClaudeDisclosureLine(expanded: $expanded) {
                HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                    Text(status.text).fontWeight(.medium)
                    if !title.isEmpty { Text("· " + title) }
                }
            }
            .disabled(plan.isEmpty)
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(ClaudeMarkdown.blocks(plan, style: .init(cwd: cwd)).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let s): ClaudeRichText(text: s)
                        case .code(let l, let c): ClaudeCodeBlock(language: l, code: c)
                        case .table(let s): ClaudeTableBlock(text: s)
                        case .rule: Divider()
                        }
                    }
                }
                .claudeTranscriptCard()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// While Claude works, the CLI's spinner line: what it's doing, for how
/// long, and how many tokens it has written ("✻ Thinking… · 23s · ↓ 1.4k
/// tokens · esc to interrupt").
struct ClaudeWorkingLine: View {
    @ObservedObject var conversation: ClaudeConversation
    @ObservedObject var activity: ClaudeTurnActivity

    /// The CLI's spinner glyphs, out and back.
    private static let frames = Array("·✢✳✶✻✽✻✶✳✢")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            HStack(spacing: 7) {
                Text(String(Self.frames[tick % Self.frames.count]))
                    .font(.toasty(Theme.Size.control, .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .frame(width: 14)
                Text(verb)
                    .font(.toasty(Theme.Size.control, .medium))
                    .foregroundStyle(.secondary)
                Text(details(now: context.date))
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude is working")
    }

    private var verb: String {
        if let status = conversation.status { return status }
        switch activity.step {
        case .thinking: return "Thinking…"
        case .writing: return "Writing…"
        case .working: return "Working…"
        }
    }

    private func details(now: Date) -> String {
        var parts: [String] = []
        if let started = conversation.turnStarted {
            parts.append(ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(started)))))
        }
        if activity.outputTokens > 0 {
            let n = activity.outputTokens
            parts.append("↓ \(n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)") tokens")
        }
        let background = conversation.backgroundTasks.count
        if background > 0 { parts.append("\(background) in background") }
        parts.append("esc to interrupt")
        return parts.joined(separator: " · ")
    }
}

/// Notes when the user last scrolled by hand (wheel or trackpad, dragging
/// a scroller, Page Up/Down, Home/End), so the transcript knows the user,
/// not a layout change, moved it.
@MainActor
final class WheelWatcher {
    static let shared = WheelWatcher()
    private var monitor: Any?
    private var last = Date.distantPast

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .keyDown]) { [weak self] event in
            switch event.type {
            case .scrollWheel, .leftMouseDragged:
                self?.last = Date()
            case .keyDown where [116, 121, 115, 119].contains(event.keyCode): // page up/down, home, end
                self?.last = Date()
            default:
                break
            }
            return event
        }
    }

    var recentlyScrolled: Bool { Date().timeIntervalSince(last) < 0.5 }
    var lastScroll: Date { last }

    /// Debug: treat the next moment as a user scroll.
    func markUserScroll() { last = Date() }
}

/// Keeps the transcript scrolled to the bottom while it grows (streaming),
/// unless the user scrolled up.
private struct PinToBottom: ViewModifier {
    func body(content: Content) -> some View {
        content.defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

// MARK: - Items

struct ClaudeItemView: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    var onRun: (String) -> Void
    var latest = false
    /// Fork the conversation at this reply (true: in a background tab).
    var onFork: ((Bool) -> Void)?

    var body: some View {
        switch item.kind {
        case .user: ClaudeUserMessage(item: item)
        case .assistant: ClaudeAssistantMessage(item: item, cwd: cwd, onRun: onRun, latest: latest, onFork: onFork)
        case .thinking: ClaudeThinking(item: item)
        case .peer: ClaudePeerMessage(item: item, cwd: cwd)
        case .tool where item.toolName == "ExitPlanMode": ClaudePlanRow(item: item, cwd: cwd)
        case .tool: ClaudeToolGroup(items: [item], cwd: cwd)
        case .notice:
            Text(item.text)
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        case .error, .warning:
            // The icon is centered on the first line (the text is an AppKit
            // view, so SwiftUI can't align them by baseline). A warning is
            // the same card in orange: Claude Code carried on.
            let tint = Color(nsColor: item.kind == .error ? .systemRed : .systemOrange)
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(tint)
                    .frame(height: Theme.Size.control * 1.5)
                ClaudeRichText(text: ClaudeMarkdown.inline(item.text, font: .systemFont(ofSize: Theme.Size.control), style: .init(cwd: cwd)))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + Theme.Space.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(tint.opacity(0.08)))
        }
    }
}

/// The user's prompt: a soft bubble on the trailing side, sized to its text.
struct ClaudeUserMessage: View {
    @ObservedObject var item: ClaudeItem

    var body: some View {
        HStack {
            Spacer(minLength: 72)
            VStack(alignment: .trailing, spacing: 8) {
                if !item.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(item.images.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        }
                    }
                }
                if !item.files.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(item.files, id: \.self) { AttachedFileChip(url: $0) }
                    }
                }
                if !item.text.isEmpty {
                    ClaudeRichText(text: Self.attributed(item.text), hugs: true)
                        // Solid blue with white text (as the Claude app's),
                        // Things' card corners: yours at a glance.
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s + Theme.Space.xxs)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.message, style: .continuous)
                            .fill(Theme.bubbleBlue))
                }
            }
        }
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let font = ClaudeTypography.body
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: 1, alpha: 0.95),
            .paragraphStyle: ClaudeTypography.paragraphStyle(font: font, multiple: ClaudeTypography.inputLineHeightMultiple),
            .baselineOffset: ClaudeTypography.baselineOffset(font, ClaudeTypography.inputLineHeightMultiple),
        ])
    }
}

struct ClaudeAssistantMessage: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    var onRun: (String) -> Void
    var latest = false
    var onFork: ((Bool) -> Void)?
    @State private var hovering = false

    var body: some View {
        let blocks = ClaudeMarkdown.blocks(item.text, style: .init(cwd: cwd))
        // Between blocks: the same rhythm as between paragraphs (a full
        // line, less the half-leading the text views already include).
        VStack(alignment: .leading, spacing: ClaudeTypography.paragraphGap - 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s): ClaudeRichText(text: s)
                case .code(let lang, let code): ClaudeCodeBlock(language: lang, code: code, onRun: onRun)
                case .table(let s): ClaudeTableBlock(text: s)
                case .rule: Rectangle().fill(Color(nsColor: ClaudeTypography.rule)).frame(height: 1).padding(.vertical, 6)
                }
            }
            if item.endsTurn {
                ClaudeReplyActions(item: item, onFork: onFork)
                    .padding(.top, -4)
                    // Always there, so hovering never shifts the transcript.
                    .opacity(latest || hovering ? 1 : 0)
                    .allowsHitTesting(latest || hovering)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }
}

/// Under a turn's last reply, like Claude: Copy (the whole response) and
/// when it was written ("2 minutes ago"; the exact time and how long the
/// turn took on hover).
struct ClaudeReplyActions: View {
    @ObservedObject var item: ClaudeItem
    var onFork: ((Bool) -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            ReplyActionButton(symbol: copied ? "checkmark" : "square.on.square",
                              tooltip: Tooltip(title: copied ? "Copied" : "Copy Response",
                                               detail: "Everything Claude wrote this turn, as Markdown.")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.turnText.isEmpty ? item.text : item.turnText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            if let onFork {
                // ⌘-click opens the fork without switching to it, like a link.
                ReplyActionButton(symbol: "arrow.triangle.branch",
                                  tooltip: Tooltip(title: "Fork from Here",
                                                   detail: "A new tab that goes on from this reply. ⌘-click to open it behind this one.")) {
                    onFork((NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command))
                }
            }
            if let date = item.finishedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.relative(date, now: context.date))
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.leading, 4)
                .tooltipText(detail(date))
            }
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: now)
    }

    private func detail(_ date: Date) -> String {
        let time = date.formatted(Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
        guard let secs = item.turnDuration else { return time }
        return "\(time) · worked for \(ClaudeToolInfo.duration(secs))"
    }
}

private struct ReplyActionButton: View {
    let symbol: String
    let tooltip: Tooltip
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.control))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .frame(width: 28, height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .tooltip(tooltip)
        .accessibilityLabel(tooltip.title)
        // The glyph, not its capsule, sits on the reply's edge.
        .padding(.leading, -7)
    }
}

struct ClaudeThinking: View {
    @ObservedObject var item: ClaudeItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClaudeDisclosureLine(expanded: $expanded, running: !item.finalized) {
                Text(item.finalized ? "Thought" : "Thinking")
            }
            if expanded, !item.text.isEmpty {
                ClaudeRichText(text: {
                    let s = NSMutableAttributedString()
                    for case .text(let t) in ClaudeMarkdown.blocks(item.text) {
                        if s.length > 0 { s.append(NSAttributedString(string: "\n")) }
                        s.append(t)
                    }
                    s.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: s.length))
                    return s
                }())
                .padding(.leading, Theme.Space.m)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.claudeSeparator).frame(width: 2)
                }
                .padding(.leading, Theme.Space.xs + 1)
            }
        }
    }
}

struct ClaudeEmptyState: View {
    @ObservedObject var conversation: ClaudeConversation

    /// A new worktree's ignored files: "Copied .env, .env.local and 2 more".
    static func copiedLine(_ files: [String]) -> String {
        let shown = files.prefix(3).joined(separator: ", ")
        let more = files.count - 3
        return more > 0 ? "Copied \(shown) and \(more) more" : "Copied \(shown)"
    }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            // As Things' empty lists: the icon large and faint; the name and
            // place quiet beneath it.
            Image(systemName: "sparkle")
                .font(.toasty(Theme.Glyph.emptyState, .ultraLight))
                .foregroundStyle(.quaternary)
                .padding(.bottom, Theme.Space.m)
            Text(conversation.projectName)
                .font(.toasty(Theme.Size.title, .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text((conversation.cwd as NSString).abbreviatingWithTildeInPath)
                if let branch = conversation.branch {
                    Text("·")
                    Image(systemName: "arrow.triangle.branch").font(.toasty(Theme.Size.caption))
                    Text(branch)
                }
            }
            .font(.toasty(Theme.Size.meta))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            if let copied = conversation.workspace?.copiedFiles, !copied.isEmpty {
                Text(Self.copiedLine(copied))
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .tooltipText(copied.joined(separator: "\n"))
            }
            if let changes = conversation.workspace?.changes {
                RemoteNotice(changes: changes, conversation: conversation)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// On a new tab, before the first prompt: the remote has commits this
/// branch doesn't (checked in the background as the tab opens; see
/// `GitChanges.checkRemote`). The button writes the prompt and leaves
/// sending it to the user.
private struct RemoteNotice: View {
    @ObservedObject var changes: GitChanges
    @ObservedObject var conversation: ClaudeConversation

    /// What's new and where, and whether taking it is a plain pull.
    private var news: (count: Int, ref: String, pull: Bool)? {
        // Only for the branch this tab is on.
        guard changes.state == .loaded, let branch = changes.branch, branch == conversation.branch else { return nil }
        if changes.behind > 0, let upstream = changes.upstream {
            return (changes.behind, upstream, changes.ahead == 0)
        }
        if changes.behindBase > 0, let base = changes.base { return (changes.behindBase, base, false) }
        return nil
    }

    var body: some View {
        if let news {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.toasty(Theme.Glyph.small, .semibold))
                    Text("\(news.count == 1 ? "1 new commit" : "\(news.count) new commits") on \(news.ref)")
                        .monospacedDigit()
                }
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                Button(news.pull ? "Ask Claude to Pull" : "Ask Claude to Rebase") {
                    conversation.draft = news.pull
                        ? "Pull the latest commits from \(news.ref)."
                        : "Rebase this branch onto \(news.ref)."
                    conversation.focusComposer()
                }
                .controlSize(.small)
                .disabled(!conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 6)
            .transition(.opacity)
        }
    }
}

// MARK: - Bottom: prompts and composer

/// The page fading in behind the composer: transparent at the top, then
/// solid, so text scrolling under the composer softly disappears.
private struct ComposerFade: View {
    static let height: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.claudeBackground.opacity(0), Color.claudeBackground],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.height)
            Color.claudeBackground
        }
        .padding(.top, -Self.height)
        .allowsHitTesting(false)
    }
}

/// The page fading in under the tab row, so text scrolling up softly
/// disappears into the header: fully hidden at the divider, then easing out
/// along one smooth curve (a flat solid part shows as an edge on bright
/// content, like a bubble). Shorter than the transcript's top padding, so
/// nothing is faded at rest.
private struct HeaderFade: View {
    static let height: CGFloat = 36

    var body: some View {
        // Smoothstep from 1 to 0: no corner anywhere along the fade.
        let stops = (0...8).map { i -> Gradient.Stop in
            let t = Double(i) / 8
            return .init(color: Color.claudeBackground.opacity(1 - t * t * (3 - 2 * t)), location: t)
        }
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: Self.height)
            .allowsHitTesting(false)
    }
}

struct ClaudeBottomArea: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        VStack(spacing: 10) {
            if let request = conversation.requests.first {
                ClaudeRequestCard(conversation: conversation, request: request)
                    .id(request.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if conversation.phase == .working {
                // Right above the input, like the CLI's spinner line.
                ClaudeWorkingLine(conversation: conversation, activity: conversation.activity)
                    .padding(.leading, ClaudeComposerBox.inset - 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, -2)
                    .transition(.opacity)
            } else if !conversation.backgroundTasks.isEmpty {
                // Between turns: what Claude Code still has running.
                ClaudeBackgroundLine(conversation: conversation)
                    .padding(.leading, ClaudeComposerBox.inset - 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, -2)
                    .transition(.opacity)
            }
            ClaudeComposerBox(conversation: conversation)
        }
        .frame(maxWidth: ClaudeTypography.composerWidth)
        .padding(.horizontal, ClaudeStyle.horizontalPadding - 12)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: conversation.requests.first?.id)
        .animation(.easeOut(duration: 0.2), value: conversation.phase)
        .animation(.easeOut(duration: 0.2), value: conversation.backgroundTasks.isEmpty)
    }
}

/// Above the composer between turns: background work Claude Code is still
/// running (a shell started in the background, a subagent), so a finished
/// turn that said "I'll be notified" doesn't look idle. Click for a menu to
/// stop a task.
struct ClaudeBackgroundLine: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        let tasks = conversation.backgroundTasks
        ClaudePopUp(items: tasks.map { task in
            PopoverMenu.Item(title: "Stop “\(Self.short(task.description))”", symbol: "stop.circle") {
                conversation.stopTask(task.id)
            }
        }) { hovering in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text(tasks.count == 1 ? "Running in the background" : "\(tasks.count) tasks running in the background")
                        .font(.toasty(Theme.Size.control, .medium))
                        .foregroundStyle(hovering ? .primary : .secondary)
                    Text(details(tasks, now: context.date))
                        .font(.toasty(Theme.Size.control))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .tooltipText("Claude Code is still running this; it picks up the result when it finishes. Click to stop.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Running in the background")
    }

    private func details(_ tasks: [ClaudeConversation.BackgroundTask], now: Date) -> String {
        guard let oldest = tasks.map(\.started).min() else { return "" }
        let time = ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(oldest))))
        if tasks.count == 1, !tasks[0].description.isEmpty {
            return Self.short(tasks[0].description) + " · " + time
        }
        return time
    }

    static func short(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }
}

struct ClaudeComposerBox: View {
    @ObservedObject var conversation: ClaudeConversation
    static let radius = Theme.Radius.large
    /// Left edge shared by the text and the first control's glyph.
    static let inset = Theme.Space.l
    /// The text area's height at rest: a little over two lines.
    static var textMinHeight: CGFloat { ClaudeComposer.minHeight + 30 }
    @State private var height: CGFloat = ClaudeComposer.minHeight
    /// The slash command menu's highlighted row.
    @State private var commandIndex = 0
    /// The draft the menu was dismissed for (Esc); it reopens once the
    /// draft changes.
    @State private var commandsDismissedFor: String?

    /// The @-mention menu's highlighted tab (among the ones that can be
    /// picked), and the draft it was dismissed for.
    @State private var mentionIndex = 0
    @State private var mentionsDismissedFor: String?

    /// "@word" being typed at the end of the draft: the word, and where the
    /// mention starts.
    private var mentionQuery: (query: String, start: String.Index)? {
        let d = conversation.draft
        guard d != mentionsDismissedFor, let at = d.lastIndex(of: "@") else { return nil }
        if at > d.startIndex, !d[d.index(before: at)].isWhitespace { return nil }
        var q = d[d.index(after: at)...]
        if q.hasPrefix("\"") { q = q.dropFirst() } else if q.contains(where: \.isWhitespace) { return nil }
        guard !q.contains("\n"), !q.contains("\"") else { return nil }
        return (String(q), at)
    }

    /// Tabs matching the mention, grouped by workspace (this one first).
    private var mentionGroups: [ClaudeMentionMenu.Group] {
        guard let q = mentionQuery?.query.lowercased() else { return [] }
        var workspaces = WorkspaceStore.shared.workspaces
        if let own = conversation.workspace, let i = workspaces.firstIndex(where: { $0 === own }) {
            workspaces.insert(workspaces.remove(at: i), at: 0)
        }
        return workspaces.compactMap { w in
            let tabs = w.conversations.filter { $0 !== conversation }
            let prefix = tabs.filter { q.isEmpty || $0.title.lowercased().hasPrefix(q) }
            let inside = tabs.filter { !q.isEmpty && !$0.title.lowercased().hasPrefix(q) && $0.title.lowercased().contains(q) }
            let match = prefix + inside
            return match.isEmpty ? nil : ClaudeMentionMenu.Group(id: w.id, name: w.displayName, tabs: match)
        }
    }

    /// Tabs that can be picked (running and known by their name), in order.
    private func pickable(_ groups: [ClaudeMentionMenu.Group]) -> [ClaudeConversation] {
        groups.flatMap(\.tabs).filter { $0.address != nil }
    }

    /// Up/down/Tab/Return/Esc while the @ menu shows.
    private func mentionKey(_ selector: Selector) -> Bool {
        let groups = mentionGroups
        guard !groups.isEmpty else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            mentionsDismissedFor = conversation.draft
            return true
        }
        let tabs = pickable(groups)
        guard !tabs.isEmpty else { return false }
        let i = min(mentionIndex, tabs.count - 1)
        switch selector {
        case #selector(NSResponder.moveUp(_:)): mentionIndex = (i - 1 + tabs.count) % tabs.count
        case #selector(NSResponder.moveDown(_:)): mentionIndex = (i + 1) % tabs.count
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)): mention(tabs[i])
        default: return false
        }
        return true
    }

    /// Replace the "@word" being typed with the tab's address, written the
    /// way Claude Code writes session mentions (quoted when needed).
    private func mention(_ tab: ClaudeConversation) {
        guard let name = tab.address, let start = mentionQuery?.start else { return }
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        conversation.draft = String(conversation.draft[..<start]) + (plain ? "@\(name) " : "@\"\(name)\" ")
        mentionIndex = 0
        conversation.focusComposer()
    }

    /// Commands matching a draft that is just "/word" (no arguments yet).
    private var commandMatches: [ClaudeConversation.SlashCommand] {
        let d = conversation.draft
        guard d.hasPrefix("/"), !d.contains(where: \.isWhitespace), d != commandsDismissedFor else { return [] }
        let q = d.dropFirst().lowercased()
        let all = conversation.availableCommands
        if q.isEmpty { return all }
        let prefix = all.filter { $0.name.lowercased().hasPrefix(q) }
        let inside = all.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + inside
    }

    /// Up/down/Tab/Return/Esc while the menu shows.
    private func commandKey(_ selector: Selector) -> Bool {
        let matches = commandMatches
        guard !matches.isEmpty else { return false }
        let i = min(commandIndex, matches.count - 1)
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            commandIndex = (i - 1 + matches.count) % matches.count
        case #selector(NSResponder.moveDown(_:)):
            commandIndex = (i + 1) % matches.count
        case #selector(NSResponder.insertTab(_:)):
            complete(matches[i], run: false)
        case #selector(NSResponder.insertNewline(_:)):
            complete(matches[i], run: true)
        case #selector(NSResponder.cancelOperation(_:)):
            commandsDismissedFor = conversation.draft
        default:
            return false
        }
        return true
    }

    /// Put the command in the draft; run it now if it takes no arguments.
    private func complete(_ command: ClaudeConversation.SlashCommand, run: Bool) {
        commandIndex = 0
        if run && command.argumentHint.isEmpty {
            conversation.draft = "/" + command.name
            conversation.submit()
        } else {
            conversation.draft = "/" + command.name + " "
        }
        conversation.focusComposer()
    }

    private var isEmpty: Bool {
        conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && conversation.attachments.isEmpty && conversation.files.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !conversation.attachments.isEmpty || !conversation.files.isEmpty {
                attachments.padding(.horizontal, Self.inset - Theme.Space.xxs).padding(.top, Theme.Space.m)
            }
            ClaudeComposer(
                text: $conversation.draft,
                height: $height,
                placeholder: placeholder,
                focusToken: conversation.composerFocusToken,
                onSubmit: { conversation.submit() },
                onEscape: {
                    if let r = conversation.requests.first {
                        conversation.respond(to: r, ["behavior": "deny", "message": "The user rejected this.", "interrupt": true])
                        return true
                    }
                    if conversation.phase == .working {
                        conversation.interrupt()
                        return true
                    }
                    return false
                },
                onShiftTab: { conversation.cyclePermissionMode() },
                onPasteImage: { conversation.attachments.append($0) },
                onFiles: { conversation.attach($0) },
                onFilesTargeted: { conversation.filesOverComposer = $0 },
                onKeyCommand: { commandKey($0) || mentionKey($0) },
                dictationID: conversation.id,
                suggestion: conversation.phase == .idle && conversation.requests.isEmpty
                    && conversation.attachments.isEmpty && conversation.files.isEmpty ? conversation.suggestion : nil,
                onAcceptSuggestion: { conversation.acceptSuggestion() })
                // Room for a couple of lines at rest; it grows as you type.
                .frame(height: max(height, Self.textMinHeight), alignment: .top)
                .padding(.horizontal, Self.inset)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.m)


            // One quiet row, as Things' toolbar: the model on the left,
            // send on the right, the icons grouped in the middle with wide
            // hover ovals. The model is the only word. Gray controls; only
            // send carries the accent (a risky mode is red, a live remote
            // session green).
            HStack(spacing: 0) {
                ClaudeModelMenu(conversation: conversation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Theme.Space.xxs) {
                    ComposerIconButton(symbol: "plus", help: "Pictures and files for Claude to read. You can also paste or drop them.",
                                       label: "Attach Files", action: attach)
                    ClaudeModeMenu(conversation: conversation)
                    if conversation.remoteControlAvailable {
                        ClaudeRemoteControlMenu(conversation: conversation)
                    }
                    DictationMicButton(conversation: conversation.id)
                }
                sendButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // The model's name lines up with the text above it.
            .padding(.leading, Self.inset - ClaudeChip.padding)
            .padding(.trailing, Theme.Space.s + 2)
            .padding(.vertical, Theme.Space.s)
            // The controls are the box's own footer, on the bars' surface.
            .fieldFooter(radius: Self.radius)
            // Buttons, not text: the arrow, not the text field's I-beam.
            .pointerStyle(.default)
        }
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Theme.Surface.field))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
        .raisedShadow()
        .contentShape(Rectangle())
        .onTapGesture { conversation.focusComposer() }
        // The slash command menu floats just above the box.
        .overlay(alignment: .top) {
            let matches = commandMatches
            if !matches.isEmpty {
                ClaudeCommandMenu(commands: matches, selected: min(commandIndex, matches.count - 1)) { i in
                    complete(matches[i], run: true)
                }
                .offset(y: -(ClaudeCommandMenu.height(for: matches.count) + 8))
                .transition(.opacity)
            }
        }
        // The @ menu: tabs to mention.
        .overlay(alignment: .top) {
            let groups = mentionGroups
            if !groups.isEmpty {
                let tabs = pickable(groups)
                ClaudeMentionMenu(groups: groups,
                                  selected: tabs.isEmpty ? nil : tabs[min(mentionIndex, tabs.count - 1)].id,
                                  choose: mention)
                .offset(y: -(ClaudeMentionMenu.height(for: groups) + 8))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: commandMatches.isEmpty)
        .animation(.easeOut(duration: 0.12), value: mentionGroups.isEmpty)
        .onChange(of: conversation.draft) { _, d in
            commandIndex = 0
            mentionIndex = 0
            if d != commandsDismissedFor { commandsDismissedFor = nil }
            if d != mentionsDismissedFor { mentionsDismissedFor = nil }
        }
    }

    private var placeholder: String {
        if !conversation.requests.isEmpty { return "Claude is waiting for your answer above" }
        if conversation.phase == .working { return "Send a follow-up…" }
        return "Ask Claude to make changes · / for commands · @ to message a tab"
    }

    @ViewBuilder private var sendButton: some View {
        if conversation.phase == .working {
            Button { conversation.interrupt() } label: {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.85))
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.claudeField).frame(width: 9, height: 9)
                }
                .frame(width: Theme.Control.height, height: Theme.Control.height)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .tooltip("Stop", shortcut: "esc", detail: "Claude stops where it is.")
            .accessibilityLabel("Stop")
        } else {
            Button { conversation.submit() } label: {
                ZStack {
                    Circle().fill(isEmpty ? Theme.Fill.selected : Color.accentColor)
                    Image(systemName: "arrow.up")
                        .font(.toasty(Theme.Size.control, .semibold))
                        .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.white))
                }
                .frame(width: Theme.Control.height, height: Theme.Control.height)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .tooltip("Send", shortcut: "⏎", detail: "⇧⏎ starts a new line.")
            .accessibilityLabel("Send")
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(conversation.attachments.enumerated()), id: \.offset) { i, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.Stroke.border))
                        .overlay(alignment: .topTrailing) {
                            RemoveAttachmentButton(label: "Remove Image") { conversation.attachments.remove(at: i) }
                        }
                }
                ForEach(conversation.files, id: \.self) { url in
                    AttachedFileChip(url: url, height: 52)
                        .overlay(alignment: .topTrailing) {
                            RemoveAttachmentButton(label: "Remove \(url.lastPathComponent)") {
                                conversation.files.removeAll { $0 == url }
                            }
                        }
                }
            }
            // Room for the remove buttons, which sit over the corners.
            .padding(.top, 5).padding(.trailing, 5)
        }
        .padding(.top, -5)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            conversation.attach(panel.urls)
        }
    }
}

struct RemoveAttachmentButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .font(.toasty(Theme.Size.body))
        }
        .buttonStyle(.plain)
        .offset(x: 5, y: -5)
        .accessibilityLabel(label)
    }
}

/// An attached file: its Finder icon, name and kind. Double-click opens it.
struct AttachedFileChip: View {
    let url: URL
    var height: CGFloat = 44

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: height - 16, height: height - 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.toasty(Theme.Size.control, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kind)
                    .font(.toasty(Theme.Size.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, Theme.Space.m)
        .frame(maxWidth: 260, alignment: .leading)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.Fill.subtle))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.Stroke.border))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .tooltipText(url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    /// "PDF", "DOCX"…: the extension says it shorter than the type's name.
    private var kind: String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}

/// Shown over the conversation while files are dragged over it.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Color.claudeBackground.opacity(0.75)
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "paperclip")
                    .font(.toasty(Theme.Glyph.hero, .light))
                Text("Drop to Attach")
                    .font(.toasty(Theme.Size.control, .medium))
            }
            .foregroundStyle(.secondary)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .padding(Theme.Space.s))
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// The file URLs in a drop, in order, delivered on the main actor.
@MainActor func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    Task { @MainActor in
        var urls: [URL] = []
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { c in
                _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        if !urls.isEmpty { done(urls) }
    }
}

// MARK: - Model and permission mode

struct ClaudeModelMenu: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        ClaudePopUp(items: conversation.models.isEmpty
            ? [.init(title: "Loading models…", enabled: false) {}]
            : conversation.models.map { m in
                .init(title: m.name, subtitle: m.detail, checked: m.value == conversation.model) {
                    conversation.setModel(m.value)
                }
            }) { hovering in
            ClaudeChip(icon: nil, title: conversation.modelName ?? "Model", tint: nil, hovering: hovering)
        }
        .tooltip("Model", detail: "The model this conversation uses.")
    }
}

struct ClaudeModeMenu: View {
    @ObservedObject var conversation: ClaudeConversation

    private static let modes: [(id: String, title: String, icon: String)] = [
        ("default", "Ask Before Edits", "hand.raised"),
        ("acceptEdits", "Accept Edits", "pencil.line"),
        ("plan", "Plan Mode", "list.bullet.clipboard"),
        ("auto", "Auto Mode", "bolt"),
        ("bypassPermissions", "Bypass Permissions", "exclamationmark.shield"),
    ]

    static func label(_ mode: String) -> String {
        modes.first { $0.id == mode }?.title ?? mode
    }

    var body: some View {
        let current = Self.modes.first { $0.id == conversation.permissionMode }
        let available = Self.modes.filter {
            $0.id != "auto" || conversation.autoModeAvailable || conversation.permissionMode == "auto"
        }
        ClaudePopUp(items: available.map { mode in
            .init(title: mode.title, symbol: mode.icon, checked: mode.id == conversation.permissionMode) {
                conversation.setPermissionMode(mode.id)
            }
        }) { hovering in
            ClaudeChip(icon: current?.icon ?? "hand.raised",
                       title: "",
                       // Only the risky mode is colored; the menu and
                       // tooltip name it.
                       tint: conversation.permissionMode == "bypassPermissions" ? .red : nil,
                       hovering: hovering)
        }
        .tooltip(Self.label(conversation.permissionMode), shortcut: "⇧⇥",
                 detail: "The permission mode: what Claude may do without asking. ⇧⇥ cycles through them.")
        .accessibilityLabel("Permission Mode: \(Self.label(conversation.permissionMode))")
    }
}

/// Claude Code's slash commands matching what's typed after "/", above the
/// composer: ↑↓ to choose, Tab to complete, Return to run, Esc to close.
struct ClaudeCommandMenu: View {
    let commands: [ClaudeConversation.SlashCommand]
    let selected: Int
    let choose: (Int) -> Void

    static let rowHeight = Theme.Menu.rowHeight
    static let visibleRows = 8

    static func height(for count: Int) -> CGFloat {
        CGFloat(min(count, visibleRows)) * rowHeight + Theme.Menu.inset * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { i, c in
                        CommandRow(command: c, selected: i == selected)
                            .id(c.id)
                            .contentShape(Rectangle())
                            .onTapGesture { choose(i) }
                    }
                }
                .padding(Theme.Menu.inset)
            }
            .scrollIndicators(commands.count > Self.visibleRows ? .automatic : .never)
            .frame(height: Self.height(for: commands.count))
            .onChange(of: selected) { _, i in
                if commands.indices.contains(i) { proxy.scrollTo(commands[i].id) }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.claudeField))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
        .popoverShadow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private struct CommandRow: View {
        let command: ClaudeConversation.SlashCommand
        let selected: Bool

        var body: some View {
            HStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.xs + 1) {
                    Text("/" + command.name)
                        .font(.toasty(Theme.Size.control, .medium))
                        .foregroundStyle(.primary)
                    // Short hints only ("<file>"); long option lists would
                    // crowd out the description.
                    if !command.argumentHint.isEmpty, command.argumentHint.count <= 24 {
                        Text(command.argumentHint)
                            .font(.toasty(Theme.Size.meta))
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                Text(command.description)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Menu.rowPadding)
            .frame(height: ClaudeCommandMenu.rowHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(selected ? Theme.Fill.accent : .clear))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// Tabs to mention with "@" (Claude Code's session mentions), grouped by
/// workspace like the sidebar. Tabs whose session isn't running (or isn't
/// known by its tab name yet) are greyed out and can't be picked.
struct ClaudeMentionMenu: View {
    struct Group: Identifiable {
        let id: UUID
        let name: String
        let tabs: [ClaudeConversation]
    }

    let groups: [Group]
    let selected: UUID?
    let choose: (ClaudeConversation) -> Void

    static let rowHeight = Theme.Menu.rowHeight
    static let headerHeight = Theme.Menu.headerHeight
    static let maxHeight: CGFloat = 8 * rowHeight

    static func height(for groups: [Group]) -> CGFloat {
        let content = groups.reduce(0) { $0 + headerHeight + CGFloat($1.tabs.count) * rowHeight }
        return min(content, maxHeight) + Theme.Menu.inset * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.name)
                            .font(.toasty(Theme.Size.meta, .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Menu.rowPadding)
                            .frame(height: Self.headerHeight, alignment: .bottomLeading)
                            .padding(.bottom, 0)
                        ForEach(group.tabs) { tab in
                            MentionRow(tab: tab, selected: tab.id == selected, choose: choose)
                                .id(tab.id)
                        }
                    }
                }
                .padding(Theme.Menu.inset)
            }
            .scrollIndicators(Self.height(for: groups) >= Self.maxHeight + 10 ? .automatic : .never)
            .frame(height: Self.height(for: groups))
            .onChange(of: selected) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.claudeField))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
        .popoverShadow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs to Message")
    }

    private struct MentionRow: View {
        @ObservedObject var tab: ClaudeConversation
        let selected: Bool
        let choose: (ClaudeConversation) -> Void

        private var hint: String? {
            if !tab.sessionRunning { return "not running" }
            return tab.address == nil ? "naming…" : nil
        }

        var body: some View {
            let enabled = tab.address != nil
            HStack(spacing: Theme.Space.s) {
                // The tab bar's icons: Claude's sparkle, or a branch for a fork.
                Image(systemName: tab.forkOrigin != nil ? "arrow.triangle.branch" : "sparkle")
                    .font(.toasty(Theme.Glyph.small, .semibold))
                    .foregroundStyle(enabled ? Color(nsColor: .systemOrange) : Color.secondary.opacity(0.5))
                    .frame(width: 12)
                Text(tab.title)
                    .font(.toasty(Theme.Size.control, .medium))
                    .foregroundStyle(enabled ? .primary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.Menu.rowPadding)
            .frame(height: ClaudeMentionMenu.rowHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(selected ? Theme.Fill.accent : .clear))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { choose(tab) } }
            .tooltipText(enabled ? "Mention @\(tab.title)" : "Open this tab to start its session, then it can be messaged")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// Remote Control (as /remote-control in the CLI): continue this session
/// from claude.ai or the Claude app. Quiet when off; green while connected.
struct ClaudeRemoteControlMenu: View {
    @ObservedObject var conversation: ClaudeConversation

    static let symbol = "iphone.radiowaves.left.and.right"

    private var items: [PopoverMenu.Item] {
        switch conversation.remoteControl {
        case .on(let url):
            var list: [PopoverMenu.Item] = [
                .init(title: "Remote Control Is On", subtitle: "Continue this session from claude.ai or the Claude app",
                      symbol: Self.symbol, enabled: false) {},
            ]
            if let url, let link = URL(string: url) {
                list.append(.init(title: "Open in Browser", symbol: "safari") { NSWorkspace.shared.open(link) })
                list.append(.init(title: "Copy Link", symbol: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                })
            }
            list.append(.init(title: "Turn Off Remote Control", symbol: "xmark.circle") { conversation.setRemoteControl(false) })
            return list
        case .connecting:
            return [
                .init(title: "Connecting…", symbol: Self.symbol, enabled: false) {},
                .init(title: "Turn Off Remote Control", symbol: "xmark.circle") { conversation.setRemoteControl(false) },
            ]
        case .failed(let error):
            return [
                .init(title: "Remote Control Couldn't Start", subtitle: error, symbol: "exclamationmark.triangle", enabled: false) {},
                .init(title: "Try Again", symbol: "arrow.clockwise") { conversation.setRemoteControl(true) },
            ]
        case .off:
            return [
                .init(title: "Turn On Remote Control", subtitle: "Continue this session from claude.ai or the Claude app",
                      symbol: Self.symbol) { conversation.setRemoteControl(true) },
            ]
        }
    }

    var body: some View {
        let state = conversation.remoteControl
        ClaudePopUp(items: items) { hovering in
            ClaudeChip(icon: { if case .failed = state { "exclamationmark.triangle" } else { Self.symbol } }(),
                       title: "",
                       tint: state.isOn ? .green : { if case .failed = state { Color.orange } else { nil } }(),
                       hovering: hovering)
        }
        .tooltip(state == .connecting ? "Remote Control: Connecting…" : "Remote Control",
                 detail: state.isOn ? "On: continue this session from claude.ai or the Claude app."
                                                      : "Continue this session from claude.ai or the Claude app.")
        .accessibilityLabel("Remote Control")
    }
}

/// A custom-drawn control that opens Toasty's own menu over itself
/// (SwiftUI's Menu flattens custom labels on macOS).
struct ClaudePopUp<Label: View>: View {
    typealias Item = PopoverMenu.Item

    let items: [Item]
    /// Makes the items when the menu opens, for a menu whose items change
    /// without this view being drawn again (else `items`).
    var makeItems: (() -> [Item])? = nil
    /// Told when its menu opens and closes.
    var onOpenChange: (Bool) -> Void = { _ in }
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    @State private var hovering = false
    @State private var menuOpen = false
    @State private var anchor = MenuAnchorRef()

    var body: some View {
        // A plain SwiftUI button, so it hovers and clicks like the others in
        // the composer; Toasty's own menu opens over it (above, inside the
        // window), placed by an AppKit view behind it that only marks where.
        Button(action: open) {
            label(hovering || menuOpen)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(MenuAnchor(ref: anchor))
        .animation(.easeOut(duration: 0.12), value: hovering || menuOpen)
    }

    private func open() {
        guard let view = anchor.view else { return }
        if menuOpen { PopoverMenu.shared.close(); return }
        menuOpen = true
        onOpenChange(true)
        PopoverMenu.shared.show(makeItems?() ?? items, from: view) {
            menuOpen = false
            onOpenChange(false)
        }
    }

    /// Where the menu opens from (the AppKit view behind the button).
    @MainActor final class MenuAnchorRef {
        weak var view: NSView?
    }

    /// A transparent AppKit view behind the button that only marks where it
    /// is (clicks and the pointer go to the button).
    struct MenuAnchor: NSViewRepresentable {
        let ref: MenuAnchorRef

        func makeNSView(context: Context) -> NSView {
            let v = Passthrough()
            ref.view = v
            return v
        }

        func updateNSView(_ view: NSView, context: Context) { ref.view = view }

        private final class Passthrough: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// A small pop-up button label: a title with a chevron (an icon before it
/// when it has one), or with no title just an icon, as the composer's icon
/// buttons.
struct ClaudeChip: View {
    /// The title's padding inside the hover capsule.
    static let padding = Theme.Space.s + Theme.Space.xxs
    let icon: String?
    let title: String
    let tint: Color?
    var hovering = false

    var body: some View {
        Group {
            if title.isEmpty, let icon {
                Image(systemName: icon)
                    .font(.toasty(Theme.Size.body, .regular))
                    .frame(width: ComposerIconButton.width, height: Theme.Control.height)
            } else {
                HStack(spacing: Theme.Space.xs + 1) {
                    if let icon {
                        Image(systemName: icon).font(.toasty(Theme.Size.meta, .medium))
                    }
                    Text(title).font(.toasty(Theme.Size.control, .medium))
                    Image(systemName: "chevron.down").font(.toasty(Theme.Glyph.small, .semibold)).opacity(0.6)
                }
                .padding(.horizontal, Self.padding)
                .frame(height: Theme.Control.height)
            }
        }
        // As the app's bar buttons: full ink and a hairline capsule under
        // the pointer (a tint, when it has one, stays its color).
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? (hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
        .overlay(Capsule().strokeBorder(hovering ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// An icon button for the composer's control row, as the app's bar
/// buttons: full ink and a hairline capsule under the pointer, filled
/// while pressed.
struct ComposerIconButton: View {
    /// Wide, as Things' toolbar buttons: the hover oval is a long capsule.
    static let width: CGFloat = 52
    let symbol: String
    let help: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.body, .regular))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: Self.width, height: Theme.Control.height)
                .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip(label, detail: help)
        .accessibilityLabel(label)
    }
}

extension View {
    /// The footer of a field (the composer, a prompt card): a band of the
    /// bars' surface along its bottom, following its corners.
    func fieldFooter(radius: CGFloat) -> some View {
        background(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            .fill(Theme.Surface.chrome))
    }
}

/// Back to the latest message, shown while scrolled up.
private struct JumpToLatestButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.toasty(Theme.Size.meta, .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.claudeField))
                .overlay(Circle().strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
                .liftShadow()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip("Jump to Latest")
        .accessibilityLabel("Jump to Latest")
    }
}
