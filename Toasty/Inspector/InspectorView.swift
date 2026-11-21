import AppKit
import SwiftUI

// MARK: - Pane

/// The top of the right column: the active workspace's selected inspector
/// tab. Changes and Tee-Up belong to the workspace; Usage follows the
/// selected conversation tab.
struct InspectorPane: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            Color.claudeChrome.ignoresSafeArea()
            if let workspace = store.active {
                InspectorWorkspace(workspace: workspace)
            }
        }
    }
}

private struct InspectorWorkspace: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            InspectorPanelHeading(title: workspace.inspectorTab.title)
            switch workspace.inspectorTab {
            case .changes:
                ChangesTab(workspace: workspace, changes: workspace.changes)
            case .teeUp:
                TeeUpTab(workspace: workspace).id(workspace.id)
            case .activity:
                if let c = workspace.selected { ActivityTab(conversation: c).id(c.id) } else { NoConversation(detail: "Open a tab to see what Claude is doing.") }
            }
            if !workspace.terminalVisible {
                InspectorFooter(workspace: workspace)
            }
        }
    }
}

/// Under the inspector while the terminal is hidden, laid out as the
/// sidebar's footer: "Open Terminal" at the left, which brings it back.
private struct InspectorFooter: View {
    @ObservedObject var workspace: Workspace

    // The label's glyph on the inspector's 20pt edge.
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            HStack(spacing: 0) {
                terminalButton
                Spacer(minLength: 0)
            }
            .frame(height: Theme.Sidebar.footerHeight)
        }
    }

    // "Open Terminal": shows the workspace's terminals (one is started if there
    // are none), as ⌃⌘T does. New terminals are the strip's +.
    private var terminalButton: some View {
        // The up chevron opens it (the strip's down chevron closes it).
        BarLabelButton(symbol: "chevron.up", title: "Open Terminal",
                       tooltip: Tooltip(title: "Open Terminal", shortcut: "⌃⌘T",
                                        detail: "A shell in this workspace's folder, under the inspector.")) {
            AppDelegate.shared.windowController?.toggleTerminal(nil)
        }
        .padding(.leading, Theme.Inspector.edge - BarLabelButton.padding)
    }
}

private struct NoConversation: View {
    var detail = "Open a tab to see its usage."

    var body: some View {
        InspectorEmpty(symbol: "sparkle", title: "No Conversation", detail: detail)
    }
}

// MARK: - Shared pieces


/// A centered message for an empty tab.
struct InspectorEmpty: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        // As Things' empty lists: the icon large and faint, the words quiet.
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Glyph.emptyState, .ultraLight))
                .foregroundStyle(.quaternary)
                .padding(.bottom, Theme.Space.xs)
            Text(title)
                .font(.toasty(Theme.Size.control, .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The open panel's name over a rule, at the top of the panel: the
/// workspace sidebar's headings (body semibold in heading blue, a 24pt
/// row, the rule a little wider than the text on both sides).
struct InspectorPanelHeading: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.toasty(Theme.Size.body, .semibold))
                .foregroundStyle(Theme.headingBlue)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Sidebar.rowHeight)
            Rectangle().fill(Theme.Stroke.rule).frame(height: 1).padding(.horizontal, -3)
        }
        .padding(.horizontal, Theme.Inspector.edge)
        // No margin of its own above: the titlebar's extra height already
        // sets it ~16pt under the tabs; each panel's content then starts
        // ~14pt under the rule.
        .accessibilityAddTraits(.isHeader)
    }
}

/// A label and its value on one 24pt row.
struct InspectorRow: View {
    let title: String
    let value: String
    var valueStyle: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        HStack {
            Text(title).font(.toasty(Theme.Size.control)).foregroundStyle(Theme.Sidebar.titleColor).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(value).font(.toasty(Theme.Size.control)).monospacedDigit().foregroundStyle(valueStyle)
        }
        .frame(height: Theme.Inspector.rowHeight)
    }
}

/// A thin capsule meter.
struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Fill.subtle)
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Changes

private struct ChangesTab: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var changes: GitChanges

    var body: some View {
        content
        // Keep it current while it's on screen: git status is cheap and
        // takes no locks. Also right after each turn (ClaudeConversation).
        .task(id: workspace.folder) {
            changes.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if NSApp.isActive { changes.refresh() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            switch changes.state {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notRepository:
                InspectorEmpty(symbol: "arrow.triangle.branch", title: "Not a Git Repository",
                               detail: (workspace.folder as NSString).abbreviatingWithTildeInPath)
            case .failed(let error):
                InspectorEmpty(symbol: "exclamationmark.triangle", title: "Couldn't Read Git Status", detail: error)
            case .loaded:
                loaded
            }
        }
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            BranchHeader(changes: changes, workspace: workspace)
                .padding(.horizontal, Theme.Inspector.edge)
                .padding(.top, Theme.Space.s + Theme.Space.xxs)
                .padding(.bottom, Theme.Space.m)
            Rectangle().fill(Color.claudeSeparator).frame(height: 0.5)
            if changes.files.isEmpty {
                InspectorEmpty(symbol: "checkmark.circle", title: "No Changes", detail: "The working tree matches the last commit.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(changes.files) { file in
                            ChangedFileRow(file: file, selected: workspace.diffFile?.id == file.id) {
                                workspace.diffFile = workspace.diffFile?.id == file.id ? nil : file
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Inspector.edge - Theme.Space.s)
                    .padding(.vertical, Theme.Space.s)
                }
            }
        }
    }
}

