import AppKit
import Combine

/// A project: its Claude conversations (tabs) and its terminals.
final class Workspace: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var folder: String
    @Published private(set) var conversations: [ClaudeConversation] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var terminals: [TerminalSession] = []
    @Published private(set) var selectedTerminalID: UUID?
    @Published var terminalVisible = false
    @Published var terminalWidth: CGFloat = 520

    weak var store: WorkspaceStore?
    /// Conversation status changes, forwarded to this workspace's observers
    /// (the sidebar row shows them).
    private var statusObservers: [UUID: AnyCancellable] = [:]

    init(id: UUID = UUID(), name: String, folder: String) {
        self.id = id
        self.name = name
        self.folder = folder
    }

    var selected: ClaudeConversation? { conversations.first { $0.id == selectedID } }
    var selectedTerminal: TerminalSession? { terminals.first { $0.id == selectedTerminalID } }

    private func changed() { store?.setNeedsSave() }

    // MARK: Conversations

    @discardableResult
    func newConversation(cwd: String? = nil, resume sessionID: String? = nil, select: Bool = true) -> ClaudeConversation {
        let c = ClaudeConversation(cwd: cwd ?? folder, sessionID: sessionID)
        add(c, select: select)
        return c
    }

    func add(_ conversation: ClaudeConversation, select: Bool) {
        conversation.workspace = self
        observe(conversation)
        var list = conversations
        if let i = list.firstIndex(where: { $0.id == selectedID }) {
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

    func close(_ conversation: ClaudeConversation) {
        guard let i = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversation.stop()
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

    private func observe(_ c: ClaudeConversation) {
        statusObservers[c.id] = c.$phase.map { _ in () }
            .merge(with: c.$requests.map { _ in () }, c.$attention.map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
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
        var terminalWidth: Double
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
              terminalWidth: Double(terminalWidth))
    }

    convenience init(saved s: Saved) {
        self.init(id: s.id, name: s.name, folder: s.folder)
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
        terminalWidth = CGFloat(s.terminalWidth)
    }
}
