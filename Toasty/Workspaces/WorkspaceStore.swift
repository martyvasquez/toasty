import AppKit
import Combine

/// A heading in the workspaces sidebar (as in Things): the workspaces below
/// it, up to the next heading, are under it.
struct WorkspaceHeading: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Its icon (one of `HeadingStyle.icons`) and color; nil is the
    /// default (Things' area: a gray cube). Older saves have neither.
    var icon: String? = nil
    var color: HeadingColor? = nil
}

/// A heading's color: Things' sidebar palette, nothing else.
enum HeadingColor: String, Codable, CaseIterable, Identifiable {
    case gray, blue, yellow, red, teal, tan, green, silver
    var id: String { rawValue }

    var name: String {
        switch self {
        case .gray: "Gray"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .red: "Red"
        case .teal: "Teal"
        case .tan: "Tan"
        case .green: "Green"
        case .silver: "Silver"
        }
    }
}

/// The icons a heading can have (filled, so they carry their color as
/// Things' sidebar icons do), the first being the default.
enum HeadingStyle {
    static let icons = [
        "shippingbox", "folder.fill", "tray.fill", "briefcase.fill",
        "building.2.fill", "person.2.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "star.fill", "flag.fill", "bolt.fill", "flame.fill",
        "leaf.fill", "book.closed.fill", "archivebox.fill", "sparkles",
    ]
    static var defaultIcon: String { icons[0] }
}

/// A top-level row of the workspaces sidebar.
enum SidebarItem: Hashable {
    case heading(UUID)
    case workspace(UUID)
    /// Where the workspaces under no heading start: below every heading's
    /// (only when there are headings). Drawn as the gap before them.
    case loose

    /// The no-heading section's id, for dropping onto it.
    static let looseID = UUID(uuidString: "00000000-0000-0000-0000-00000000100E")!
    /// A workspace's `headingID` when it's under no heading at the top,
    /// above every heading (nil: under no heading at the bottom).
    static let topID = UUID(uuidString: "00000000-0000-0000-0000-00000000100F")!

    var id: UUID {
        switch self {
        case .heading(let id), .workspace(let id): id
        case .loose: Self.looseID
        }
    }
}

