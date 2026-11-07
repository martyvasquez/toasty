import AppKit
import SwiftUI

/// A Claude Code conversation: the transcript and the composer at one
/// shared width, with prompts that need an answer above the composer. No
/// header bar: the tab row above is the only chrome.
struct ClaudeConversationView: View {
    @ObservedObject var conversation: ClaudeConversation
    var onRunInTerminal: (String) -> Void

    var body: some View {
        // The transcript scrolls under the composer and fades out above it.
        ClaudeTranscript(conversation: conversation, onRunInTerminal: onRunInTerminal)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ClaudeBottomArea(conversation: conversation)
                    .background(alignment: .top) { ComposerFade() }
            }
            .background(Color.claudeBackground)
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
    @State private var limit = 160
    /// The view is scrolled to (near) the end.
    @State private var atBottom = true
    /// Follow new output, like a terminal: on while at the bottom, off once
    /// the user scrolls up, back on when they return to the bottom.
    @State private var following = true

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var atBottom: Bool
    }

    var body: some View {
        let all = rows
        let hidden = max(0, all.count - limit)
        let shown = Array(all.suffix(limit))

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if conversation.items.isEmpty {
                        ClaudeEmptyState(conversation: conversation)
                    }
                    if hidden > 0 {
                        Button("Show \(hidden) Earlier") { limit += 160 }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 20)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                        rowView(row)
                            .padding(.top, i == 0 ? 0 : spacing(before: row, after: shown[i - 1]))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                // Exactly the composer's width and edges.
                .frame(maxWidth: ClaudeTypography.composerWidth, alignment: .leading)
                .padding(.horizontal, ClaudeStyle.horizontalPadding - 12)
                .padding(.top, 26)
                // Clear of the fade behind the composer.
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .modifier(PinToBottom())
            .onScrollGeometryChange(for: ScrollState.self) { g in
                // The bottom of what's visible above the composer (the
                // bottom inset) against the end of the content.
                ScrollState(offset: g.contentOffset.y, contentHeight: g.contentSize.height,
                            atBottom: g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 60)
            } action: { old, new in
                if new.offset != old.offset {
                    // The user (or a jump) scrolled: follow only from the bottom.
                    following = new.atBottom
                } else if new.contentHeight > old.contentHeight, following {
                    // Output grew while following: stay with it.
                    proxy.scrollTo("bottom", anchor: .bottom)
                    return
                }
                if new.atBottom != atBottom { withAnimation(.easeOut(duration: 0.15)) { atBottom = new.atBottom } }
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
            .onChange(of: conversation.items.count) { _, _ in
                // A new message: follow it, unless the user is reading
                // further up (a prompt they just sent always shows).
                guard following || conversation.items.last?.kind == .user else { return }
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
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
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
            default:
                flush()
                out.append(.item(item))
            }
        }
        flush()
        return out
    }

    private func spacing(before row: TranscriptRow, after previous: TranscriptRow) -> CGFloat {
        if row.first?.kind == .user { return 34 }
        if previous.first?.kind == .user { return 18 }
        return 16
    }

    @ViewBuilder private func rowView(_ row: TranscriptRow) -> some View {
        switch row {
        case .tools(let items):
            ClaudeToolGroup(items: items, cwd: conversation.cwd)
        case .item(let item):
            ClaudeItemView(item: item, cwd: conversation.cwd, onRun: onRunInTerminal,
                           latest: item.id == latestReplyID)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: status.symbol)
                        .font(.system(size: 11.5))
                        .foregroundStyle(status.color)
                    Text(status.text).font(.system(size: 12.5, weight: .medium))
                    if !title.isEmpty {
                        Text("· " + title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(plan.isEmpty)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ClaudeMarkdown.blocks(plan, style: .init(cwd: cwd)).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let s): ClaudeRichText(text: s)
                        case .code(let l, let c): ClaudeCodeBlock(language: l, code: c)
                        case .table(let s): ClaudeTableBlock(text: s)
                        case .rule: Divider()
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous).fill(Color.claudeFill))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Claude's task list while it works (TodoWrite / TaskCreate), above the
/// working line: the current item and its neighbours, ticked off live.
struct ClaudeTaskList: View {
    let todos: [ClaudeConversation.Todo]
    private static let shown = 5

    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        // A window around the first unfinished item.
        let focus = todos.firstIndex { $0.status != .completed } ?? 0
        let start = max(0, min(focus - 1, todos.count - Self.shown))
        let slice = todos[start..<min(todos.count, start + Self.shown)]
        VStack(alignment: .leading, spacing: 5) {
            Text("Tasks · \(done) of \(todos.count) done")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(slice) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Group {
                        switch todo.status {
                        case .completed:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
                        case .inProgress:
                            Image(systemName: "circle.inset.filled").foregroundStyle(Color.accentColor)
                        case .pending:
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                    .frame(width: 14)
                    Text(todo.status == .inProgress ? (todo.activeTitle ?? todo.title) : todo.title)
                        .font(.system(size: 12.5, weight: todo.status == .inProgress ? .medium : .regular))
                        .foregroundStyle(todo.status == .completed ? .tertiary : todo.status == .inProgress ? .primary : .secondary)
                        .strikethrough(todo.status == .completed, color: .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, ClaudeComposerBox.inset - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tasks, \(done) of \(todos.count) done")
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .frame(width: 14)
                Text(verb)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(details(now: context.date))
                    .font(.system(size: 12.5))
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
        parts.append("esc to interrupt")
        return parts.joined(separator: " · ")
    }
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

    var body: some View {
        switch item.kind {
        case .user: ClaudeUserMessage(item: item)
        case .assistant: ClaudeAssistantMessage(item: item, cwd: cwd, onRun: onRun, latest: latest)
        case .thinking: ClaudeThinking(item: item)
        case .tool where item.toolName == "ExitPlanMode": ClaudePlanRow(item: item, cwd: cwd)
        case .tool: ClaudeToolGroup(items: [item], cwd: cwd)
        case .notice:
            Text(item.text)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                ClaudeRichText(text: ClaudeMarkdown.inline(item.text, font: .systemFont(ofSize: 13), style: .init(cwd: cwd)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .systemRed).opacity(0.08)))
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
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                if !item.text.isEmpty {
                    ClaudeRichText(text: Self.attributed(item.text), hugs: true)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.075)))
                }
            }
        }
    }

    static func attributed(_ text: String) -> NSAttributedString {
        let font = ClaudeTypography.body
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: ClaudeTypography.text,
            .paragraphStyle: ClaudeTypography.paragraphStyle(font: font, multiple: 1.38),
            .baselineOffset: ClaudeTypography.baselineOffset(font, 1.38),
        ])
    }
}

