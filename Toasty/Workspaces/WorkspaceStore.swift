import AppKit
import Combine

/// All workspaces, which one is shown, and the window's layout; persisted to
/// `~/Library/Application Support/<app name>/state.json`.
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeID: UUID?
    @Published var sidebarVisible = true
    /// Width of the workspaces sidebar (kept when the user drags it).
    var sidebarWidth: CGFloat = 250
    /// Width of the right column and the inspector's share of its height:
    /// the same for every workspace, so switching never resizes anything.
    var rightColumnWidth: CGFloat = 400
    var inspectorFraction: CGFloat = 0.55
    /// The workspace whose name is being edited in the sidebar.
    @Published var renamingID: UUID?
    /// The workspace being dragged in the sidebar.
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
            workspaces = Self.grouped(loaded)
            activeID = s.activeWorkspace.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
                ?? workspaces.first?.id
            sidebarVisible = s.sidebarVisible
            sidebarWidth = s.sidebarWidth.map { CGFloat($0) } ?? sidebarWidth
            // Older state kept these per workspace: start from the active one's.
            let activeSaved = s.workspaces.first { $0.id == activeID } ?? s.workspaces.first
            rightColumnWidth = CGFloat(s.rightColumnWidth ?? activeSaved?.terminalWidth ?? Double(rightColumnWidth))
            inspectorFraction = CGFloat(s.inspectorFraction ?? activeSaved?.inspectorFraction ?? Double(inspectorFraction))
            windowFrame = s.windowFrame.map(NSRectFromString)
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
                      windowFrame: windowFrame.map(NSStringFromRect))
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

    @discardableResult
    func create(folder: String, name: String? = nil, activate: Bool = true, withConversation: Bool = true,
                append: Bool = false, parent: Workspace? = nil) -> Workspace {
        let w = Workspace(name: name ?? Self.projectName(for: URL(fileURLWithPath: folder)), folder: folder,
                          parentID: parent?.id)
        w.store = self
        if withConversation { w.newConversation() }
        var list = workspaces
        if let parent, let i = list.firstIndex(where: { $0.id == parent.id }) {
            // A worktree goes after its parent's other worktrees.
            list.insert(w, at: i + 1 + children(of: parent.id).count)
        } else if !append, let active, let i = list.firstIndex(where: { $0.id == (active.parentID ?? active.id) }) {
            // After the active workspace and its worktrees.
            list.insert(w, at: i + 1 + children(of: list[i].id).count)
        } else {
            list.append(w)
        }
        workspaces = list
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

    func activate(index: Int) {
        guard workspaces.indices.contains(index) else { return }
        activate(workspaces[index].id)
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

    /// Each top-level workspace followed by its worktrees.
    static func grouped(_ list: [Workspace]) -> [Workspace] {
        list.filter { $0.parentID == nil }.flatMap { top in [top] + list.filter { $0.parentID == top.id } }
    }

    /// Reorder the top-level workspaces; worktrees travel with their parent.
    private func reorder(_ tops: [UUID]) {
        workspaces = tops.flatMap { id in workspaces.filter { $0.id == id || $0.parentID == id } }
        setNeedsSave()
    }

    private var topIDs: [UUID] { workspaces.filter { $0.parentID == nil }.map(\.id) }

    /// A workspace's top-level workspace (itself or its parent).
    private func top(_ id: UUID) -> UUID? {
        workspaces.first { $0.id == id }.map { $0.parentID ?? $0.id }
    }

    // MARK: Order

    // Only top-level workspaces move; their worktrees move with them.

    func move(_ id: UUID, to target: UUID) {
        guard let id = top(id), let target = top(target), id != target else { return }
        var tops = topIDs
        guard let from = tops.firstIndex(of: id), let to = tops.firstIndex(of: target) else { return }
        tops.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        reorder(tops)
    }

    func moveToEnd(_ id: UUID) {
        guard let id = top(id) else { return }
        var tops = topIDs
        guard let from = tops.firstIndex(of: id), from != tops.count - 1 else { return }
        tops.append(tops.remove(at: from))
        reorder(tops)
    }

    func move(_ id: UUID, by delta: Int) {
        var tops = topIDs
        guard let from = tops.firstIndex(of: id), tops.indices.contains(from + delta) else { return }
        tops.swapAt(from, from + delta)
        reorder(tops)
    }

    /// Whether `move(id, by: delta)` would do anything.
    func canMove(_ id: UUID, by delta: Int) -> Bool {
        guard let from = topIDs.firstIndex(of: id) else { return false }
        return topIDs.indices.contains(from + delta)
    }

    // MARK: Attention

    /// The latest conversation needing the user (waiting first, then
    /// finished unseen), anywhere.
    func jumpToAttention() {
        Activity.shared.jumpToLatest()
    }

    // MARK: Opening folders (`open -a Toasty <dir>`, Finder, Dock)

    /// The workspace whose folder is, or contains, `path` (deepest wins), or
    /// a new workspace for it.
    func openFolder(_ path: String) {
        let target = Self.normalize(path)
        let match = workspaces
            .filter { Self.isPath(target, inside: $0.folder) }
            .max { Self.normalize($0.folder).count < Self.normalize($1.folder).count }
        if let match {
            activate(match.id)
            if Self.normalize(match.folder) != target {
                match.newTerminal(cwd: target)
                match.showTerminal()
            }
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
