import AppKit
import Combine

/// All workspaces, which one is shown, and the window's layout; persisted to
/// `~/Library/Application Support/<app name>/state.json`.
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeID: UUID?
    @Published var sidebarVisible = true
    /// The workspace whose name is being edited in the sidebar.
    @Published var renamingID: UUID?
    /// The workspace being dragged in the sidebar.
    @Published var draggingID: UUID?
    var windowFrame: NSRect?

    /// The active workspace or its selection changed (window title, focus).
    let selectionChanged = PassthroughSubject<Void, Never>()

    var active: Workspace? { workspaces.first { $0.id == activeID } }

    // MARK: Persistence

    struct Saved: Codable {
        var workspaces: [Workspace.Saved]
        var activeWorkspace: UUID?
        var sidebarVisible: Bool
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

    func load() {
        loading = true
        defer { loading = false }
        if let data = try? Data(contentsOf: Self.stateURL),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            workspaces = s.workspaces.map { Workspace(saved: $0) }
            workspaces.forEach { $0.store = self }
            activeID = s.activeWorkspace.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
                ?? workspaces.first?.id
            sidebarVisible = s.sidebarVisible
            windowFrame = s.windowFrame.map(NSRectFromString)
        }
        if workspaces.isEmpty {
            create(folder: NSHomeDirectory(), name: "Home")
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
        if w.id == activeID { selectionChanged.send() }
    }

    // MARK: Workspaces

    @discardableResult
    func create(folder: String, name: String? = nil, activate: Bool = true) -> Workspace {
        let w = Workspace(name: name ?? Self.projectName(for: URL(fileURLWithPath: folder)), folder: folder)
        w.store = self
        w.newConversation()
        var list = workspaces
        if let i = list.firstIndex(where: { $0.id == activeID }) {
            list.insert(w, at: i + 1)
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

    func close(_ id: UUID) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let w = workspaces[i]
        var list = workspaces
        list.remove(at: i)
        workspaces = list
        w.stop()
        if activeID == id {
            activeID = list.isEmpty ? nil : list[min(i, list.count - 1)].id
            selectionChanged.send()
        }
        setNeedsSave()
    }

    // MARK: Order

    func move(_ id: UUID, to target: UUID) {
        guard id != target,
              let from = workspaces.firstIndex(where: { $0.id == id }),
              let to = workspaces.firstIndex(where: { $0.id == target }) else { return }
        var list = workspaces
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        workspaces = list
        setNeedsSave()
    }

    func moveToEnd(_ id: UUID) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }), from != workspaces.count - 1 else { return }
        var list = workspaces
        list.append(list.remove(at: from))
        workspaces = list
        setNeedsSave()
    }

    func move(_ id: UUID, by delta: Int) {
        guard let from = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let to = from + delta
        guard workspaces.indices.contains(to) else { return }
        var list = workspaces
        list.swapAt(from, to)
        workspaces = list
        setNeedsSave()
    }

    // MARK: Attention

    /// The latest conversation needing the user (waiting first, then
    /// finished unseen), anywhere.
    func jumpToAttention() {
        let all = workspaces.flatMap { w in w.conversations.map { (w, $0) } }
        guard let (w, c) = all.first(where: { !$0.1.requests.isEmpty }) ?? all.first(where: { $0.1.attention }) else {
            NSSound.beep()
            return
        }
        activate(w.id)
        w.select(c)
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

    static func normalize(_ path: String) -> String {
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