struct ClaudeAssistantMessage: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    var onRun: (String) -> Void
    var latest = false
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
                ClaudeReplyActions(item: item)
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
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            ReplyActionButton(symbol: copied ? "checkmark" : "square.on.square",
                              help: copied ? "Copied" : "Copy Response") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.turnText.isEmpty ? item.text : item.turnText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            if let date = item.finishedAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.relative(date, now: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.leading, 4)
                .help(detail(date))
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
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .padding(.leading, -6)
    }
}

struct ClaudeThinking: View {
    @ObservedObject var item: ClaudeItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(item.finalized ? "Thought" : "Thinking")
                        .font(.system(size: 12.5, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.claudeSeparator).frame(width: 2)
                }
            }
        }
    }
}

struct ClaudeEmptyState: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .padding(.bottom, 4)
            Text(conversation.projectName)
                .font(.system(size: 22, weight: .semibold))
            HStack(spacing: 6) {
                Text((conversation.cwd as NSString).abbreviatingWithTildeInPath)
                if let branch = conversation.branch {
                    Text("·")
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(branch)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
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

struct ClaudeBottomArea: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        VStack(spacing: 10) {
            if let request = conversation.requests.first {
                ClaudeRequestCard(conversation: conversation, request: request)
                    .id(request.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if conversation.phase == .working {
                // Claude's task list, when Claude Code gives it one (the CLI
                // shows it under its spinner).
                if conversation.todos.contains(where: { $0.status != .completed }) {
                    ClaudeTaskList(todos: conversation.todos)
                        .transition(.opacity)
                }
                // Right above the input, like the CLI's spinner line.
                ClaudeWorkingLine(conversation: conversation, activity: conversation.activity)
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
        .animation(.easeOut(duration: 0.2), value: conversation.todos)
    }
}

struct ClaudeComposerBox: View {
    @ObservedObject var conversation: ClaudeConversation
    static let radius: CGFloat = 18
    /// Left edge shared by the text and the first control's glyph.
    static let inset: CGFloat = 16
    @State private var height: CGFloat = ClaudeComposer.minHeight
    /// The slash command menu's highlighted row.
    @State private var commandIndex = 0
    /// The draft the menu was dismissed for (Esc); it reopens once the
    /// draft changes.
    @State private var commandsDismissedFor: String?

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
        conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && conversation.attachments.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !conversation.attachments.isEmpty {
                attachments.padding(.horizontal, 14).padding(.top, 12)
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
                onKeyCommand: commandKey)
                .frame(height: height)
                .padding(.horizontal, Self.inset)
                .padding(.top, 13)

            // One quiet row: attach and mode on the left, model and send on
            // the right. Text-only controls; only send carries color.
            HStack(spacing: 2) {
                ComposerIconButton(symbol: "plus", help: "Attach Images…", label: "Attach Images", action: attach)
                ClaudeModeMenu(conversation: conversation)
                Spacer(minLength: 8)
                if conversation.remoteControlAvailable {
                    ClaudeRemoteControlMenu(conversation: conversation)
                }
                ClaudeModelMenu(conversation: conversation)
                sendButton.padding(.leading, 4)
            }
            .padding(.leading, Self.inset - 7)
            .padding(.trailing, 9)
            .padding(.top, 4)
            .padding(.bottom, 9)
        }
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Color.claudeField))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
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
        .animation(.easeOut(duration: 0.12), value: commandMatches.isEmpty)
        .onChange(of: conversation.draft) { _, d in
            commandIndex = 0
            if d != commandsDismissedFor { commandsDismissedFor = nil }
        }
    }

    private var placeholder: String {
        if !conversation.requests.isEmpty { return "Claude is waiting for your answer above" }
        if conversation.phase == .working { return "Send a follow-up…" }
        return "Ask Claude to make changes, or type / for commands"
    }

    @ViewBuilder private var sendButton: some View {
        if conversation.phase == .working {
            Button { conversation.interrupt() } label: {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.85))
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.claudeField).frame(width: 9, height: 9)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop (esc)")
            .accessibilityLabel("Stop")
        } else {
            Button { conversation.submit() } label: {
                ZStack {
                    Circle().fill(isEmpty ? Color.primary.opacity(0.10) : Color.accentColor)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.white))
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.15), value: isEmpty)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .help("Send (⏎)")
            .accessibilityLabel("Send")
        }
    }

    private var attachments: some View {
        HStack(spacing: 8) {
            ForEach(Array(conversation.attachments.enumerated()), id: \.offset) { i, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                    .overlay(alignment: .topTrailing) {
                        Button { conversation.attachments.remove(at: i) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove Image")
                    }
            }
        }
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let image = NSImage(contentsOf: url) { conversation.attachments.append(image) }
            }
            conversation.focusComposer()
        }
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
        .help("Model")
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

    /// The chip's short name for a mode (the menu shows the full name).
    static func shortLabel(_ mode: String) -> String {
        switch mode {
        case "default": "Ask Before Edits"
        case "acceptEdits": "Accept Edits"
        case "plan": "Plan"
        case "auto": "Auto"
        case "bypassPermissions": "Bypass Permissions"
        default: mode
        }
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
                       title: Self.shortLabel(conversation.permissionMode),
                       tint: conversation.permissionMode == "default" ? nil
                           : conversation.permissionMode == "bypassPermissions" ? .red
                           : conversation.permissionMode == "plan" ? .teal : .accentColor,
                       hovering: hovering)
        }
        .help("Permission mode (⇧⇥ to cycle)")
    }
}

