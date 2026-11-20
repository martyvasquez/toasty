import SwiftUI
import UniformTypeIdentifiers

/// The workspaces sidebar (the split view's sidebar item, which provides the
/// native sidebar material and runs under the window buttons).
struct WorkspaceSidebarView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.items, id: \.self) { item in
                        switch item {
                        case .heading(let id):
                            if let heading = store.headings.first(where: { $0.id == id }) {
                                HeadingRow(heading: heading, store: store, first: item == store.items.first)
                                    .opacity(store.draggingID == id ? 0.35 : 1)
                                    .onDrag { drag(id) }
                                    .onDrop(of: [.toastyWorkspace], delegate: WorkspaceDropDelegate(target: id, store: store))
                            }
                        case .workspace(let id):
                            // The workspace, then its worktrees.
                            ForEach(store.workspaces.filter { $0.id == id || $0.parentID == id }) { w in
                                WorkspaceRow(workspace: w, store: store)
                                    .opacity(dimmed(w) ? 0.35 : 1)
                                    // A worktree drags its parent (they move together).
                                    .onDrag { drag(id) }
                                    .onDrop(of: [.toastyWorkspace], delegate: WorkspaceDropDelegate(target: w.id, store: store))
                            }
                            // Worktrees being created.
                            ForEach(store.pendingWorktrees.filter { $0.parentID == id }) { p in
                                PendingWorktreeRow(name: p.name)
                            }
                        }
                    }
                    // Dropping below the last workspace moves it to the end.
                    Color.clear
                        .frame(height: 40)
                        .contentShape(Rectangle())
                        .onDrop(of: [.toastyWorkspace], delegate: WorkspaceDropDelegate(target: nil, store: store))
                        .contextMenu {
                            Button("New Heading") { store.newHeading() }
                        }
                }
                .padding(.horizontal, Theme.Sidebar.inset)
                .animation(.easeInOut(duration: 0.15), value: store.items)
                .animation(.easeInOut(duration: 0.15), value: store.workspaces.map(\.id))
            }
            .scrollIndicators(.never)
            // Measured from the window's top, as Things: the first row's
            // middle sits 47pt below the window buttons'.
            .contentMargins(.top, Theme.Sidebar.listTop, for: .scrollContent)
            .ignoresSafeArea(.container, edges: .top)

            SidebarFooter(store: store)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func drag(_ id: UUID) -> NSItemProvider {
        store.draggingID = id
        return NSItemProvider(item: id.uuidString.data(using: .utf8) as NSData?,
                              typeIdentifier: UTType.toastyWorkspace.identifier)
    }

    /// Whether a workspace's row is dimmed: it's being dragged, with its
    /// parent, or under a heading being dragged.
    private func dimmed(_ w: Workspace) -> Bool {
        guard let dragging = store.draggingID else { return false }
        let top = w.parent ?? w
        return dragging == top.id || dragging == top.headingID
    }
}

/// The sidebar's footer, as Things': New Workspace on the left (glyph and
/// words), New Heading on the right, above a hairline.
private struct SidebarFooter: View {
    @ObservedObject var store: WorkspaceStore
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            HStack(spacing: 0) {
                Button { store.createWithFolderPicker() } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "plus").font(.toasty(Theme.Size.control, .medium))
                        Text("New Workspace").font(.toasty(Theme.Size.body))
                    }
                    .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, Theme.Space.s + Theme.Space.xxs)
                    .frame(height: 28)
                    .contentShape(Capsule())
                }
                .buttonStyle(BarButtonStyle(hovering: hovering))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .tooltip(Tooltip(title: "New Workspace", shortcut: "⌘N",
                                 detail: "You can also drop a folder on Toasty in the Dock."))
                .accessibilityLabel("New Workspace")
                // The glyph, not its capsule, sits on the names' edge.
                .padding(.leading, Theme.Sidebar.inset + Theme.Sidebar.rowLeading - (Theme.Space.s + Theme.Space.xxs))
                Spacer(minLength: 0)
                BarIconButton(symbol: "text.badge.plus",
                              tooltip: Tooltip(title: "New Heading", shortcut: "⌥⌘N",
                                               detail: "Group your workspaces by client, project or stage."),
                              size: CGSize(width: 32, height: 28)) { store.newHeading() }
                    // Its glyph ends where the rows' ⌘-numbers do.
                    .padding(.trailing, Theme.Sidebar.inset + Theme.Sidebar.rowTrailing - (32 - 16) / 2)
            }
            .frame(height: Theme.Sidebar.footerHeight)
        }
    }
}

/// A heading over a group of workspaces (as in Things): its name in the
/// accent color over a hairline.
private struct HeadingRow: View {
    let heading: WorkspaceHeading
    @ObservedObject var store: WorkspaceStore
    /// The sidebar's first row (no space above).
    let first: Bool

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var isRenaming: Bool { store.renamingID == heading.id }

    /// The accent color, softened on dark backgrounds (as Things does).
    private var color: Color {
        colorScheme == .dark ? Color.accentColor.mix(with: .white, by: 0.35) : .accentColor
    }

