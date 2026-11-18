import AppKit
import Combine

/// A project: its Claude conversations (tabs) and its terminals.
final class Workspace: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var folder: String {
        didSet { if folder != oldValue { changes.folder = folder; changes.refresh() } }
    }
    @Published private(set) var conversations: [ClaudeConversation] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var terminals: [TerminalSession] = []
    @Published private(set) var selectedTerminalID: UUID?
    @Published var terminalVisible = false
    /// The inspector: the top of the right column.
    @Published var inspectorVisible = false
    @Published var inspectorTab: InspectorTab = .changes
    /// The preview browser has the right column (experimental; see
    /// `previewShowing`). The inspector and terminal keep their own state
    /// underneath and come back when the preview closes.
    @Published var previewVisible = false
    /// Prompts teed up for later (the inspector's Tee-Up tab): the
    /// workspace's, shared by all of its tabs.
    @Published private(set) var teeUps: [TeeUp] = []
    /// The teed-up prompt open for editing in place.
    @Published private(set) var teeUpEditingID: UUID?
    /// A changed file whose diff fills the conversation column.
    @Published var diffFile: GitChanges.File?
    /// The workspace this one is a git worktree of (shown nested under it).
    var parentID: UUID?
    /// Ignored files copied in when Toasty created this worktree (shown in
    /// its first tab's empty state).
    @Published var copiedFiles: [String] = []

    /// Git status of the workspace folder (the inspector's Changes tab).
    lazy var changes = GitChanges(folder: folder)

    weak var store: WorkspaceStore?
    /// Conversation status changes, forwarded to this workspace's observers
    /// (the sidebar row shows them).
    private var statusObservers: [UUID: AnyCancellable] = [:]

    init(id: UUID = UUID(), name: String, folder: String, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.parentID = parentID
    }

    var isWorktree: Bool { parentID != nil }
    var parent: Workspace? { parentID.flatMap { id in store?.workspaces.first { $0.id == id } } }

    /// The name with its parent's for a worktree ("toasty › fix-login"),
    /// where the workspace is named out of the sidebar's context.
    var displayName: String {
        parent.map { "\($0.name) › \(name)" } ?? name
    }

    var selected: ClaudeConversation? { conversations.first { $0.id == selectedID } }
    var selectedTerminal: TerminalSession? { terminals.first { $0.id == selectedTerminalID } }

    private func changed() { store?.setNeedsSave() }

    // MARK: Conversations

    @discardableResult
    func newConversation(cwd: String? = nil, resume sessionID: String? = nil, select: Bool = true) -> ClaudeConversation {
        let c = ClaudeConversation(cwd: cwd ?? folder, sessionID: sessionID)
        add(c, select: select)
        // Before the first prompt: is the branch behind its remote? (The
        // new tab's empty state says so.)
        changes.checkRemote()
        return c
    }

    /// Fork a conversation at one of its replies: Claude Code copies the
    /// conversation up to and including that reply into a new session,
    /// which opens in a new tab right after the source.
    func fork(_ source: ClaudeConversation, at item: ClaudeItem, select: Bool = true) {
        guard let sessionID = source.sessionID, let uuid = item.entryUUID else { return }
        var base = source.title
        if base.hasSuffix(" (fork)") { base.removeLast(7) }
        let title = "\(base) (fork)"
        ClaudeAgentProcess.fork(sessionID: sessionID, upToMessageID: uuid, title: title, cwd: source.cwd) { [weak self, weak source] result in
            guard let self else { return }
            switch result {
            case .success(let id):
                let c = ClaudeConversation(cwd: source?.cwd ?? self.folder, sessionID: id, customTitle: title, forked: true)
                self.add(c, select: select, after: source)
            case .failure(let error):
                source?.showError(error.localizedDescription)
            }
        }
    }

    /// The open conversation (in any workspace) holding a session.
    static func conversation(withSession id: String) -> ClaudeConversation? {
        for w in WorkspaceStore.shared.workspaces {
            if let c = w.conversations.first(where: { $0.sessionID == id }) { return c }
        }
        return nil
    }

    func add(_ conversation: ClaudeConversation, select: Bool, after: ClaudeConversation? = nil) {
        conversation.workspace = self
        observe(conversation)
        var list = conversations
        if let i = list.firstIndex(where: { $0.id == (after?.id ?? selectedID) }) {
            list.insert(conversation, at: i + 1)
        } else {
            list.append(conversation)
        }
        conversations = list
        if select || selectedID == nil { self.select(conversation) }
        changed()
    }

    func select(_ conversation: ClaudeConversation) {
        guard conversations.contains(where: { $0.id == conversation.id }) else { return }
        selectedID = conversation.id
        diffFile = nil
        conversation.attention = false
        store?.workspaceSelectionChanged(self)
        changed()
    }

    func select(index: Int) {
        guard conversations.indices.contains(index) else { return }
        select(conversations[index])
    }

    func selectRelative(_ delta: Int) {
        guard !conversations.isEmpty else { return }
        let i = conversations.firstIndex { $0.id == selectedID } ?? 0
        select(conversations[(i + delta + conversations.count) % conversations.count])
    }

    /// Close a tab, asking first if Claude is working or waiting in it.
    func requestClose(_ conversation: ClaudeConversation) {
        Activity.shared.confirm(Activity.shared.closeWarning(conversations: [conversation], terminals: [], action: "close it"),
                                title: "Close “\(conversation.title)”?", button: "Close Tab") { [weak self] in
            self?.close(conversation)
        }
    }

    func requestCloseOthers(than conversation: ClaudeConversation) {
        let others = conversations.filter { $0.id != conversation.id }
        Activity.shared.confirm(Activity.shared.closeWarning(conversations: others, terminals: [], action: "close them"),
                                title: "Close Other Tabs?", button: "Close Tabs") { [weak self] in
            others.forEach { self?.close($0) }
        }
    }

    /// Close a terminal, asking first if a program is running in it.
    func requestCloseTerminal(_ id: UUID) {
        guard let t = terminals.first(where: { $0.id == id }) else { return }
        Activity.shared.confirm(Activity.shared.closeWarning(conversations: [], terminals: [t], action: "close it"),
                                title: "Close this terminal?", button: "Close Terminal") { [weak self] in
            self?.closeTerminal(id)
        }
    }

    func close(_ conversation: ClaudeConversation) {
        guard let i = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversation.stop()
        Activity.shared.forget(conversation)
        statusObservers[conversation.id] = nil
        var list = conversations
        list.remove(at: i)
        conversations = list
        if selectedID == conversation.id {
            selectedID = nil
            if !list.isEmpty { select(list[min(i, list.count - 1)]) }
        }
        store?.workspaceSelectionChanged(self)
        changed()
    }

    func closeOthers(than conversation: ClaudeConversation) {
        conversations.filter { $0.id != conversation.id }.forEach(close)
    }

    func renamed() { changed(); store?.workspaceSelectionChanged(self) }

    /// Move a tab to `index` in the row (dragged there, or Move Left/Right).
    func moveConversation(_ id: UUID, to index: Int) {
        guard let moved = Self.moving(conversations, id, to: index) else { return }
        conversations = moved
        changed()
    }

    func moveTerminal(_ id: UUID, to index: Int) {
        guard let moved = Self.moving(terminals, id, to: index) else { return }
        terminals = moved
        changed()
    }

    /// `list` with one item moved to `index`, or nil if that changes nothing.
    private static func moving<T: Identifiable>(_ list: [T], _ id: T.ID, to index: Int) -> [T]? {
        guard let from = list.firstIndex(where: { $0.id == id }) else { return nil }
        let to = max(0, min(index, list.count - 1))
        guard to != from else { return nil }
        var list = list
        list.insert(list.remove(at: from), at: to)
        return list
    }

    private func observe(_ c: ClaudeConversation) {
        statusObservers[c.id] = c.$phase.map { _ in () }
            .merge(with: c.$requests.map { _ in () }, c.$attention.map { _ in () })
            .sink { [weak self] in
                self?.objectWillChange.send()
                Activity.shared.objectWillChange.send()  // the sidebar's Notifications
            }
    }

    // MARK: Terminals

    @discardableResult
    func newTerminal(cwd: String? = nil, select: Bool = true) -> TerminalSession {
        let t = TerminalSession(cwd: cwd ?? folder)
        attach(t)
        var list = terminals
        if let i = list.firstIndex(where: { $0.id == selectedTerminalID }) {
            list.insert(t, at: i + 1)
        } else {
            list.append(t)
        }
        terminals = list
        if select || selectedTerminalID == nil { selectedTerminalID = t.id }
        changed()
        return t
    }

    private func attach(_ t: TerminalSession) {
        t.onExit = { [weak self, weak t] in
            guard let self, let t else { return }
            self.closeTerminal(t.id)
        }
    }

    func selectTerminal(_ id: UUID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
        changed()
    }

    func selectTerminalRelative(_ delta: Int) {
        guard !terminals.isEmpty else { return }
        let i = terminals.firstIndex { $0.id == selectedTerminalID } ?? 0
        selectTerminal(terminals[(i + delta + terminals.count) % terminals.count].id)
    }

    /// Close a terminal tab. Closing the last one hides the sidebar; the
    /// next show starts a fresh shell.
    func closeTerminal(_ id: UUID) {
        guard let i = terminals.firstIndex(where: { $0.id == id }) else { return }
        let t = terminals[i]
        var list = terminals
        list.remove(at: i)
        terminals = list
        t.terminate()
        if selectedTerminalID == id {
            selectedTerminalID = list.isEmpty ? nil : list[min(i, list.count - 1)].id
        }
        if list.isEmpty { terminalVisible = false }
        changed()
    }

    /// Show the terminal sidebar (starting a shell if there's none).
    func showTerminal() {
        previewVisible = false
        if terminals.isEmpty { newTerminal() }
        if selectedTerminalID == nil { selectedTerminalID = terminals.first?.id }
        terminalVisible = true
        changed()
    }

    /// "Run in Terminal" from a code block: paste the command into the
    /// shown terminal (never executes it), and focus it.
    func runInTerminal(_ command: String) {
        showTerminal()
        let text = command.trimmingCharacters(in: .newlines)
        DispatchQueue.main.async {
            guard let t = self.selectedTerminal else { return }
            t.view.terminal.insertPaste(text)
            t.view.terminal.window?.makeFirstResponder(t.view.terminal)
        }
    }

    func hideTerminal() {
        terminalVisible = false
        changed()
    }

    // MARK: Tee-Up

    /// Start a new prompt at the end of the list, open for typing (with
    /// `files` attached, when it's started by dropping them). Left empty,
    /// it goes away when it's closed.
    func newTeeUp(with files: [URL] = []) {
        endTeeUpEdit()
        var item = TeeUp()
        item.attach(files)
        teeUps.append(item)
        teeUpEditingID = item.id
        changed()
    }

    /// Files dropped on the Tee-Up tab: onto the open prompt, or a new one.
    func attachToTeeUp(_ files: [URL]) {
        guard let i = teeUps.firstIndex(where: { $0.id == teeUpEditingID }) else { return newTeeUp(with: files) }
        var item = teeUps[i]
        item.attach(files)
        updateTeeUp(item)
    }

    func addTeeUp(_ item: TeeUp) {
        guard !item.isEmpty else { return }
        teeUps.append(item)
        changed()
    }

    /// Replace a teed-up prompt with its edited version (as it's typed:
    /// there is no save step).
    func updateTeeUp(_ item: TeeUp) {
        guard let i = teeUps.firstIndex(where: { $0.id == item.id }), teeUps[i] != item else { return }
        TeeUpImages.delete(teeUps[i].images.filter { !item.images.contains($0) })
        teeUps[i] = item
        changed()
    }

    /// Open a teed-up prompt for editing in place (closing any other).
    func editTeeUp(_ id: UUID) {
        guard teeUpEditingID != id else { return }
        endTeeUpEdit()
        if teeUps.contains(where: { $0.id == id }) { teeUpEditingID = id }
    }

    /// Close the prompt being edited. Edited down to nothing, it's deleted.
    func endTeeUpEdit() {
        guard let id = teeUpEditingID else { return }
        teeUpEditingID = nil
        guard let i = teeUps.firstIndex(where: { $0.id == id }) else { return }
        if teeUps[i].isEmpty { return removeTeeUp(id) }
        let trimmed = teeUps[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != teeUps[i].text { teeUps[i].text = trimmed; changed() }
    }

    func removeTeeUp(_ id: UUID) {
        if teeUpEditingID == id { teeUpEditingID = nil }
        guard let i = teeUps.firstIndex(where: { $0.id == id }) else { return }
        TeeUpImages.delete(teeUps.remove(at: i).images)
        changed()
    }

    func moveTeeUp(_ id: UUID, to index: Int) {
        guard let moved = Self.moving(teeUps, id, to: index) else { return }
        teeUps = moved
        changed()
    }

    /// Send a teed-up prompt to the open tab, as if typed there: it leaves
    /// the list. False if there's no tab to send it to.
    @discardableResult
    func sendTeeUp(_ id: UUID) -> Bool {
        guard let conversation = selected, let i = teeUps.firstIndex(where: { $0.id == id }) else { return false }
        if teeUpEditingID == id { teeUpEditingID = nil }
        let item = teeUps.remove(at: i)
        diffFile = nil  // show the conversation it went to
        conversation.post(item.text, images: item.images.compactMap(TeeUpImages.image),
                          files: item.files.map { URL(fileURLWithPath: $0) })
        TeeUpImages.delete(item.images)
        changed()
        return true
    }

    /// Every picture this workspace's teed-up prompts still use.
    var teeUpImageNames: [String] { teeUps.flatMap(\.images) }

    // MARK: Inspector

    /// Show the inspector, on `tab` if given.
    func showInspector(_ tab: InspectorTab? = nil) {
        previewVisible = false
        if let tab { inspectorTab = tab }
        inspectorVisible = true
        changed()
    }

    func hideInspector() {
        inspectorVisible = false
        changed()
    }

    /// The right column (inspector and/or terminal, or the preview) is showing.
    var rightColumnVisible: Bool { inspectorVisible || terminalVisible || previewShowing }

    /// The preview has the right column: asked for, and its setting is on.
    /// It and the inspector/terminal are never shown together.
    var previewShowing: Bool { previewVisible && PreviewSettings.shared.enabled }

    func showPreview() {
        guard PreviewSettings.shared.enabled, !previewVisible else { return }
        previewVisible = true
    }

    /// Close the preview: the inspector and terminal are back as they were
    /// (or the column closes, if neither was showing).
    func hidePreview() {
        if previewVisible { previewVisible = false }
    }

    /// The titlebar's column toggle: hide both halves, or bring the
    /// inspector back. From the preview, it swaps to the inspector.
    func toggleRightColumn() {
        if previewShowing {
            previewVisible = false
            if !terminalVisible { inspectorVisible = true }
        } else if rightColumnVisible {
            inspectorVisible = false
            terminalVisible = false
        } else {
            inspectorVisible = true
        }
        changed()
    }

    // MARK: State

    var needsAttention: Bool { conversations.contains { !$0.requests.isEmpty } }
    var isWorking: Bool { conversations.contains { $0.phase != .idle } }
    var hasAttention: Bool { conversations.contains { $0.attention } }

    func stop() {
        conversations.forEach { $0.stop() }
        terminals.forEach { $0.terminate() }
    }

    struct Saved: Codable {
        var id: UUID
        var name: String
        var folder: String
        var conversations: [SavedConversation]
        var selected: UUID?
        var terminals: [SavedTerminal]
        var selectedTerminal: UUID?
        var terminalVisible: Bool
        /// Older state kept sizes per workspace (now window-wide).
        var terminalWidth: Double?
        var inspectorVisible: Bool?
        var inspectorTab: String?
        var inspectorFraction: Double?
        var parentID: UUID?
        var teeUps: [TeeUp]?
    }

    struct SavedConversation: Codable {
        var id: UUID
        var sessionID: String?
        var cwd: String
        var customTitle: String?
    }

    struct SavedTerminal: Codable {
        var id: UUID
        var cwd: String
    }

    var saved: Saved {
        Saved(id: id, name: name, folder: folder,
              conversations: conversations.map {
                  SavedConversation(id: $0.id, sessionID: $0.sessionID, cwd: $0.cwd, customTitle: $0.customTitle)
              },
              selected: selectedID,
              terminals: terminals.map { SavedTerminal(id: $0.id, cwd: $0.directory) },
              selectedTerminal: selectedTerminalID,
              terminalVisible: terminalVisible,
              terminalWidth: nil,
              inspectorVisible: inspectorVisible,
              inspectorTab: inspectorTab.rawValue,
              inspectorFraction: nil,
              parentID: parentID,
              teeUps: teeUps.isEmpty ? nil : teeUps)
    }

    convenience init(saved s: Saved) {
        self.init(id: s.id, name: s.name, folder: s.folder, parentID: s.parentID)
        for c in s.conversations {
            let conv = ClaudeConversation(restoring: c.id, cwd: c.cwd, sessionID: c.sessionID, customTitle: c.customTitle)
            conv.workspace = self
            observe(conv)
            conversations.append(conv)
        }
        selectedID = s.selected.flatMap { id in conversations.contains { $0.id == id } ? id : nil } ?? conversations.first?.id
        for t in s.terminals {
            let session = TerminalSession(id: t.id, cwd: t.cwd)
            attach(session)
            terminals.append(session)
        }
        selectedTerminalID = s.selectedTerminal.flatMap { id in terminals.contains { $0.id == id } ? id : nil } ?? terminals.first?.id
        terminalVisible = s.terminalVisible && !terminals.isEmpty
        inspectorVisible = s.inspectorVisible ?? false
        inspectorTab = s.inspectorTab.flatMap(InspectorTab.init(rawValue:)) ?? .changes
        // (Not a new prompt that was still empty when Toasty quit.)
        teeUps = (s.teeUps ?? []).filter { !$0.isEmpty }
    }
}

/// The inspector's tabs.
enum InspectorTab: String, CaseIterable, Identifiable {
    case changes, usage, teeUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .usage: "Usage"
        case .teeUp: "Tee-Up"
        }
    }

    var symbol: String {
        switch self {
        case .changes: "arrow.triangle.branch"
        case .usage: "gauge.with.dots.needle.50percent"
        case .teeUp: "text.line.first.and.arrowtriangle.forward"
        }
    }

    /// ⌃⌘1, ⌃⌘2, ⌃⌘3
    var shortcut: String {
        switch self {
        case .changes: "1"
        case .usage: "2"
        case .teeUp: "3"
        }
    }
}
