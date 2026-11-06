import AppKit
import SwiftUI

/// mostty: The native Claude Code conversation: a header bar (project,
/// branch, activity, inspector toggle), the transcript at a comfortable
/// reading width, prompts that need an answer, and the composer.
struct ClaudeConversationView: View {
    @ObservedObject var conversation: ClaudeConversation
    var terminalVisible = false
    var onRunInTerminal: (String) -> Void
    var onToggleTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ClaudeTranscript(conversation: conversation, onRunInTerminal: onRunInTerminal)
            ClaudeBottomArea(conversation: conversation)
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

// MARK: - Header bar

/// Like Xcode's jump bar + activity view: where you are on the left, what
/// Claude is doing in the middle, the inspector toggle on the right.
struct ClaudeHeaderBar: View {
    @ObservedObject var conversation: ClaudeConversation
    var terminalVisible: Bool
    var onToggleTerminal: () -> Void

    static let height: CGFloat = 38

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                breadcrumb
                Spacer(minLength: 12)
                Button(action: onToggleTerminal) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(terminalVisible ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(terminalVisible ? "Hide Terminal (⌃⌘T)" : "Show Terminal (⌃⌘T)")
            }
            ClaudeActivityPill(conversation: conversation)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.claudeSeparator).frame(height: 0.5)
        }
    }

    private var breadcrumb: some View {
        ClaudePopUp(items: [
            .init(title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: conversation.cwd)])
            },
            .init(title: "Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conversation.cwd, forType: .string)
            },
        ]) { hovering in
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text(conversation.projectName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                if let branch = conversation.branch {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(branch)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        }
        .help(conversation.cwd)
    }
}

/// Xcode-style activity view: one rounded field that says what's going on.
struct ClaudeActivityPill: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                indicator
                Text(label(now: context.date))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 200, maxWidth: 360)
            .frame(height: 24)
            .background(Capsule().fill(Color.claudeFill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        }
        .animation(.easeOut(duration: 0.2), value: conversation.phase)
    }

    @ViewBuilder private var indicator: some View {
        if !conversation.requests.isEmpty {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if conversation.phase != .idle || conversation.status != nil {
            ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemOrange).opacity(0.85))
        }
    }

    private func label(now: Date) -> String {
        if !conversation.requests.isEmpty { return "Waiting for you" }
        if let status = conversation.status { return status }
        switch conversation.phase {
        case .starting: return "Starting Claude Code…"
        case .working:
            let secs = conversation.turnStarted.map { Int(now.timeIntervalSince($0)) } ?? 0
            return secs > 0 ? "Working · \(ClaudeToolInfo.duration(secs))" : "Working…"
        case .idle:
            return conversation.modelName.map { "Claude Code · \($0)" } ?? "Claude Code"
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
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }
            .modifier(PinToBottom())
            .onChange(of: conversation.items.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var rows: [TranscriptRow] {
        var out: [TranscriptRow] = []
        var run: [ClaudeItem] = []
        func flush() {
            if !run.isEmpty { out.append(.tools(run)); run = [] }
        }
        for item in conversation.items {
            switch item.kind {
            case .tool:
                run.append(item)
            case .thinking where item.finalized && item.text.isEmpty:
                // Nothing to show when the model returned no visible thinking.
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
            ClaudeItemView(item: item, cwd: conversation.cwd, onRun: onRunInTerminal)
        }
    }
}

/// Keeps the transcript scrolled to the bottom while it grows (streaming),
/// unless the user scrolled up.
private struct PinToBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else if #available(macOS 14.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

// MARK: - Items

struct ClaudeItemView: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    var onRun: (String) -> Void

    var body: some View {
        switch item.kind {
        case .user: ClaudeUserMessage(item: item)
        case .assistant: ClaudeAssistantMessage(item: item, cwd: cwd, onRun: onRun)
        case .thinking: ClaudeThinking(item: item)
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
    @State private var copied = false

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
            if let footer = item.footer {
                HStack(spacing: 10) {
                    Text(footer)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(.system(size: 11))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Copy Response")
                }
                .padding(.top, -4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text(item.finalized ? "Thought" : "Thinking…")
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

struct ClaudeBottomArea: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        VStack(spacing: 10) {
            if let request = conversation.requests.first {
                ClaudeRequestCard(conversation: conversation, request: request)
                    .id(request.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ClaudeComposerBox(conversation: conversation)
        }
        .frame(maxWidth: ClaudeTypography.composerWidth)
        .padding(.horizontal, ClaudeStyle.horizontalPadding - 12)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: conversation.requests.first?.id)
    }
}

struct ClaudeComposerBox: View {
    @ObservedObject var conversation: ClaudeConversation
    @State private var height: CGFloat = ClaudeComposer.minHeight

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
                onPasteImage: { conversation.attachments.append($0) })
                .frame(height: height)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            HStack(spacing: 4) {
                ClaudeModelMenu(conversation: conversation)
                ClaudeModeMenu(conversation: conversation)
                Spacer()
                Button(action: attach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach Images…")
                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
            .padding(.top, 2)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.claudeField))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { conversation.focusComposer() }
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
                    RoundedRectangle(cornerRadius: 2).fill(Color.claudeField).frame(width: 9, height: 9)
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Stop (esc)")
        } else {
            Button { conversation.submit() } label: {
                ZStack {
                    Circle().fill(isEmpty ? Color.primary.opacity(0.12) : Color.accentColor)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(isEmpty ? Color.secondary : Color.white)
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .help("Send (⏎)")
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
                       title: current?.title ?? conversation.permissionMode,
                       tint: conversation.permissionMode == "default" ? nil
                           : conversation.permissionMode == "bypassPermissions" ? .red
                           : conversation.permissionMode == "plan" ? .teal : .accentColor,
                       hovering: hovering)
        }
        .help("Permission mode (⇧⇥ to cycle)")
    }
}

/// mostty: A custom-drawn control that opens a native menu below itself
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
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
            }
            Text(title).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.map { $0.opacity(hovering ? 0.18 : 0.12) } ?? Color.primary.opacity(hovering ? 0.07 : 0)))
    }
}