private struct BranchHeader: View {
    @ObservedObject var changes: GitChanges
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.toasty(Theme.Size.meta, .medium))
                    .foregroundStyle(.secondary)
                Text(changes.branch ?? "Detached HEAD")
                    .font(.toasty(Theme.Size.control, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)  // the name gives way, not the pill
                if workspace.isWorktree {
                    WorktreeBadge(help: worktreeHelp)
                }
                Spacer(minLength: 6)
                SyncStatus(changes: changes)
            }
            HStack(spacing: 6) {
                Text(summary)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                if !changes.files.isEmpty {
                    Text("+\(changes.totalAdded)").foregroundStyle(Color(nsColor: .systemGreen))
                        .font(.toasty(Theme.Size.meta, .medium)).monospacedDigit()
                    Text("−\(changes.totalRemoved)").foregroundStyle(Color(nsColor: .systemRed))
                        .font(.toasty(Theme.Size.meta, .medium)).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var worktreeHelp: String {
        let path = (workspace.folder as NSString).abbreviatingWithTildeInPath
        return workspace.parent.map { "Worktree of \($0.name) · \(path)" } ?? "Worktree · \(path)"
    }

    private var summary: String {
        switch changes.files.count {
        case 0: "Everything committed"
        case 1: "1 file not committed"
        case let n: "\(n) files not committed"
        }
    }
}

/// "Worktree", styled like the ahead/behind badges beside it.
private struct WorktreeBadge: View {
    let help: String

    var body: some View {
        Text("Worktree")
            .font(.toasty(Theme.Size.caption, .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(Theme.Fill.subtle))
            .tooltipText(help)
    }
}

/// Whether the branch's commits are on the remote, in words: "Pushed",
/// "2 not pushed", "1 to pull", or "Not pushed" for a branch that has
/// never been pushed; and "3 behind main" when the main branch has moved on.
private struct SyncStatus: View {
    @ObservedObject var changes: GitChanges

    var body: some View {
        HStack(spacing: 4) {
            if changes.branch != nil, changes.behindBase > 0, let base = changes.base {
                pill("arrow.down", "\(changes.behindBase) behind \(GitChanges.shortName(base))",
                     help: "\(commits(changes.behindBase)) on \(base) this branch doesn't have")
            }
            if changes.branch == nil {
                EmptyView()
            } else if changes.upstream == nil {
                pill(nil, "Not pushed", help: "This branch isn't on a remote yet")
            } else if changes.ahead == 0 && changes.behind == 0 {
                pill("checkmark", "Pushed", help: "All commits are on \(changes.upstream ?? "the remote")")
            } else {
                if changes.ahead > 0 {
                    pill("arrow.up", "\(changes.ahead) not pushed",
                         help: "\(commits(changes.ahead)) not on \(changes.upstream ?? "the remote") yet")
                }
                if changes.behind > 0 {
                    pill("arrow.down", "\(changes.behind) to pull",
                         help: "\(commits(changes.behind)) on \(changes.upstream ?? "the remote") you don't have")
                }
            }
        }
    }

    private func commits(_ n: Int) -> String { n == 1 ? "1 commit" : "\(n) commits" }

    private func pill(_ symbol: String?, _ text: String, help: String) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.toasty(Theme.Glyph.small, .semibold)) }
            Text(text).font(.toasty(Theme.Size.caption, .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Theme.Fill.subtle))
        .tooltipText(help)
    }
}

