import AppKit
import SwiftUI

// MARK: - Pane

/// The top of the right column: the active workspace's selected inspector
/// tab. Changes belong to the workspace; To-dos and Usage follow the
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
            case .usage:
                if let c = workspace.selected { UsageTab(conversation: c).id(c.id) } else { NoConversation() }
            }
            if !workspace.terminalVisible {
                TerminalFooter(workspace: workspace)
            }
        }
    }
}

/// Under the inspector while the terminal is hidden: one click brings it
/// back (like Xcode's debug area button).
private struct TerminalFooter: View {
    @ObservedObject var workspace: Workspace
    @State private var hovering = false

    var body: some View {
        Button {
            workspace.showTerminal()
            DispatchQueue.main.async { AppDelegate.shared.windowController?.focusTerminal() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11))
                Text("Terminal").font(.system(size: 12))
                Spacer()
                Text("⌃⌘T").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { Rectangle().fill(Color.claudeSeparator).frame(height: 0.5) }
        .help("Show Terminal (⌃⌘T)")
    }
}

private struct NoConversation: View {
    var body: some View {
        InspectorEmpty(symbol: "sparkle", title: "No Conversation", detail: "Open a tab to see its usage.")
    }
}

// MARK: - Shared pieces

/// A centered message for an empty tab.
struct InspectorEmpty: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small uppercase-free section title, like the sidebar's "Workspaces".
private struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// A thin capsule meter.
private struct Meter: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

private func formatTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
    case 10_000...: "\(n / 1000)k"
    case 1000...: String(format: "%.1fk", Double(n) / 1000)
    default: "\(n)"
    }
}

// MARK: - Changes

