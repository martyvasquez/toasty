import AppKit
import os
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
    /// Terminals that are tabs in the top row, among the conversations
    /// (an experiment, beside the dock's terminals).
    @Published private(set) var tabTerminals: [TerminalSession] = []
    /// The top row's order: conversations and terminal tabs together.
    @Published private(set) var tabOrder: [UUID] = []
    /// The terminal tab filling the conversation column (nil: the
    /// selected conversation shows).
    @Published private(set) var shownTabTerminalID: UUID?
    /// The terminal drawer under the conversation (another experiment):
    /// its own terminals and tabs, open or closed.
    @Published private(set) var drawerTerminals: [TerminalSession] = []
    @Published private(set) var selectedDrawerTerminalID: UUID?
    @Published private(set) var drawerOpen = false
    /// The widget column's space this workspace is on (nil: the first).
    @Published var spaceID: UUID?
    /// The widget column shows (off: focus, the conversation alone).
    @Published var widgetsVisible = true
    /// The terminal over the widgets is open (off: its tab strip alone).
    @Published var terminalOpen = false
    /// Prompts teed up for later (the inspector's Tee-Up tab): the
    /// workspace's, shared by all of its tabs.
    @Published private(set) var teeUps: [TeeUp] = []
    /// Auto-Send: teed-up prompts are being sent to one tab, each when
    /// Claude finishes the one before. Never saved: after a relaunch it's
    /// off until turned on again.
    @Published private(set) var teeUpFeed: TeeUpFeed?
    private var teeUpFeedTimer: DispatchWorkItem?
    /// The teed-up prompt open for editing in place.
    @Published private(set) var teeUpEditingID: UUID?
    /// A changed file whose diff fills the conversation column.
    @Published var diffFile: GitChanges.File?
    /// The workspace this one is a git worktree of (shown nested under it).
    var parentID: UUID?
    /// The sidebar heading this workspace sits under (top-level workspaces
    /// only; a worktree goes with its parent).
    var headingID: UUID?
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
        // In the row: right after the tab it was opened from.
        if !tabOrder.isEmpty {
            var order = topTabs.map(\.id).filter { $0 != conversation.id }
            let from = after?.id ?? shownTopTabID
            if let i = order.firstIndex(where: { $0 == from }) { order.insert(conversation.id, at: i + 1) } else { order.append(conversation.id) }
            tabOrder = order
        }
        if select || selectedID == nil { self.select(conversation) }
        changed()
    }

    func select(_ conversation: ClaudeConversation) {
        guard conversations.contains(where: { $0.id == conversation.id }) else { return }
        selectedID = conversation.id
        shownTabTerminalID = nil
        diffFile = nil
        conversation.attention = false
        store?.workspaceSelectionChanged(self)
        changed()
    }

    /// The next or previous tab in the top row (conversation or terminal).
    func selectRelative(_ delta: Int) {
        let tabs = topTabs
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == shownTopTabID } ?? 0
        selectTopTab(tabs[(i + delta + tabs.count) % tabs.count])
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
        if teeUpFeed?.conversationID == conversation.id { stopTeeUpFeed() }
        Activity.shared.forget(conversation)
        statusObservers[conversation.id] = nil
        var list = conversations
        let neighbour = topTabNeighbour(of: conversation.id)
        list.remove(at: i)
        conversations = list
        tabOrder.removeAll { $0 == conversation.id }
        if selectedID == conversation.id {
            selectedID = list.isEmpty ? nil : list[min(i, list.count - 1)].id
            // It was showing: its neighbour in the row shows instead.
            if shownTabTerminalID == nil, let neighbour { selectTopTab(neighbour) }
        }
        store?.workspaceSelectionChanged(self)
        changed()
    }

    func renamed() { changed(); store?.workspaceSelectionChanged(self) }

    /// Move a tab to `index` in the row (dragged there, or Move Left/Right).
    /// (`index` is a place in the top row, among terminal tabs too.)
    func moveConversation(_ id: UUID, to index: Int) { moveTopTab(id, to: index) }

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
        if list.isEmpty { terminalOpen = false }
        changed()
    }

    /// Open the terminal over the widgets (starting a shell if there's
    /// none), with the widget column showing.
    func showTerminal() {
        ensureTerminal()
        terminalOpen = true
        if id == store?.activeID, let wc = AppDelegate.shared.windowController { wc.revealWidgets(self) } else { widgetsVisible = true }
        changed()
    }

    func hideTerminal() {
        terminalOpen = false
        changed()
    }

    /// A shell to show, started if there's none.
    func ensureTerminal() {
        if terminals.isEmpty { newTerminal() }
        if selectedTerminalID == nil { selectedTerminalID = terminals.first?.id }
    }

    /// "Run in Terminal" from a code block: paste the command into the
    /// shown terminal (never executes it), and focus it.
    func runInTerminal(_ command: String) {
        let drawer = !TerminalLayoutSettings.shared.sidebarTerminal
        if drawer { setDrawer(open: true) } else { showTerminal() }
        let text = command.trimmingCharacters(in: .newlines)
        DispatchQueue.main.async {
            guard let t = drawer ? self.selectedDrawerTerminal : self.selectedTerminal else { return }
            t.view.terminal.insertPaste(text)
            t.view.terminal.window?.makeFirstResponder(t.view.terminal)
        }
    }

    /// A terminal tab's label: its place in the strip ("Terminal 2"), so the
    /// tabs always read 1, 2, 3 from the left. What's running and where is
    /// in the tab's tooltip.
    func terminalLabel(_ t: TerminalSession) -> String {
        "Terminal \((terminals.firstIndex { $0.id == t.id } ?? 0) + 1)"
    }

    // MARK: Top row (conversations and terminal tabs)

    /// The top row's tabs in order: `tabOrder`, then any it doesn't list
    /// yet (conversations first, as they were).
    var topTabs: [TopTab] {
        let all = conversations.map(TopTab.conversation) + tabTerminals.map(TopTab.terminal)
        let place = Dictionary(uniqueKeysWithValues: tabOrder.enumerated().map { ($1, $0) })
        return all.enumerated()
            .sorted { (place[$0.element.id] ?? tabOrder.count + $0.offset) < (place[$1.element.id] ?? tabOrder.count + $1.offset) }
            .map(\.element)
    }

    /// The tab showing in the conversation column.
    var shownTopTabID: UUID? { shownTabTerminalID ?? selectedID }
    var shownTabTerminal: TerminalSession? { tabTerminals.first { $0.id == shownTabTerminalID } }

    func selectTopTab(_ tab: TopTab) {
        switch tab {
        case .conversation(let c): select(c)
        case .terminal(let t): showTabTerminal(t.id)
        }
    }

    /// The tab after `id` in the row (else the one before), for when it closes.
    private func topTabNeighbour(of id: UUID) -> TopTab? {
        let tabs = topTabs
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < tabs.count { return tabs[i + 1] }
        return i > 0 ? tabs[i - 1] : nil
    }

    func moveTopTab(_ id: UUID, to index: Int) {
        guard let moved = Self.moving(topTabs, id, to: index) else { return }
        tabOrder = moved.map(\.id)
        // The conversations keep the row's order among themselves.
        let rank = Dictionary(uniqueKeysWithValues: tabOrder.enumerated().map { ($1, $0) })
        conversations = conversations.sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        changed()
    }

    /// A new terminal tab right after the shown tab, in the workspace's folder.
    @discardableResult
    func newTabTerminal(cwd: String? = nil) -> TerminalSession {
        let t = TerminalSession(cwd: cwd ?? folder)
        attachTab(t)
        var order = topTabs.map(\.id)
        if let i = order.firstIndex(where: { $0 == shownTopTabID }) { order.insert(t.id, at: i + 1) } else { order.append(t.id) }
        tabTerminals.append(t)
        tabOrder = order
        showTabTerminal(t.id)
        return t
    }

    private func attachTab(_ t: TerminalSession) {
        t.onPage = true
        t.onExit = { [weak self, weak t] in
            guard let self, let t else { return }
            self.closeTabTerminal(t.id)
        }
    }

    func showTabTerminal(_ id: UUID) {
        guard tabTerminals.contains(where: { $0.id == id }) else { return }
        shownTabTerminalID = id
        lastTabTerminalID = id
        diffFile = nil
        store?.workspaceSelectionChanged(self)
        changed()
    }

    func requestCloseTabTerminal(_ id: UUID) {
        guard let t = tabTerminals.first(where: { $0.id == id }) else { return }
        Activity.shared.confirm(Activity.shared.closeWarning(conversations: [], terminals: [t], action: "close it"),
                                title: "Close this terminal?", button: "Close Terminal") { [weak self] in
            self?.closeTabTerminal(id)
        }
    }

    func closeTabTerminal(_ id: UUID) {
        guard let i = tabTerminals.firstIndex(where: { $0.id == id }) else { return }
        let neighbour = topTabNeighbour(of: id)
        let t = tabTerminals.remove(at: i)
        tabOrder.removeAll { $0 == id }
        t.terminate()
        if shownTabTerminalID == id {
            shownTabTerminalID = nil
            if let neighbour { selectTopTab(neighbour) }
        }
        store?.workspaceSelectionChanged(self)
        changed()
    }

    /// The last terminal tab shown (for ⌃`), else the first.
    var lastTabTerminalID: UUID?

    // MARK: Terminal drawer (under the conversation)

    var selectedDrawerTerminal: TerminalSession? { drawerTerminals.first { $0.id == selectedDrawerTerminalID } }

    /// Open the drawer (with a shell, if it has none), or close it.
    func setDrawer(open: Bool) {
        if open, drawerTerminals.isEmpty { newDrawerTerminal() }
        guard drawerOpen != open else { return }
        drawerOpen = open
        changed()
    }

    @discardableResult
    func newDrawerTerminal() -> TerminalSession {
        let t = TerminalSession(cwd: folder)
        attachDrawer(t)
        var list = drawerTerminals
        if let i = list.firstIndex(where: { $0.id == selectedDrawerTerminalID }) { list.insert(t, at: i + 1) } else { list.append(t) }
        drawerTerminals = list
        selectedDrawerTerminalID = t.id
        changed()
        return t
    }

    private func attachDrawer(_ t: TerminalSession) {
        t.onPage = true
        t.onExit = { [weak self, weak t] in
            guard let self, let t else { return }
            self.closeDrawerTerminal(t.id)
        }
    }

    func selectDrawerTerminal(_ id: UUID) {
        guard drawerTerminals.contains(where: { $0.id == id }) else { return }
        selectedDrawerTerminalID = id
        changed()
    }

    func moveDrawerTerminal(_ id: UUID, to index: Int) {
        guard let moved = Self.moving(drawerTerminals, id, to: index) else { return }
        drawerTerminals = moved
        changed()
    }

    func requestCloseDrawerTerminal(_ id: UUID) {
        guard let t = drawerTerminals.first(where: { $0.id == id }) else { return }
        Activity.shared.confirm(Activity.shared.closeWarning(conversations: [], terminals: [t], action: "close it"),
                                title: "Close this terminal?", button: "Close Terminal") { [weak self] in
            self?.closeDrawerTerminal(id)
        }
    }

    /// Closing the last one closes the drawer.
    func closeDrawerTerminal(_ id: UUID) {
        guard let i = drawerTerminals.firstIndex(where: { $0.id == id }) else { return }
        var list = drawerTerminals
        let t = list.remove(at: i)
        drawerTerminals = list
        t.terminate()
        if selectedDrawerTerminalID == id { selectedDrawerTerminalID = list.isEmpty ? nil : list[min(i, list.count - 1)].id }
        if list.isEmpty { drawerOpen = false }
        changed()
    }

    // MARK: Tee-Up

    /// Start a new prompt at the end of the list, open for typing (with
    /// `files` attached, when it's started by dropping them). Left empty,
    /// it goes away when it's closed.
    func newTeeUp(with files: [URL] = []) {
        newTeeUp(after: nil, with: files)
    }

    /// Start a new prompt right under `id` (as Space under a selected
    /// Things to-do), or at the end, open for typing.
    func newTeeUp(after id: UUID?, with files: [URL] = []) {
        endTeeUpEdit()
        var item = TeeUp()
        item.attach(files)
        if let id, let i = teeUps.firstIndex(where: { $0.id == id }) {
            teeUps.insert(item, at: i + 1)
        } else {
            teeUps.append(item)
        }
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
    func endTeeUpEdit(keepingEmpty: Bool = false) {
        guard let id = teeUpEditingID else { return }
        teeUpEditingID = nil
        guard let i = teeUps.firstIndex(where: { $0.id == id }) else { return }
        if teeUps[i].isEmpty {
            if !keepingEmpty { removeTeeUp(id) }
            return
        }
        let trimmed = teeUps[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != teeUps[i].text { teeUps[i].text = trimmed; changed() }
    }

    /// Removes a prompt that was left empty (unless it's being edited again).
    func removeTeeUpIfEmpty(_ id: UUID) {
        guard teeUpEditingID != id, teeUps.first(where: { $0.id == id })?.isEmpty == true else { return }
        removeTeeUp(id)
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

    /// Send a teed-up prompt to the open tab (or `tab`), as if typed there:
    /// it leaves the list. False if there's no tab to send it to.
    @discardableResult
    func sendTeeUp(_ id: UUID, to tab: ClaudeConversation? = nil) -> Bool {
        guard let conversation = tab ?? selected, let i = teeUps.firstIndex(where: { $0.id == id }) else { return false }
        if teeUpEditingID == id { teeUpEditingID = nil }
        let item = teeUps.remove(at: i)
        if tab == nil { diffFile = nil }  // show the conversation it went to
        conversation.post(item.text, images: item.images.compactMap(TeeUpImages.image),
                          files: item.files.map { URL(fileURLWithPath: $0) })
        TeeUpImages.delete(item.images)
        changed()
        return true
    }

    func setTeeUpHeld(_ id: UUID, _ held: Bool) {
        guard let i = teeUps.firstIndex(where: { $0.id == id }), teeUps[i].isHeld != held else { return }
        teeUps[i].held = held ? true : nil
        changed()
    }

    // MARK: Tee-Up Auto-Send

    /// Seconds between Claude finishing and the next prompt going out:
    /// time to read the reply and pause.
    static let teeUpFeedDelay: TimeInterval = 5

    /// The prompt Auto-Send would send next: the first that isn't held.
    var nextTeeUpToFeed: TeeUp? { teeUps.first { !$0.isHeld } }

    /// The tab Auto-Send is sending to.
    var teeUpFeedTab: ClaudeConversation? {
        teeUpFeed.flatMap { feed in conversations.first { $0.id == feed.conversationID } }
    }

    /// The Auto-Send button: say what's about to happen, and where, before
    /// anything is sent. A slip here would send a whole list of prompts.
    func requestTeeUpFeed() {
        guard let conversation = selected, nextTeeUpToFeed != nil else { return }
        let count = teeUps.filter { !$0.isHeld }.count
        let mode: String
        switch conversation.permissionMode {
        case "default": mode = "That tab is in Ask Before Edits, so it will wait whenever Claude needs your permission."
        case "plan": mode = "That tab is in Plan Mode, so it will wait when Claude has a plan to review."
        case "acceptEdits": mode = "That tab is in Accept Edits, so Claude will edit files without asking."
        default: mode = "That tab is in \(ClaudeModeMenu.label(conversation.permissionMode)), so Claude will make changes without asking."
        }
        // Which tab, unmistakably: its name, where it is in the row, and
        // the workspace (several tabs can be called "New Chat").
        let position = (conversations.firstIndex { $0.id == conversation.id } ?? 0) + 1
        let place = conversations.count > 1 ? "tab \(position) of \(conversations.count) in \(displayName)" : "the only tab in \(displayName)"
        let what = count == 1 ? "1 prompt goes" : "\(count) prompts go"
        let first = conversation.isBusy ? "The first is sent when Claude finishes what it's doing"
                                        : "The first is sent now"
        let rest = count == 1 ? "." : ", and each of the others when Claude finishes the one before."
        Activity.shared.confirm("""
            \(what) to “\(conversation.title)”, \(place): the tab that's open now. Only that tab, even after you switch to another.

            \(first)\(rest) \(mode)

            It pauses if Claude hits an error, needs an answer, or you send a message in that tab. Pause and Stop are under the list the whole time.
            """,
            title: "Auto-Send to “\(conversation.title)”?",
            button: "Start Auto-Send") { [weak self, weak conversation] in
            // Still the tab that was asked about.
            guard let self, let conversation, self.selected?.id == conversation.id else { return }
            self.startTeeUpFeed()
        }
    }

    /// Turn Auto-Send on for the open tab. If Claude is idle there the
    /// first prompt goes now; otherwise when the turn under way finishes.
    func startTeeUpFeed() {
        guard let conversation = selected, nextTeeUpToFeed != nil else { return }
        teeUpFeedTimer?.cancel()
        teeUpFeed = TeeUpFeed(conversationID: conversation.id)
        if !conversation.isBusy { feedNextTeeUp() }
    }

    /// Turn Auto-Send off (the Stop button, always there while it's on or
    /// paused). Claude finishes what it has; the prompts left stay teed up.
    func stopTeeUpFeed() {
        teeUpFeedTimer?.cancel()
        teeUpFeed = nil
    }

    /// The Pause button: nothing more is sent until Resume. It keeps its tab.
    func pauseTeeUpFeed() {
        guard let conversation = teeUpFeedTab else { return stopTeeUpFeed() }
        pauseTeeUpFeed(for: conversation, because: "")
    }

    /// Auto-Send pauses by itself, saying why, if it's sending to
    /// `conversation`. It stays with that tab: Resume carries on, Stop ends it.
    /// `notify`: when nothing else tells the user (it happens between
    /// turns; an error or their own interrupt they already know about).
    func pauseTeeUpFeed(for conversation: ClaudeConversation, because reason: String, notify: Bool = false) {
        // Already paused: the first reason is the one that matters.
        guard teeUpFeed?.conversationID == conversation.id, teeUpFeed?.paused == nil else { return }
        if notify { conversation.notifyTeeUpPaused(reason) }
        teeUpFeedTimer?.cancel()
        teeUpFeed?.nextAt = nil
        teeUpFeed?.checking = nil
        teeUpFeed?.verdict = nil
        teeUpFeed?.paused = reason
        if !reason.isEmpty { Self.teeUpLog.notice("paused: \(reason, privacy: .public)") }
    }

    /// The Resume button: carry on in the same tab. The next prompt goes
    /// now if Claude is idle there, else when its turn finishes.
    func resumeTeeUpFeed() {
        guard teeUpFeed?.paused != nil, let conversation = teeUpFeedTab, nextTeeUpToFeed != nil else { return stopTeeUpFeed() }
        teeUpFeed?.paused = nil
        if !conversation.isBusy { feedNextTeeUp() }
    }

    /// What Auto-Send decides, for looking into a surprise afterwards:
    /// `/usr/bin/log show --last 1h --predicate 'category == "teeup"'`
    nonisolated static let teeUpLog = Logger(subsystem: "com.martyvasquez.toasty", category: "teeup")

    /// A turn ended in `conversation`. Only a clean finish feeds the next
    /// prompt (after a pause): later prompts usually build on this one. And
    /// not if Claude's reply is a question it needs answered (Settings ▸
    /// Tee-Up says how that's judged).
    /// Returns what it means for the turn's own "finished" notification.
    @discardableResult
    func teeUpTurnEnded(_ conversation: ClaudeConversation, cleanly: Bool, interrupted: Bool, reply: String = "") -> TeeUpFeed.TurnEnd {
        guard teeUpFeed?.conversationID == conversation.id, teeUpFeed?.paused == nil else { return .notFeeding }
        guard cleanly else {
            pauseTeeUpFeed(for: conversation, because: interrupted ? "Interrupted" : "Claude stopped with an error")
            return .notFeeding
        }
        teeUpFeed?.verdict = nil
        guard nextTeeUpToFeed != nil else { stopTeeUpFeed(); return .done }
        let finished = Date()
        let asks = TeeUpQuestion.mightAsk(reply)
        switch TeeUpSettings.shared.questionCheck {
        case .off:
            scheduleTeeUpFeed(at: finished)
        case .anyQuestion:
            if asks { pauseTeeUpFeed(for: conversation, because: "Claude asked a question", notify: true) }
            else { scheduleTeeUpFeed(at: finished) }
        case .smallModel:
            guard asks else { scheduleTeeUpFeed(at: finished); return .goingOn }
            // Ask a small model whether Claude is waiting for an answer
            // or only offering more. Not sure counts as waiting.
            let check = UUID()
            teeUpFeed?.checking = check
            let prompt = TeeUpQuestion.prompt(asked: teeUpFeed?.lastPrompt ?? "", reply: reply)
            ClaudeAgentProcess.ask(prompt, system: TeeUpQuestion.system, cwd: conversation.cwd) { [weak self, weak conversation] result in
                guard let self, let conversation, self.teeUpFeed?.checking == check else { return }
                self.teeUpFeed?.checking = nil
                switch result {
                case .success(let answer): Self.teeUpLog.notice("reply check: \(answer, privacy: .public)")
                case .failure(let error): Self.teeUpLog.error("reply check failed: \(error.localizedDescription, privacy: .public)")
                }
                switch result.map(TeeUpQuestion.verdict) {
                case .success(.goOn):
                    // Said in the bar through the countdown, so the
                    // decision can be seen (and paused) before it acts.
                    self.teeUpFeed?.verdict = "Claude's question was only an offer"
                    self.scheduleTeeUpFeed(at: finished)
                case .success(.waiting(let what)):
                    self.pauseTeeUpFeed(for: conversation, because: what.isEmpty ? "Claude asked a question" : "Claude needs \(what)", notify: true)
                case .success(.unclear), .failure:
                    self.pauseTeeUpFeed(for: conversation, because: "Couldn't tell if Claude needs an answer", notify: true)
                }
            }
        }
        return .goingOn
    }

    /// Send the next prompt `teeUpFeedDelay` after the turn `finished`
    /// (what's left of it, if checking the reply took a while).
    private func scheduleTeeUpFeed(at finished: Date) {
        // After a reply check, long enough to read what it decided.
        let least: TimeInterval = teeUpFeed?.verdict == nil ? 1 : 4
        let at = max(Date().addingTimeInterval(least), finished.addingTimeInterval(Self.teeUpFeedDelay))
        teeUpFeed?.nextAt = at
        let work = DispatchWorkItem { [weak self] in self?.feedNextTeeUp() }
        teeUpFeedTimer?.cancel()
        teeUpFeedTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSinceNow, execute: work)
    }

    private func feedNextTeeUp() {
        guard let conversation = teeUpFeedTab else { return stopTeeUpFeed() }
        teeUpFeed?.nextAt = nil
        guard let next = nextTeeUpToFeed else { return stopTeeUpFeed() }
        // Claude is busy or waiting on the user after all: not now.
        guard !conversation.isBusy else {
            return pauseTeeUpFeed(for: conversation, because: "Claude is waiting for you", notify: true)
        }
        guard teeUpEditingID != next.id else {
            return pauseTeeUpFeed(for: conversation, because: "The next prompt is being edited", notify: true)
        }
        teeUpFeed?.verdict = nil
        teeUpFeed?.lastPrompt = next.text
        sendTeeUp(next.id, to: conversation)
    }

    /// Every picture this workspace's teed-up prompts still use.
    var teeUpImageNames: [String] { teeUps.flatMap(\.images) }

    // MARK: Widgets

    func setWidgets(visible: Bool) {
        guard widgetsVisible != visible else { return }
        widgetsVisible = visible
        changed()
    }

    func selectSpace(_ id: UUID) {
        guard spaceID != id else { return }
        spaceID = id
        changed()
    }

    // MARK: State

    var needsAttention: Bool { conversations.contains { !$0.requests.isEmpty } }
    var isWorking: Bool { conversations.contains { $0.phase != .idle } }
    var hasAttention: Bool { conversations.contains { $0.attention } }

    func stop() {
        conversations.forEach { $0.stop() }
        terminals.forEach { $0.terminate() }
        tabTerminals.forEach { $0.terminate() }
        drawerTerminals.forEach { $0.terminate() }
    }

    struct Saved: Codable {
        var id: UUID
        var name: String
        var folder: String
        var conversations: [SavedConversation]
        var selected: UUID?
        var terminals: [SavedTerminal]
        var selectedTerminal: UUID?
        /// Older state: the right column's halves (now the widgets).
        var terminalVisible: Bool?
        var terminalWidth: Double?
        var inspectorVisible: Bool?
        var inspectorTab: String?
        var inspectorFraction: Double?
        var space: UUID?
        var widgetsHidden: Bool?
        var parentID: UUID?
        var teeUps: [TeeUp]?
        var heading: UUID?
        /// Terminal tabs in the top row (the experiment), the row's order,
        /// and the one showing.
        var tabTerminals: [SavedTerminal]?
        var tabOrder: [UUID]?
        var shownTabTerminal: UUID?
        /// The terminal drawer's.
        var drawerTerminals: [SavedTerminal]?
        var selectedDrawerTerminal: UUID?
        var drawerOpen: Bool?
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
              terminalVisible: terminalOpen,
              terminalWidth: nil,
              inspectorVisible: nil,
              inspectorTab: nil,
              inspectorFraction: nil,
              space: spaceID,
              widgetsHidden: widgetsVisible ? nil : true,
              parentID: parentID,
              teeUps: teeUps.isEmpty ? nil : teeUps,
              heading: headingID,
              tabTerminals: tabTerminals.isEmpty ? nil : tabTerminals.map { SavedTerminal(id: $0.id, cwd: $0.directory) },
              tabOrder: tabTerminals.isEmpty ? nil : tabOrder,
              shownTabTerminal: shownTabTerminalID,
              drawerTerminals: drawerTerminals.isEmpty ? nil : drawerTerminals.map { SavedTerminal(id: $0.id, cwd: $0.directory) },
              selectedDrawerTerminal: selectedDrawerTerminalID,
              drawerOpen: drawerOpen ? true : nil)
    }

    convenience init(saved s: Saved) {
        self.init(id: s.id, name: s.name, folder: s.folder, parentID: s.parentID)
        headingID = s.heading
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
        spaceID = s.space
        for t in s.tabTerminals ?? [] {
            let session = TerminalSession(id: t.id, cwd: t.cwd)
            attachTab(session)
            tabTerminals.append(session)
        }
        tabOrder = s.tabOrder ?? []
        for t in s.drawerTerminals ?? [] {
            let session = TerminalSession(id: t.id, cwd: t.cwd)
            attachDrawer(session)
            drawerTerminals.append(session)
        }
        selectedDrawerTerminalID = s.selectedDrawerTerminal.flatMap { id in drawerTerminals.contains { $0.id == id } ? id : nil } ?? drawerTerminals.first?.id
        drawerOpen = (s.drawerOpen ?? false) && !drawerTerminals.isEmpty
        shownTabTerminalID = s.shownTabTerminal.flatMap { id in tabTerminals.contains { $0.id == id } ? id : nil }
        terminalOpen = (s.terminalVisible ?? false) && !terminals.isEmpty
        widgetsVisible = !(s.widgetsHidden ?? false)
        // (Not a new prompt that was still empty when Toasty quit.)
        teeUps = (s.teeUps ?? []).filter { !$0.isEmpty }
    }
}