private struct ChangedFileRow: View {
    let file: GitChanges.File
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StatusMark(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.toasty(Theme.Size.control, .medium))
                    .strikethrough(file.status == .deleted, color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty || file.oldPath != nil {
                    Text(file.oldPath.map { "from \($0)" } ?? file.directory)
                        .font(.toasty(Theme.Size.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                if let a = file.added, a > 0 {
                    Text("+\(a)").foregroundStyle(Color(nsColor: .systemGreen))
                }
                if let r = file.removed, r > 0 {
                    Text("−\(r)").foregroundStyle(Color(nsColor: .systemRed))
                }
                if file.added == nil && file.removed == nil {
                    Text("binary").foregroundStyle(.tertiary)
                }
            }
            .font(.toasty(Theme.Size.caption, .medium))
            .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(selected ? Theme.Fill.accent : (hovering ? Theme.Fill.hover : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .tooltipText("\(file.status.label): \(file.path)")
        .contextMenu {
            Button(selected ? "Hide Diff" : "Show Diff", action: action)
            Divider()
            Button("Open") { NSWorkspace.shared.open(file.url) }.disabled(file.status == .deleted)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                .disabled(file.status == .deleted)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.status.label) \(file.path)")
        .accessibilityAddTraits(.isButton)
    }
}

/// The file's status as a letter in its color (Xcode's source control marks).
struct StatusMark: View {
    let status: GitChanges.Status

    var body: some View {
        Text(status.mark)
            .font(.toasty(Theme.Size.caption, .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch status {
        case .added, .untracked: Color(nsColor: .systemGreen)
        case .deleted: Color(nsColor: .systemRed)
        case .renamed, .copied: Color(nsColor: .systemBlue)
        case .conflicted: Color(nsColor: .systemOrange)
        case .modified, .typeChanged: Color(nsColor: .systemOrange)
        }
    }
}

// MARK: - Diff page (in the conversation column)

/// A changed file's diff against the last commit, in place of the
/// conversation until closed (Esc or the back button).
struct DiffPage: View {
    let file: GitChanges.File
    /// Every changed file, for the previous / next buttons.
    var files: [GitChanges.File] = []
    var select: (GitChanges.File) -> Void = { _ in }
    let close: () -> Void
    @State private var lines: [DiffLine]?

    private static let maxLines = 8000

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            if let lines {
                if lines.isEmpty {
                    InspectorEmpty(symbol: "doc", title: "No Line Changes",
                                   detail: file.status == .renamed ? "The file was renamed without edits." : nil)
                } else {
                    DiffTextView(lines: Array(lines.prefix(Self.maxLines)), path: file.path)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.claudeBackground)
        .task(id: file) {
            lines = nil
            let f = file
            lines = await Task.detached(priority: .userInitiated) { GitChanges.diffLines(f) }.value
        }
    }

    private var position: Int? { files.firstIndex { $0.id == file.id } }

    private func step(_ by: Int) {
        guard let i = position, files.indices.contains(i + by) else { return }
        select(files[i + by])
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.toasty(Theme.Size.meta, .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .tooltip("Back to Conversation", shortcut: "esc")
            .accessibilityLabel("Back to Conversation")

            StatusMark(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.toasty(Theme.Size.control, .semibold)).lineLimit(1)
                Text(file.directory.isEmpty ? file.status.label : "\(file.status.label) · \(file.directory)")
                    .font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let a = file.added, a > 0 {
                Text("+\(a)").foregroundStyle(Color(nsColor: .systemGreen)).font(.toasty(Theme.Size.meta, .medium)).monospacedDigit()
            }
            if let r = file.removed, r > 0 {
                Text("−\(r)").foregroundStyle(Color(nsColor: .systemRed)).font(.toasty(Theme.Size.meta, .medium)).monospacedDigit()
            }
            if files.count > 1, let i = position {
                Text("\(i + 1) of \(files.count)")
                    .font(.toasty(Theme.Size.meta)).foregroundStyle(.tertiary).monospacedDigit()
                    .padding(.leading, Theme.Space.s)
                HStack(spacing: 0) {
                    BarIconButton(symbol: "chevron.up",
                                  tooltip: Tooltip(title: "Previous File", shortcut: "⌃⌘↑")) { step(-1) }
                        .disabled(i == 0)
                        .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                    BarIconButton(symbol: "chevron.down",
                                  tooltip: Tooltip(title: "Next File", shortcut: "⌃⌘↓")) { step(1) }
                        .disabled(i == files.count - 1)
                        .keyboardShortcut(.downArrow, modifiers: [.control, .command])
                }
            }
            if file.status != .deleted {
                BarIconButton(symbol: "arrow.up.forward.app",
                              tooltip: Tooltip(title: "Open in Default App", detail: file.path)) {
                    NSWorkspace.shared.open(file.url)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

// MARK: - Terminal strip

/// The top of the terminal half: the workspace's terminal tabs, and a
/// button to hide the terminal.
struct TerminalStrip: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        // The card's raised surface (the terminal's background).
        ZStack {
            Color(nsColor: NSColor(name: nil) { a in
                let t = TerminalTheme.current(for: a)
                return NSColor(cgColor: t.background.cgColor) ?? .windowBackgroundColor
            })
            if let workspace = store.active {
                TerminalStripContent(workspace: workspace)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
    }
}

private struct TerminalStripContent: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            TerminalTabBar(workspace: workspace)
            BarIconButton(symbol: "chevron.down",
                          tooltip: Tooltip(title: "Hide Terminal", shortcut: "⌃⌘T",
                                           detail: "The inspector takes the whole column."),
                          size: CGSize(width: 32, height: TabStyle.height)) { workspace.hideTerminal() }
                .padding(.trailing, TitlebarRow.edge)
        }
    }
}