    var body: some View {
        // A row like the workspaces' (as Things' areas in its sidebar): the
        // same height, no rule; groups are set apart by the space above.
        Group {
                if isRenaming {
                    TextField("Heading", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { store.renamingID = nil }
                        .onAppear {
                            draft = heading.name
                            DispatchQueue.main.async { fieldFocused = true }
                        }
                        .onChange(of: fieldFocused) { _, focused in if !focused && isRenaming { commit() } }
                } else {
                    Text(heading.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        .font(.toasty(Theme.Size.body, .semibold))  // Things' area titles: 600
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Sidebar.rowHeight)
        .padding(.leading, Theme.Sidebar.rowLeading)
        .padding(.trailing, Theme.Sidebar.rowTrailing)
        .padding(.top, first ? 0 : Theme.Sidebar.headingSpaceAbove)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.renamingID = heading.id }
        .contextMenu {
            Button("Rename…") { store.renamingID = heading.id }
            Divider()
            Button("Move Up") { store.moveHeading(heading.id, by: -1) }
                .disabled(!store.canMoveHeading(heading.id, by: -1))
            Button("Move Down") { store.moveHeading(heading.id, by: 1) }
                .disabled(!store.canMoveHeading(heading.id, by: 1))
            Divider()
            Button("Remove Heading") { store.removeHeading(heading.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func commit() {
        store.setHeadingName(draft, for: heading.id)
        store.renamingID = nil
    }
}


/// A worktree being created.
private struct PendingWorktreeRow: View {
    let name: String

    var body: some View {
        HStack(spacing: Theme.Sidebar.iconGap) {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                .frame(width: WorkspaceRow.branchWidth)
            Text(name)
                .font(.toasty(Theme.Size.control))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Sidebar.rowHeight)
        .help("Creating worktree…")
        .padding(.leading, Theme.Sidebar.rowLeading)
        .padding(.trailing, Theme.Sidebar.rowTrailing)
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
        HStack(spacing: Theme.Sidebar.iconGap) {
            // Names start on the headings' edge; a worktree's branch mark
            // starts where its parent's name does, and its name follows.
            if workspace.isWorktree {
                Image(systemName: "arrow.triangle.branch")
                    .font(.toasty(Theme.Sidebar.iconSize - 2))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.branchWidth)
            }

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
                        .foregroundStyle(Theme.Sidebar.titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                // The row's status at its end: how long Claude has worked,
                // then its mark (spinner, or a dot), then its ⌘-number.
                if working && !waiting {
                    // How long Claude has been at it, once it's a minute.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let minutes = workingMinutes(now: context.date), minutes > 0 {
                            Text(Self.duration(minutes))
                                .font(.toasty(Theme.Size.caption, .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
                // Its ⌘-number while it has something for you (⌘1 is the
                // first such row from the top); it takes you to the tab.
                statusMark
                // The number's slot is kept on every row, so status marks
                // line up in one column whether or not a row has a number.
                Group {
                    if let number = activity.number(for: workspace) {
                        Text("⌘\(number)")
                            .font(.toasty(Theme.Size.caption, .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .accessibilityHidden(true)
                    } else {
                        Color.clear  // an empty frame would collapse
                    }
                }
                .frame(width: Theme.Sidebar.shortcutWidth, height: 14, alignment: .trailing)
            }
        }
        .frame(height: Theme.Sidebar.rowHeight)
        .padding(.leading, Theme.Sidebar.rowLeading)
        .padding(.trailing, Theme.Sidebar.rowTrailing)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                // Editing the name looks selected too, so the field reads as one.
                .fill(isActive || isRenaming ? Theme.Fill.selected : (hovering ? Theme.Fill.hover : .clear))
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
                if !store.headings.isEmpty {
                    Menu("Move to Heading") {
                        Button("No Heading") { store.move(workspace.id, toHeading: nil) }
                            .disabled(workspace.headingID == nil)
                        Divider()
                        ForEach(store.headings) { h in
                            Button(h.name) { store.move(workspace.id, toHeading: h.id) }
                                .disabled(workspace.headingID == h.id)
                        }
                    }
                }
                Button("New Heading Above") { store.newHeading(above: workspace.id) }
                Divider()
                Button("Close Workspace") { store.requestClose(workspace.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// Things' sidebar weights at one size: workspaces as its lists (500),
    /// worktrees as its projects (400).
    private var nameFont: Font {
        .toasty(Theme.Size.body, workspace.isWorktree ? .regular : .medium)
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
    /// A worktree's branch mark's slot (its name starts after it).
    static var branchWidth: CGFloat { Theme.Sidebar.iconSize - 1 }

    /// Claude's status here, if any: waiting on you (orange), working (a
    /// spinner), finished unseen (gray; red if anything stopped with an
    /// error). Nothing when idle.
    private var statusMark: some View {
        // Each centered in the same box, so dots and the spinner share a
        // column.
        Group {
            if waiting {
                StatusDot(color: StatusColor.needsInput)
            } else if working {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else if attention {
                let done = workspace.conversations.filter(\.attention)
                StatusDot(color: done.contains(where: activity.isStopped) ? StatusColor.stopped : StatusColor.ready)
            }
        }
        .frame(width: 14, height: 14)
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

/// Reorders workspaces live as a dragged workspace passes over others (or
/// headings, as a dragged heading passes over rows).
private struct WorkspaceDropDelegate: DropDelegate {
    let target: UUID?
    let store: WorkspaceStore

    func dropEntered(info: DropInfo) {
        guard let dragging = store.draggingID else { return }
        if let target {
            if store.isHeading(dragging) { store.moveHeading(dragging, to: target) } else { store.move(dragging, to: target) }
        } else {
            store.moveToEnd(dragging)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { store.draggingID != nil }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        return true
    }
}