private struct ChangesTab: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var changes: GitChanges

    var body: some View {
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

    private var loaded: some View {
        VStack(spacing: 0) {
            BranchHeader(changes: changes, workspace: workspace)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(changes.branch ?? "Detached HEAD")
                    .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if !changes.files.isEmpty {
                    Text("+\(changes.totalAdded)").foregroundStyle(Color(nsColor: .systemGreen))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    Text("−\(changes.totalRemoved)").foregroundStyle(Color(nsColor: .systemRed))
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
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
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help(help)
    }
}

/// Whether the branch's commits are on the remote, in words: "Pushed",
/// "2 not pushed", "1 to pull", or "Not pushed" for a branch that has
/// never been pushed.
private struct SyncStatus: View {
    @ObservedObject var changes: GitChanges

    var body: some View {
        HStack(spacing: 4) {
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
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help(help)
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
                    .font(.system(size: 12.5, weight: .medium))
                    .strikethrough(file.status == .deleted, color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty || file.oldPath != nil {
                    Text(file.oldPath.map { "from \($0)" } ?? file.directory)
                        .font(.system(size: 11))
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
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .help("\(file.status.label): \(file.path)")
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
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.14)))
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
    let close: () -> Void
    @State private var lines: [(Character, String)]?

    private static let maxLines = 4000

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.claudeSeparator).frame(height: 0.5)
            if let lines {
                if lines.isEmpty {
                    InspectorEmpty(symbol: "doc", title: "No Line Changes",
                                   detail: file.status == .renamed ? "The file was renamed without edits." : nil)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ClaudeDiffView(lines: Array(lines.prefix(Self.maxLines)), maxLines: nil)
                            if lines.count > Self.maxLines {
                                Text("\(lines.count - Self.maxLines) more lines not shown")
                                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: ClaudeTypography.composerWidth + 160, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.claudeBackground)
        .task(id: file) {
            lines = nil
            let f = file
            lines = await Task.detached(priority: .userInitiated) { GitChanges.diff(f) }.value
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Back to Conversation (esc)")
            .accessibilityLabel("Back to Conversation")

            StatusMark(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(file.directory.isEmpty ? file.status.label : "\(file.status.label) · \(file.directory)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let a = file.added, a > 0 {
                Text("+\(a)").foregroundStyle(Color(nsColor: .systemGreen)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            if let r = file.removed, r > 0 {
                Text("−\(r)").foregroundStyle(Color(nsColor: .systemRed)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            if file.status != .deleted {
                Button("Open") { NSWorkspace.shared.open(file.url) }
                    .controlSize(.small)
                    .help("Open in its default app")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

// MARK: - Usage

private struct UsageTab: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        if conversation.context == nil && conversation.usage == nil && conversation.rateLimits.isEmpty {
            InspectorEmpty(symbol: "gauge.with.dots.needle.50percent", title: "No Usage Yet",
                           detail: conversation.phase == .idle && conversation.sessionID == nil
                               ? "Usage shows here once the session starts." : "Usage shows here after Claude's first reply.")
                .onAppear { conversation.refreshContextUsage() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let context = conversation.context { ContextSection(context: context) }
                    if !conversation.rateLimits.isEmpty { LimitsSection(limits: conversation.rateLimits) }
                    if let usage = conversation.usage { SessionSection(usage: usage) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { conversation.refreshContextUsage() }
        }
    }
}

private struct ContextSection: View {
    let context: ClaudeConversation.ContextUsage

    var body: some View {
        let fraction = context.maxTokens > 0 ? Double(context.totalTokens) / Double(context.maxTokens) : context.percentage / 100
        InspectorSection(title: "Context Window") {
            Text("\(formatTokens(context.totalTokens)) of \(formatTokens(context.maxTokens))")
                .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("used").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Meter(fraction: fraction, tint: fraction > 0.9 ? Color(nsColor: .systemRed)
                  : fraction > 0.75 ? Color(nsColor: .systemOrange) : .accentColor)
            let used = context.categories.filter { $0.kind == "used" && $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
            if !used.isEmpty {
                VStack(spacing: 5) {
                    ForEach(used.prefix(7)) { c in
                        HStack {
                            Text(c.name).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatTokens(c.tokens)).font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct LimitsSection: View {
    let limits: [ClaudeConversation.RateLimit]

    var body: some View {
        InspectorSection(title: "Plan Limits") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(limits) { limit in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(limit.title).font(.system(size: 12))
                            Spacer(minLength: 8)
                            if let u = limit.utilization {
                                Text("\(Int((u * 100).rounded()))%")
                                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(limit.status == "allowed" ? .secondary : .primary)
                            } else if limit.status == "rejected" {
                                Text("Limit reached").font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color(nsColor: .systemRed))
                            }
                        }
                        if let u = limit.utilization {
                            Meter(fraction: u, tint: limit.status == "rejected" ? Color(nsColor: .systemRed)
                                  : limit.status == "allowed_warning" ? Color(nsColor: .systemOrange) : .accentColor)
                        }
                        if let resets = limit.resetsAt {
                            Text("Resets \(resets.formatted(resets.timeIntervalSinceNow < 86_400 ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute()))")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

private struct SessionSection: View {
    let usage: ClaudeConversation.Usage

    var body: some View {
        InspectorSection(title: "This Session") {
            VStack(spacing: 6) {
                row("Cost (estimate)", usage.costUSD < 0.01 && usage.costUSD > 0 ? "< $0.01" : String(format: "$%.2f", usage.costUSD))
                row("Input tokens", formatTokens(usage.inputTokens))
                row("Output tokens", formatTokens(usage.outputTokens))
                row("Cache reads", formatTokens(usage.cacheReadTokens))
                row("Cache writes", formatTokens(usage.cacheWriteTokens))
                row("API time", ClaudeToolInfo.duration(Int(usage.apiDuration.rounded())))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12)).monospacedDigit()
        }
    }
}

// MARK: - Terminal strip

/// The top of the terminal half: the workspace's terminal tabs, and a
/// button to hide the terminal.
struct TerminalStrip: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            Color.claudeChrome
            if let workspace = store.active {
                TerminalStripContent(workspace: workspace)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.claudeSeparator).frame(height: 0.5) }
    }
}

private struct TerminalStripContent: View {
    @ObservedObject var workspace: Workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            TerminalTabBar(workspace: workspace)
            Button {
                workspace.hideTerminal()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.trailing, 6)
            .help("Hide Terminal (⌃⌘T)")
            .accessibilityLabel("Hide Terminal")
        }
    }
}