/// All workspaces, which one is shown, and the window's layout; persisted to
/// `~/Library/Application Support/<app name>/state.json`.
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [Workspace] = []
    /// The sidebar's headings, in order. Workspaces under no heading come
    /// first, then each heading's.
    @Published private(set) var headings: [WorkspaceHeading] = []
    @Published private(set) var activeID: UUID?
    @Published var sidebarVisible = true
    /// Width of the workspaces sidebar (kept when the user drags its edge;
    /// a double-click there puts it back to the default).
    var sidebarWidth: CGFloat = WorkspaceStore.defaultSidebarWidth
    static let defaultSidebarWidth: CGFloat = 250
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...400
    /// Width of the right column and the inspector's share of its height:
    /// the same for every workspace, so switching never resizes anything.
    var rightColumnWidth: CGFloat = WorkspaceStore.defaultRightColumnWidth
    static let defaultRightColumnWidth: CGFloat = 400
    var inspectorFraction: CGFloat = 0.55
    /// The workspace or heading whose name is being edited in the sidebar.
    @Published var renamingID: UUID?
    /// The heading whose icon and color are being picked (its popover open).
    @Published var stylingID: UUID?
    /// The workspace or heading being dragged in the sidebar.
    @Published var draggingID: UUID?
    /// Worktrees being created (placeholder rows in the sidebar).
    @Published var pendingWorktrees: [PendingWorktree] = []
    var windowFrame: NSRect?

    /// The active workspace or its selection changed (window title, focus).
    let selectionChanged = PassthroughSubject<Void, Never>()

    var active: Workspace? { workspaces.first { $0.id == activeID } }

    // MARK: Persistence

    struct Saved: Codable {
        var workspaces: [Workspace.Saved]
        var activeWorkspace: UUID?
        var sidebarVisible: Bool
        var sidebarWidth: Double?
        var rightColumnWidth: Double?
        var inspectorFraction: Double?
        var windowFrame: String?
        var headings: [WorkspaceHeading]?
    }

    static var stateURL: URL {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Toasty"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        return dir.appendingPathComponent("state.json")
    }

    private var saveScheduled = false
    private var loading = false

    /// No state.json yet: Toasty's first launch.
    private(set) var isFirstLaunch = false

    func load() {
        isFirstLaunch = !FileManager.default.fileExists(atPath: Self.stateURL.path)
        loading = true
        defer { loading = false }
        if let data = try? Data(contentsOf: Self.stateURL),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            let loaded = s.workspaces.map { Workspace(saved: $0) }
            loaded.forEach { $0.store = self }
            // A worktree whose parent is gone stands on its own.
            for w in loaded where w.parentID != nil && !loaded.contains(where: { $0.id == w.parentID && $0.parentID == nil }) {
                w.parentID = nil
            }
            headings = s.headings ?? []
            workspaces = grouped(loaded)
            activeID = s.activeWorkspace.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
                ?? workspaces.first?.id
            sidebarVisible = s.sidebarVisible
            sidebarWidth = min(max(CGFloat(s.sidebarWidth ?? Double(Self.defaultSidebarWidth)),
                                   Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
            // Older state kept these per workspace: start from the active one's.
            let activeSaved = s.workspaces.first { $0.id == activeID } ?? s.workspaces.first
            rightColumnWidth = CGFloat(s.rightColumnWidth ?? activeSaved?.terminalWidth ?? Double(rightColumnWidth))
            inspectorFraction = CGFloat(s.inspectorFraction ?? activeSaved?.inspectorFraction ?? Double(inspectorFraction))
            windowFrame = s.windowFrame.map(NSRectFromString)
            TeeUpImages.sweep(keeping: Set(workspaces.flatMap(\.teeUpImageNames)))
        }
        if workspaces.isEmpty {
            create(folder: NSHomeDirectory(), name: "Home")
        }
        syncWorktrees()
        // Worktrees made or removed outside Toasty show up on coming back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WorkspaceStore.shared.syncWorktrees() }
        }
    }

    /// Save soon (coalesces bursts of changes).
    func setNeedsSave() {
        guard !loading, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        let s = Saved(workspaces: workspaces.map(\.saved), activeWorkspace: activeID,
                      sidebarVisible: sidebarVisible,
                      sidebarWidth: Double(sidebarWidth),
                      rightColumnWidth: Double(rightColumnWidth),
                      inspectorFraction: Double(inspectorFraction),
                      windowFrame: windowFrame.map(NSStringFromRect),
                      headings: headings.isEmpty ? nil : headings)
        do {
            let url = Self.stateURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(s).write(to: url, options: .atomic)
        } catch {
            NSLog("Toasty: couldn't save state: \(error)")
        }
    }

    func workspaceSelectionChanged(_ w: Workspace) {
        if w.id == activeID {
            selectionChanged.send()
            startShownConversation()
        }
    }

    /// Like running `claude`: a conversation's agent starts when its tab is
    /// first shown (restored tabs resume lazily, when first shown).
    func startShownConversation() {
        active?.selected?.start()
    }

    // MARK: Workspaces

    /// A new workspace: last, under no heading (a worktree: after its
    /// parent's other worktrees).
    @discardableResult
    func create(folder: String, name: String? = nil, activate: Bool = true, withConversation: Bool = true,
                parent: Workspace? = nil) -> Workspace {
        let w = Workspace(name: name ?? Self.projectName(for: URL(fileURLWithPath: folder)), folder: folder,
                          parentID: parent?.id)
        w.store = self
        if withConversation { w.newConversation() }
        var list = workspaces
        if let parent, let i = list.firstIndex(where: { $0.id == parent.id }) {
            // A worktree goes after its parent's other worktrees.
            list.insert(w, at: i + 1 + children(of: parent.id).count)
        } else {
            // A new workspace goes last, under no heading (below every
            // heading's), to be filed under one when you like.
            list.append(w)
            w.headingID = nil
        }
        workspaces = grouped(list)
        if activate { self.activate(w.id) }
        setNeedsSave()
        return w
    }

    func createWithFolderPicker() {
        chooseFolder(title: "New Workspace", prompt: "Create Workspace") { url in
            guard let url else { return }
            self.create(folder: url.path)
        }
    }

    func activate(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        renamingID = nil
        activeID = id
        selectionChanged.send()
        startShownConversation()
        setNeedsSave()
    }

    func activateRelative(_ delta: Int) {
        guard !workspaces.isEmpty else { return }
        let i = workspaces.firstIndex { $0.id == activeID } ?? 0
        activate(workspaces[(i + delta + workspaces.count) % workspaces.count].id)
    }

    func setName(_ name: String, for id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { w.name = t }
        selectionChanged.send()
        setNeedsSave()
    }

    func renameActive() {
        guard let activeID else { return }
        sidebarVisible = true
        renamingID = activeID
    }

    func chooseFolder(for id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        chooseFolder(title: "Workspace Folder", prompt: "Choose", start: w.folder) { url in
            guard let url else { return }
            let oldDefault = Self.projectName(for: URL(fileURLWithPath: w.folder))
            w.folder = url.path
            if w.name == oldDefault || w.name == "Home" { w.name = Self.projectName(for: url) }
            self.selectionChanged.send()
            self.setNeedsSave()
        }
    }

    /// Close a workspace, asking first if anything is running in it.
    func requestClose(_ id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        let all = [w] + children(of: id)
        Activity.shared.confirm(Activity.shared.closeWarning(conversations: all.flatMap(\.conversations),
                                                             terminals: all.flatMap(\.terminals), action: "close it"),
                                title: "Close “\(w.name)”?", button: "Close Workspace") { [weak self] in
            self?.close(id)
        }
    }

    /// Close a workspace and its worktrees (closing doesn't delete them:
    /// they come back with their parent).
    func close(_ id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let closing = [workspaces[i]] + children(of: id)
        closing.forEach { w in w.conversations.forEach { Activity.shared.forget($0) } }
        var list = workspaces
        list.removeAll { w in closing.contains { $0.id == w.id } }
        workspaces = list
        closing.forEach { $0.stop() }
        if let activeID, closing.contains(where: { $0.id == activeID }) {
            let next = list.isEmpty ? nil : list[min(i, list.count - 1)]
            if let parentID = closing[0].parentID {
                // A closed worktree's next sibling, else its parent.
                self.activeID = next?.parentID == parentID ? next?.id : parentID
            } else {
                self.activeID = next?.id
            }
            selectionChanged.send()
        }
        setNeedsSave()
    }

    // MARK: Worktrees

    /// The worktrees shown under a workspace, in order.
    func children(of id: UUID) -> [Workspace] { workspaces.filter { $0.parentID == id } }

    /// Each top-level workspace followed by its worktrees, in sidebar order:
    /// each heading's, then those under no heading (keeping their order
    /// within a section).
    private func grouped(_ list: [Workspace]) -> [Workspace] {
        let tops = list.filter { $0.parentID == nil }
        let known = Set(headings.map(\.id) + [SidebarItem.topID])
        for w in tops where w.headingID.map({ !known.contains($0) }) == true { w.headingID = nil }
        let sections: [UUID?] = [SidebarItem.topID] + headings.map(\.id) + [nil]
        return sections.flatMap { h in tops.filter { $0.headingID == h } }
            .flatMap { top in [top] + list.filter { $0.parentID == top.id } }
    }

    /// A workspace's top-level workspace (itself or its parent).
    private func top(_ id: UUID) -> UUID? {
        workspaces.first { $0.id == id }.map { $0.parentID ?? $0.id }
    }

    // MARK: Order

    // Only top-level workspaces move; their worktrees move with them. A
    // workspace moved past a heading goes under it (or out from under it).

    /// The sidebar's top level in order: workspaces under no heading at
    /// the top, each heading followed by its workspaces, then (marked by
    /// `.loose`) those under no heading at the bottom.
    var items: [SidebarItem] {
        let tops = workspaces.filter { $0.parentID == nil }
        let above = tops.filter { $0.headingID == SidebarItem.topID }.map { SidebarItem.workspace($0.id) }
        let loose = tops.filter { $0.headingID == nil }.map { SidebarItem.workspace($0.id) }
        guard !headings.isEmpty else { return above + loose }
        return above + headings.flatMap { h in
            [.heading(h.id)] + tops.filter { $0.headingID == h.id }.map { .workspace($0.id) }
        } + [.loose] + loose
    }

    /// Take `items` as the new order: each workspace goes under the heading
    /// above it.
    private func apply(_ items: [SidebarItem]) {
        // Above the first heading: the top section (with no headings at
        // all, there's just the one, under no heading).
        let hasHeadings = items.contains { if case .heading = $0 { true } else { false } }
        var heading: UUID? = hasHeadings ? SidebarItem.topID : nil
        var order: [UUID] = []
        var tops: [UUID] = []
        for item in items {
            switch item {
            case .heading(let id):
                heading = id
                order.append(id)
            case .workspace(let id):
                workspaces.first { $0.id == id }?.headingID = heading
                tops.append(id)
            case .loose:
                heading = nil
            }
        }
        headings = order.compactMap { id in headings.first { $0.id == id } }
        workspaces = tops.flatMap { id in workspaces.filter { $0.id == id || $0.parentID == id } }
        setNeedsSave()
    }

    func isHeading(_ id: UUID) -> Bool { headings.contains { $0.id == id } }

    /// Move a workspace to where `target` (a workspace or a heading) is,
    /// as when dragging it there.
    func move(_ id: UUID, to target: UUID) {
        // Onto the no-heading section: first under no heading.
        if target == SidebarItem.looseID {
            guard let id = top(id) else { return }
            var items = items
            guard let from = items.firstIndex(of: .workspace(id)) else { return }
            items.remove(at: from)
            if let i = items.firstIndex(of: .loose) { items.insert(.workspace(id), at: i + 1) } else { items.insert(.workspace(id), at: 0) }
            apply(items)
            return
        }
        guard let id = top(id), let target = isHeading(target) ? target : top(target), id != target else { return }
        var items = items
        guard let from = items.firstIndex(of: .workspace(id)),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        apply(items)
    }

    func moveToEnd(_ id: UUID) {
        if isHeading(id) {
            guard let from = headings.firstIndex(where: { $0.id == id }), from != headings.count - 1 else { return }
            moveHeading(id, by: headings.count - 1 - from)
            return
        }
        guard let id = top(id) else { return }
        var items = items
        guard let from = items.firstIndex(of: .workspace(id)), from != items.count - 1 else { return }
        items.append(items.remove(at: from))
        apply(items)
    }

    /// Move a workspace one row up or down (past a heading, it changes
    /// heading).
    func move(_ id: UUID, by delta: Int) {
        var items = items
        guard let from = items.firstIndex(of: .workspace(id)), items.indices.contains(from + delta) else { return }
        items.swapAt(from, from + delta)
        apply(items)
    }

    /// Whether `move(id, by: delta)` would do anything.
    func canMove(_ id: UUID, by delta: Int) -> Bool {
        guard let from = items.firstIndex(of: .workspace(id)) else { return false }
        return items.indices.contains(from + delta)
    }

    /// Put a workspace last under a heading (nil: under none).
    func move(_ id: UUID, toHeading heading: UUID?) {
        guard let id = top(id), let w = workspaces.first(where: { $0.id == id }) else { return }
        w.headingID = heading
        workspaces = grouped(workspaces.filter { $0.id != id } + [w])
        setNeedsSave()
    }

    // MARK: Worktree order

    func isWorktree(_ id: UUID) -> Bool { workspaces.first { $0.id == id }?.parentID != nil }

    /// Move a worktree to where `target` is, among its own workspace's
    /// worktrees (its parent's row: first). Anywhere else, it stays.
    func moveWorktree(_ id: UUID, to target: UUID) {
        guard id != target, let w = workspaces.first(where: { $0.id == id }), let parent = w.parentID else { return }
        var siblings = children(of: parent).map(\.id)
        guard let from = siblings.firstIndex(of: id) else { return }
        let to: Int
        if target == parent { to = 0 }
        else if let i = siblings.firstIndex(of: target) { to = i }
        else { return }
        guard to != from else { return }
        siblings.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        reorderWorktrees(of: parent, siblings)
    }

    func moveWorktree(_ id: UUID, by delta: Int) {
        guard let parent = workspaces.first(where: { $0.id == id })?.parentID else { return }
        var siblings = children(of: parent).map(\.id)
        guard let from = siblings.firstIndex(of: id), siblings.indices.contains(from + delta) else { return }
        siblings.swapAt(from, from + delta)
        reorderWorktrees(of: parent, siblings)
    }

    func canMoveWorktree(_ id: UUID, by delta: Int) -> Bool {
        guard let parent = workspaces.first(where: { $0.id == id })?.parentID else { return false }
        let siblings = children(of: parent).map(\.id)
        guard let from = siblings.firstIndex(of: id) else { return false }
        return siblings.indices.contains(from + delta)
    }

    /// Put a workspace's worktrees in this order (they follow it).
    private func reorderWorktrees(of parent: UUID, _ order: [UUID]) {
        let others = workspaces.filter { $0.parentID != parent }
        let kids = order.compactMap { id in workspaces.first { $0.id == id } }
        var list = others
        if let i = list.firstIndex(where: { $0.id == parent }) { list.insert(contentsOf: kids, at: i + 1) }
        workspaces = grouped(list)
        setNeedsSave()
    }

    // MARK: Headings

    /// A new heading, named in place: at the end, or above a workspace
    /// (taking it and the ones below it in its section).
    func newHeading(above id: UUID? = nil) {
        let h = WorkspaceHeading(id: UUID(), name: "New Heading")
        var items = items
        if let id, let top = top(id), let i = items.firstIndex(of: .workspace(top)) {
            items.insert(.heading(h.id), at: i)
        } else {
            items.append(.heading(h.id))
        }
        headings.append(h)
        apply(items)
        sidebarVisible = true
        renamingID = h.id
    }

    func setHeadingName(_ name: String, for id: UUID) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = headings.firstIndex(where: { $0.id == id }) else { return }
        headings[i].name = t
        setNeedsSave()
    }

    /// A heading's icon and color (nil: the default).
    func setHeadingStyle(icon: String?, color: HeadingColor?, for id: UUID) {
        guard let i = headings.firstIndex(where: { $0.id == id }) else { return }
        headings[i].icon = icon == HeadingStyle.defaultIcon ? nil : icon
        headings[i].color = color == .gray ? nil : color
        setNeedsSave()
    }

    /// Remove a heading; its workspaces join the section above (under the
    /// first heading: the top one, under no heading).
    func removeHeading(_ id: UUID) {
        apply(items.filter { $0 != .heading(id) })
    }

    /// Move a heading (with its workspaces) past `delta` others.
    func moveHeading(_ id: UUID, by delta: Int) {
        guard let from = headings.firstIndex(where: { $0.id == id }), headings.indices.contains(from + delta) else { return }
        var list = headings
        list.insert(list.remove(at: from), at: from + delta)
        headings = list
        workspaces = grouped(workspaces)
        setNeedsSave()
    }

    func canMoveHeading(_ id: UUID, by delta: Int) -> Bool {
        guard let from = headings.firstIndex(where: { $0.id == id }) else { return false }
        return headings.indices.contains(from + delta)
    }

    /// Move a heading to where `target` is, as when dragging it there: a
    /// heading, or a workspace (standing for its heading; one under no
    /// heading means the top).
    func moveHeading(_ id: UUID, to target: UUID) {
        guard let from = headings.firstIndex(where: { $0.id == id }) else { return }
        // Onto the no-heading section at the bottom (or a workspace in
        // it): the heading goes last, just above it. Onto a workspace in
        // the top one: first, just below it.
        let targetSection = isHeading(target) ? target : top(target).flatMap { t in workspaces.first { $0.id == t }?.headingID }
        if target == SidebarItem.looseID || (!isHeading(target) && targetSection == nil) {
            moveHeading(id, by: headings.count - 1 - from)
            return
        }
        if targetSection == SidebarItem.topID {
            moveHeading(id, by: -from)
            return
        }
        let targetHeading = isHeading(target) ? target : top(target).flatMap { t in workspaces.first { $0.id == t }?.headingID }
        let to = targetHeading.flatMap { t in headings.firstIndex { $0.id == t } } ?? 0
        guard to != from else { return }
        moveHeading(id, by: to - from)
    }

    // MARK: Attention

    /// The latest conversation needing the user (waiting first, then
    /// finished unseen), anywhere.
    func jumpToAttention() {
        Activity.shared.jumpToLatest()
    }

    // MARK: Opening folders (Services, `open -a Toasty <dir>`, Finder, Dock)

    /// A new tab in the workspace whose folder is, or contains, `path`
    /// (deepest wins), working in `path`; or a new workspace for it.
    func openFolder(_ path: String) {
        let target = Self.normalize(path)
        let match = workspaces
            .filter { Self.isPath(target, inside: $0.folder) }
            .max { Self.normalize($0.folder).count < Self.normalize($1.folder).count }
        if let match {
            activate(match.id)
            match.newConversation(cwd: target)
        } else {
            create(folder: target)
        }
    }

    nonisolated static func normalize(_ path: String) -> String {
        let p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    static func isPath(_ path: String, inside folder: String) -> Bool {
        let p = normalize(path), f = normalize(folder)
        return p == f || p.hasPrefix(f == "/" ? "/" : f + "/")
    }

    /// A workspace name for a folder: the git repository's name if the
    /// folder is inside one, otherwise the folder's own name.
    static func projectName(for url: URL) -> String {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                let repo = dir.lastPathComponent
                let leaf = url.standardizedFileURL.lastPathComponent
                return repo == leaf ? repo : "\(repo)/\(leaf)"
            }
            dir.deleteLastPathComponent()
        }
        return url.lastPathComponent
    }

    private func chooseFolder(title: String, prompt: String, start: String? = nil, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: start ?? active?.folder ?? NSHomeDirectory())
        let handler: (NSApplication.ModalResponse) -> Void = { completion($0 == .OK ? panel.url : nil) }
        if let window = AppDelegate.shared.windowController?.window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }
}