/// Auto-Send under way (see `Workspace.startTeeUpFeed`).
struct TeeUpFeed: Equatable {
    /// What a finished turn means to Auto-Send, for the tab's own
    /// "finished" notification.
    enum TurnEnd {
        /// Not its tab, or it stopped here for a reason the user is told
        /// anyway: notify as usual.
        case notFeeding
        /// More to send (or a pause that says so itself): stay quiet.
        case goingOn
        /// That was the last prompt.
        case done
    }

    /// The tab the prompts go to: the one that was open when it was started.
    let conversationID: UUID
    /// When the next prompt goes out, while counting down to it.
    var nextAt: Date?
    /// Claude's reply is being checked for a question it needs answered.
    var checking: UUID?
    /// The prompt it sent last (what Claude's reply answers).
    var lastPrompt = ""
    /// What the reply check decided, while counting down to the next prompt.
    var verdict: String?
    /// Paused, and why ("" when the user pressed Pause): nothing is sent
    /// until Resume. It keeps its tab.
    var paused: String?
}

/// A tab in the top row: a conversation or a terminal.
enum TopTab: Identifiable {
    case conversation(ClaudeConversation)
    case terminal(TerminalSession)

    var id: UUID {
        switch self {
        case .conversation(let c): return c.id
        case .terminal(let t): return t.id
        }
    }
}