/// Claude Code's slash commands matching what's typed after "/", above the
/// composer: ↑↓ to choose, Tab to complete, Return to run, Esc to close.
struct ClaudeCommandMenu: View {
    let commands: [ClaudeConversation.SlashCommand]
    let selected: Int
    let choose: (Int) -> Void

    static let rowHeight: CGFloat = 32
    static let visibleRows = 8

    static func height(for count: Int) -> CGFloat {
        CGFloat(min(count, visibleRows)) * rowHeight + 10
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
                .padding(5)
            }
            .scrollIndicators(commands.count > Self.visibleRows ? .automatic : .never)
            .frame(height: Self.height(for: commands.count))
            .onChange(of: selected) { _, i in
                if commands.indices.contains(i) { proxy.scrollTo(commands[i].id) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.claudeField))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    private struct CommandRow: View {
        let command: ClaudeConversation.SlashCommand
        let selected: Bool

        var body: some View {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("/" + command.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    // Short hints only ("<file>"); long option lists would
                    // crowd out the description.
                    if !command.argumentHint.isEmpty, command.argumentHint.count <= 24 {
                        Text(command.argumentHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                Text(command.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: ClaudeCommandMenu.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear))
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

    private var items: [ClaudePopUp<ClaudeChip>.Item] {
        switch conversation.remoteControl {
        case .on(let url):
            var list: [ClaudePopUp<ClaudeChip>.Item] = [
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
                       title: state.isOn ? "Remote" : state == .connecting ? "Connecting…" : "",
                       tint: state.isOn ? .green : { if case .failed = state { Color.orange } else { nil } }(),
                       hovering: hovering)
        }
        .help(state.isOn ? "Remote Control is on: continue this session from claude.ai or the Claude app"
              : "Remote Control")
        .accessibilityLabel("Remote Control")
    }
}

/// A custom-drawn control that opens a native menu below itself
/// (SwiftUI's Menu flattens custom labels on macOS).
struct ClaudePopUp<Label: View>: View {
    struct Item {
        var title: String
        var subtitle: String = ""
        var symbol: String?
        var checked = false
        var enabled = true
        var action: () -> Void
    }

    let items: [Item]
    @ViewBuilder let label: (_ hovering: Bool) -> Label
    @State private var hovering = false

    var body: some View {
        label(hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .overlay(MenuAnchor(items: items))
    }

    /// Transparent AppKit view that shows the menu on click, anchored to
    /// its own bottom-left corner like a pop-up button.
    private struct MenuAnchor: NSViewRepresentable {
        let items: [Item]

        func makeNSView(context: Context) -> AnchorView { AnchorView() }
        func updateNSView(_ view: AnchorView, context: Context) { view.items = items }

        final class AnchorView: NSView {
            var items: [Item] = []

            override func mouseDown(with event: NSEvent) {
                let menu = NSMenu()
                menu.autoenablesItems = false
                for item in items {
                    let mi = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = item.action
                    mi.state = item.checked ? .on : .off
                    mi.isEnabled = item.enabled
                    if let symbol = item.symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                    if !item.subtitle.isEmpty, #available(macOS 14.4, *) { mi.subtitle = item.subtitle }
                    menu.addItem(mi)
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
            }

            @objc private func choose(_ sender: NSMenuItem) {
                (sender.representedObject as? () -> Void)?()
            }
        }
    }
}

/// A small pop-up button label: optional icon, title and a chevron.
struct ClaudeChip: View {
    let icon: String?
    let title: String
    let tint: Color?
    var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
            }
            if !title.isEmpty { Text(title).font(.system(size: 12.5, weight: .medium)) }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.6)
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A borderless icon button for the composer's control row (hover fill only).
struct ComposerIconButton: View {
    let symbol: String
    let help: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Back to the latest message, shown while scrolled up.
private struct JumpToLatestButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.claudeField))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Jump to Latest")
        .accessibilityLabel("Jump to Latest")
    }
}
