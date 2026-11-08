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
                        WorkspaceRow(workspace: w, index: i, store: store)
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
private let worktreeIndent: CGFloat = 16

/// A worktree being created.
private struct PendingWorktreeRow: View {
    let name: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 18)
                Text("Creating worktree…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.leading, 8 + worktreeIndent)
        .padding(.trailing, 8)
        .transition(.opacity)
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    let index: Int
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var activity: Activity = .shared

    @State private var hovering = false
    @State private var draft = ""
    @State private var pulse = false
    @FocusState private var fieldFocused: Bool

    private var isActive: Bool { store.activeID == workspace.id }
    private var isRenaming: Bool { store.renamingID == workspace.id }
    private var waiting: Bool { workspace.needsAttention }
    private var working: Bool { workspace.isWorking }
    private var attention: Bool { workspace.hasAttention }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingIcon.frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if isRenaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
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
                            .font(.system(size: 13, weight: isActive ? .medium : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if hovering && index < 9 && !isRenaming {
                        Text("⌥\(index + 1)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else if workspace.conversations.count > 1 {
                        Text("\(workspace.conversations.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .help("\(workspace.conversations.count) conversations")
                    }
                }
                .frame(height: 18)

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(subtitle(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(waiting ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(working || waiting || attention ? .tail : .middle)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 8 + (workspace.isWorktree ? worktreeIndent : 0))
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isActive ? 0.10 : (hovering ? 0.05 : 0)))
        )
        .contentShape(Rectangle())
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

    /// What Claude is doing here: working (and for how long), what it's
    /// waiting on, or what finished while you weren't looking; else the
    /// folder.
    private func subtitle(now: Date) -> String {
        let conversations = workspace.conversations
        if waiting {
            let asking = conversations.filter { !$0.requests.isEmpty }
            return activity.latestMessage(asking) ?? "Waiting for you"
        }
        if working {
            guard let since = activity.workingSince(conversations) else { return "Working…" }
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return minutes < 1 ? "Working…" : "Working · \(Self.duration(minutes))"
        }
        if attention, let message = activity.latestMessage(conversations.filter(\.attention)) {
            return message
        }
        return (workspace.folder as NSString).abbreviatingWithTildeInPath
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Claude's status when there is one, else the folder.
    @ViewBuilder private var leadingIcon: some View {
        if waiting {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .opacity(pulse ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
                .onDisappear { pulse = false }
                .help("Claude is waiting for you")
        } else if working {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                .help("Claude is working")
        } else if attention {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                .help("Something finished in this workspace")
        } else {
            Image(systemName: workspace.isWorktree ? "arrow.triangle.branch" : "folder")
                .font(.system(size: 12.5))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
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
