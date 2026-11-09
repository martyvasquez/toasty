import SwiftUI
import UniformTypeIdentifiers

/// The workspaces sidebar (the split view's sidebar item, which provides the
/// native sidebar material and runs under the window buttons).
struct WorkspaceSidebarView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.createWithFolderPicker() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Workspace (⌘N)")
                .accessibilityLabel("New Workspace")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(store.workspaces.enumerated()), id: \.element.id) { i, w in
                        WorkspaceRow(workspace: w, store: store)
                            .opacity(store.draggingID.map { $0 == w.id || $0 == w.parentID } == true ? 0.35 : 1)
                            .onDrag {
                                // A worktree drags its parent (they move together).
                                let id = w.parentID ?? w.id
                                store.draggingID = id
                                return NSItemProvider(item: id.uuidString.data(using: .utf8) as NSData?,
                                                      typeIdentifier: UTType.toastyWorkspace.identifier)
                            }
                            .onDrop(of: [.toastyWorkspace], delegate: WorkspaceDropDelegate(target: w.id, store: store))
                        // Worktrees being created, after the last of the group.
                        if !store.pendingWorktrees.isEmpty, isLastOfGroup(i) {
                            ForEach(store.pendingWorktrees.filter { $0.parentID == (w.parentID ?? w.id) }) { p in
                                PendingWorktreeRow(name: p.name)
                            }
                        }
                    }
                    // Dropping below the last workspace moves it to the end.
                    Color.clear
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .onDrop(of: [.toastyWorkspace], delegate: WorkspaceDropDelegate(target: nil, store: store))
                }
                .padding(.horizontal, 8)
                .animation(.easeInOut(duration: 0.15), value: store.workspaces.map(\.id))
            }
            .scrollIndicators(.never)

            NotificationsSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Whether the workspace at `i` ends its group (a workspace and its
    /// worktrees).
    private func isLastOfGroup(_ i: Int) -> Bool {
        let list = store.workspaces
        return i == list.count - 1 || list[i + 1].parentID == nil
    }
}

/// How far a worktree's row is indented under its parent.
private let worktreeIndent: CGFloat = 20
/// Rows are one line: 18pt plus this above and below.
private let rowVerticalPadding: CGFloat = 5

/// A worktree being created.
private struct PendingWorktreeRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                .frame(width: 16, height: 18)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .padding(.vertical, rowVerticalPadding)
        .help("Creating worktree…")
        .padding(.leading, 8 + worktreeIndent)
        .padding(.trailing, 8)
        .transition(.opacity)
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var activity: Activity = .shared

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var isActive: Bool { store.activeID == workspace.id }
    private var isRenaming: Bool { store.renamingID == workspace.id }
    private var waiting: Bool { workspace.needsAttention }
    private var working: Bool { workspace.isWorking }
    private var attention: Bool { workspace.hasAttention }

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon.frame(width: 16, height: 18)

            HStack(spacing: 6) {
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(nameFont)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { store.renamingID = nil }
                        .onAppear {
                            draft = workspace.name
                            DispatchQueue.main.async { fieldFocused = true }
                        }
                        .onChange(of: fieldFocused) { _, focused in if !focused && isRenaming { commit() } }
                } else {
                    Text(workspace.name)
                        .font(nameFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if working && !waiting {
                    // How long Claude has been at it, once it's a minute.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let minutes = workingMinutes(now: context.date), minutes > 0 {
                            Text(Self.duration(minutes))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                } else if workspace.conversations.count > 1 {
                    Text("\(workspace.conversations.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 18)
        .padding(.vertical, rowVerticalPadding)
        .padding(.leading, 8 + (workspace.isWorktree ? worktreeIndent : 0))
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.10 : (hovering ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
        .help(help)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.renamingID = workspace.id }
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            if !isRenaming { store.activate(workspace.id) }
        })
        .contextMenu {
            if workspace.isWorktree {
                Button("Rename…") { store.renamingID = workspace.id }
                Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: workspace.folder)) }
                Divider()
                Button("Remove Worktree…") { store.requestRemoveWorktree(workspace.id) }
            } else {
                Button("New Worktree…") { store.requestNewWorktree(for: workspace.id) }
                Divider()
                Button("Rename…") { store.renamingID = workspace.id }
                Button("Change Folder…") { store.chooseFolder(for: workspace.id) }
                Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: workspace.folder)) }
                Divider()
                Button("Move Up") { store.move(workspace.id, by: -1) }
                    .disabled(!store.canMove(workspace.id, by: -1))
                Button("Move Down") { store.move(workspace.id, by: 1) }
                    .disabled(!store.canMove(workspace.id, by: 1))
                Divider()
                Button("Close Workspace") { store.requestClose(workspace.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// Workspaces are always bold; their worktrees are a step below:
    /// smaller and regular weight. Selection shows in the background.
    private var nameFont: Font {
        workspace.isWorktree ? .system(size: 12) : .system(size: 13, weight: .semibold)
    }

    private func workingMinutes(now: Date) -> Int? {
        activity.workingSince(workspace.conversations).map { Int(now.timeIntervalSince($0) / 60) }
    }

    /// The tooltip: what Claude is doing here (waiting on, working, or what
    /// finished unseen), then the folder.
    private var help: String {
        let conversations = workspace.conversations
        var status: String?
        if waiting {
            status = activity.latestMessage(conversations.filter { !$0.requests.isEmpty }) ?? "Waiting for you"
        } else if working {
            status = workingMinutes(now: .now).map { $0 > 0 ? "Working · \(Self.duration($0))" : "Working…" } ?? "Working…"
        } else if attention {
            status = activity.latestMessage(conversations.filter(\.attention))
        }
        var lines = [status, (workspace.folder as NSString).abbreviatingWithTildeInPath].compactMap { $0 }
        if conversations.count > 1 { lines.append("\(conversations.count) conversations") }
        return lines.joined(separator: "\n")
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Claude's status when there is one, else the folder.
    @ViewBuilder private var leadingIcon: some View {
        if waiting {
            StatusDot(color: StatusColor.needsInput)
        } else if working {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        } else if attention {
            // Red if anything here stopped with an error, else blue.
            let done = workspace.conversations.filter(\.attention)
            StatusDot(color: done.contains(where: activity.isStopped) ? StatusColor.stopped : StatusColor.ready)
        } else {
            Image(systemName: workspace.isWorktree ? "arrow.triangle.branch" : "folder")
                .font(.system(size: workspace.isWorktree ? 11.5 : 12.5))
                .foregroundStyle(Color.secondary)  // gray = idle; selection is the background
        }
    }

    private func commit() {
        store.setName(draft, for: workspace.id)
        store.renamingID = nil
    }
}

extension UTType {
    /// A workspace being dragged in the sidebar. A private type so a
    /// workspace dropped on a terminal can't be pasted into it as text.
    static let toastyWorkspace = UTType(exportedAs: "com.martyvasquez.toasty.workspace")
}

/// Reorders workspaces live as a dragged workspace passes over others.
private struct WorkspaceDropDelegate: DropDelegate {
    let target: UUID?
    let store: WorkspaceStore

    func dropEntered(info: DropInfo) {
        guard let dragging = store.draggingID else { return }
        if let target { store.move(dragging, to: target) } else { store.moveToEnd(dragging) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { store.draggingID != nil }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        return true
    }
}
