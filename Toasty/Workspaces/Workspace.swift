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
    /// Width of the right column (inspector over terminals).
    @Published var terminalWidth: CGFloat = 400
    /// The inspector: the top of the right column.
    @Published var inspectorVisible = false
    @Published var inspectorTab: InspectorTab = .changes
    /// The inspector's share of the right column's height when the
    /// terminal shows below it.
    @Published var inspectorFraction: CGFloat = 0.55
    /// A changed file whose diff fills the conversation column.
    @Published var diffFile: GitChanges.File?

    /// Git status of the workspace folder (the inspector's Changes tab).
    lazy var changes = GitChanges(folder: folder)

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

    // MARK: Inspector

    /// Show the inspector, on `tab` if given.
    func showInspector(_ tab: InspectorTab? = nil) {
        if let tab { inspectorTab = tab }
        inspectorVisible = true
        changed()
    }

    func hideInspector() {
        inspectorVisible = false
        changed()
    }

    /// The right column (inspector and/or terminal) is showing.
    var rightColumnVisible: Bool { inspectorVisible || terminalVisible }

    /// The titlebar's column toggle: hide both halves, or bring the
    /// inspector back.
    func toggleRightColumn() {
        if rightColumnVisible {
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
        var terminalWidth: Double
        var inspectorVisible: Bool?
        var inspectorTab: String?
        var inspectorFraction: Double?
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
              terminalWidth: Double(terminalWidth),
              inspectorVisible: inspectorVisible,
              inspectorTab: inspectorTab.rawValue,
              inspectorFraction: Double(inspectorFraction))
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
        inspectorVisible = s.inspectorVisible ?? false
        inspectorTab = s.inspectorTab.flatMap(InspectorTab.init(rawValue:)) ?? .changes
        inspectorFraction = CGFloat(s.inspectorFraction ?? 0.55)
    }
}

/// The inspector's tabs.
enum InspectorTab: String, CaseIterable, Identifiable {
    case changes, usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .changes: "arrow.triangle.branch"
        case .usage: "gauge.with.dots.needle.50percent"
        }
    }

    /// ⌃⌘1, ⌃⌘2
    var shortcut: String {
        switch self {
        case .changes: "1"
        case .usage: "2"
        }
    }
}
