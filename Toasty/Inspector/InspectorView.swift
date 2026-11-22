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

    /// Rows listed; past this (a dependency folder that isn't ignored
    /// yet) the list ends with how many more there are.
    private static let maxRows = 500

    private var loaded: some View {
        VStack(spacing: 0) {
            BranchSummary(changes: changes, workspace: workspace)
            if changes.files.isEmpty {
                InspectorEmpty(symbol: "checkmark.circle", title: "No Changes", detail: "The working tree matches the last commit.")
            } else {
                ScrollView {
                    InspectorListSection(title: "Uncommitted", count: changes.files.count) {
                        LazyVStack(spacing: 0) {
                            ForEach(changes.files.prefix(Self.maxRows)) { file in
                                ChangedFileRow(file: file, selected: workspace.diffFile?.id == file.id) {
                                    workspace.diffFile = workspace.diffFile?.id == file.id ? nil : file
                                }
                            }
                            if changes.files.count > Self.maxRows {
                                let more = changes.files.count - Self.maxRows
                                InspectorRow(label: Text(more == 1 ? "1 more file" : "\(more.formatted()) more files")
                                                .font(.toasty(Theme.Size.control))
                                                .foregroundColor(.secondary)) {
                                    // Keeps the label on the rows' text edge.
                                    Color.clear
                                } trailing: {
                                    EmptyView()
                                }
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.l)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

/// The summary row: the branch, whether it's on the remote (chips at the
/// right), and what isn't committed.
private struct BranchSummary: View {
    @ObservedObject var changes: GitChanges
    let workspace: Workspace

    var body: some View {
        InspectorSummary(title: changes.branch ?? "Detached HEAD", detail: detail) {
            InspectorGlyph(symbol: "arrow.triangle.branch")
        } trailing: {
            HStack(spacing: Theme.Space.xs) {
                if workspace.isWorktree {
                    InspectorChip(text: "Worktree").tooltipText(worktreeHelp)
                }
                SyncStatus(changes: changes)
            }
        }
    }

    private var detail: Text {
        let summary: String = switch changes.files.count {
        case 0: "Everything committed"
        case 1: "1 file not committed"
        case let n: "\(n) files not committed"
        }
        guard !changes.files.isEmpty else { return Text(summary) }
        let mono = Font.toasty(Theme.Size.meta, design: .monospaced)
        return Text(summary + " · ")
            + Text("+\(changes.totalAdded)").font(mono).foregroundColor(Theme.Inspector.added)
            + Text(" ")
            + Text("−\(changes.totalRemoved)").font(mono).foregroundColor(Theme.Inspector.removed)
    }

    private var worktreeHelp: String {
        let path = (workspace.folder as NSString).abbreviatingWithTildeInPath
        return workspace.parent.map { "Worktree of \($0.name) · \(path)" } ?? "Worktree · \(path)"
    }
}

/// Whether the branch's commits are on the remote, as chips: "Pushed",
/// "2 Not Pushed", "1 to Pull", or "Not Pushed" for a branch that has
/// never been pushed; and "3 Behind main" when the main branch has moved on.
private struct SyncStatus: View {
    @ObservedObject var changes: GitChanges

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if changes.branch != nil, changes.behindBase > 0, let base = changes.base {
                chip("arrow.down", "\(changes.behindBase) Behind \(GitChanges.shortName(base))",
                     help: "\(commits(changes.behindBase)) on \(base) this branch doesn't have")
            }
            if changes.branch == nil {
                EmptyView()
            } else if changes.upstream == nil {
                chip(nil, "Not Pushed", help: "This branch isn't on a remote yet")
            } else if changes.ahead == 0 && changes.behind == 0 {
                chip(nil, "Pushed", help: "All commits are on \(changes.upstream ?? "the remote")")
            } else {
                if changes.ahead > 0 {
                    chip("arrow.up", "\(changes.ahead) Not Pushed",
                         help: "\(commits(changes.ahead)) not on \(changes.upstream ?? "the remote") yet")
                }
                if changes.behind > 0 {
                    chip("arrow.down", "\(changes.behind) to Pull",
                         help: "\(commits(changes.behind)) on \(changes.upstream ?? "the remote") you don't have")
                }
            }
        }
    }

    private func commits(_ n: Int) -> String { n == 1 ? "1 commit" : "\(n) commits" }

    private func chip(_ symbol: String?, _ text: String, help: String) -> some View {
        InspectorChip(text: text, symbol: symbol).tooltipText(help)
    }
}

/// A changed file: its letter, its name with the folder inline after it,
/// and its line counts.
private struct ChangedFileRow: View {
    let file: GitChanges.File
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let deleted = file.status == .deleted
        InspectorRow(label: Text(file.name)
                        .font(.toasty(Theme.Size.control))
                        .foregroundColor(deleted ? .secondary : .primary)
                        .strikethrough(deleted, color: Color.primary.opacity(0.25)),
                     detail: file.oldPath.map { "from \($0)" } ?? (file.directory.isEmpty ? nil : file.directory),
                     selected: selected, hoverable: true) {
            ChangeLetter(status: file.status)
        } trailing: {
            if file.added == nil && file.removed == nil {
                Text("binary").font(.toasty(Theme.Size.meta, design: .monospaced)).foregroundStyle(.tertiary)
            } else {
                DiffCounts(added: file.added, removed: file.removed)
            }
        }
        .onTapGesture(perform: action)
        .tooltipText("\(file.status.label): \(file.path)")
        .contextMenu {
            Button(selected ? "Hide Diff" : "Show Diff", action: action)
            Divider()
            Button("Open") { NSWorkspace.shared.open(file.url) }.disabled(deleted)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                .disabled(deleted)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            if let lines {
                if lines.isEmpty {
                    InspectorEmpty(symbol: "doc", title: "No Line Changes",
                                   detail: file.status == .renamed ? "The file was renamed without edits." : nil)
                } else {
                    DiffTextView(lines: lines, path: file.path)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.claudeBackground)
        .task(id: file) {
            lines = nil
            let f = file
            let loaded = await Task.detached(priority: .userInitiated) { GitChanges.diffLines(f) }.value
            // Another file was chosen while this one loaded.
            guard !Task.isCancelled else { return }
            lines = loaded
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

            ChangeLetter(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.toasty(Theme.Size.control, .semibold)).lineLimit(1)
                Text(file.directory.isEmpty ? file.status.label : "\(file.status.label) · \(file.directory)")
                    .font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            DiffCounts(added: file.added, removed: file.removed)
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
