import AppKit
import Combine
import SwiftUI

/// mostty: A workspace window's contents: its Claude Code conversations
/// (the tabs along the top) and its terminals (tabs in the right panel).
///
/// A workspace is one window and one TerminalController. The controller's
/// `surfaceTree` is the terminal tab currently shown in the panel, so
/// Ghostty's own machinery (splits, keybindings, focus, close) works on it
/// unchanged; the other terminal tabs are kept here and swapped in when
/// selected. Conversations aren't terminals at all: each runs Claude Code
/// through the Agent SDK (see ClaudeConversation).
@MainActor
final class ClaudeWorkspace: ObservableObject {
    @Published private(set) var conversations: [ClaudeConversation] = []
    @Published private(set) var selectedID: String?

    struct TerminalTab: Identifiable {
        let id: UUID
        /// The tab's terminals while it's not the one shown. The shown tab
        /// lives in the controller's `surfaceTree`.
        var tree: SplitTree<Ghostty.SurfaceView>
    }

    @Published private(set) var terminals: [TerminalTab] = []
    @Published private(set) var selectedTerminalID: UUID?
    @Published var terminalVisible: Bool { didSet { stateDidChange() } }
    @Published var terminalWidth: CGFloat { didSet { stateDidChange() } }
    /// The terminal sidebar's width as laid out (terminalWidth, clamped to
    /// the window), shared with the titlebar row so its strips line up.
    @Published var panelWidth: CGFloat = 460

    /// The workspace's project folder (new conversations and terminals start here).
    var cwd: String
    weak var controller: TerminalController?

    private var appearanceObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []

    init(cwd: String, terminalVisible: Bool = false, terminalWidth: CGFloat = 460) {
        self.cwd = cwd
        self.terminalVisible = terminalVisible
        self.terminalWidth = terminalWidth
    }

    var selected: ClaudeConversation? {
        conversations.first { $0.id == selectedID } ?? conversations.first
    }

    // MARK: Attaching to a window

    /// Make `controller`'s window this workspace. Its current terminal
    /// becomes the first terminal tab.
    func attach(to controller: TerminalController) {
        self.controller = controller
        let id = UUID()
        if terminals.isEmpty {
            terminals = [TerminalTab(id: id, tree: controller.surfaceTree)]
            selectedTerminalID = id
        }
        // System colors: follow light/dark mode.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak controller] _, _ in
            DispatchQueue.main.async { controller?.syncAppearance() }
        }
        DispatchQueue.main.async { [weak self] in
            controller.syncAppearance()
            self?.conversations.forEach { $0.start() }
            self?.selected?.focusComposer()
        }
    }

    // MARK: Conversations

    @discardableResult
    func newConversation(cwd explicitCwd: String? = nil, resume sessionID: String? = nil, select: Bool = true) -> ClaudeConversation {
        let c = ClaudeConversation(cwd: explicitCwd ?? cwd, sessionID: sessionID)
        add(c, select: select)
        if controller != nil { c.start() }
        return c
    }

    func add(_ conversation: ClaudeConversation, select: Bool) {
        conversation.workspace = self
        // Re-render tabs when a conversation's title or state changes.
        conversation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        if let i = conversations.firstIndex(where: { $0.id == selectedID }) {
            conversations.insert(conversation, at: i + 1)
        } else {
            conversations.append(conversation)
        }
        if select || selectedID == nil { self.select(conversation) }
        stateDidChange()
    }

    func select(_ conversation: ClaudeConversation) {
        selectedID = conversation.id
        conversation.attention = false
        conversation.focusComposer()
        controller?.mosttyRefreshTitle()
        stateDidChange()
        WorkspaceManager.shared.refresh()
    }

    func select(index: Int) {
        guard conversations.indices.contains(index) else { NSSound.beep(); return }
        select(conversations[index])
    }

    func selectRelative(_ delta: Int) {
        guard !conversations.isEmpty else { return }
        let i = conversations.firstIndex { $0.id == selected?.id } ?? 0
        select(conversations[(i + delta + conversations.count) % conversations.count])
    }

    /// Close a conversation tab (asks first while Claude is busy in it).
    func close(_ conversation: ClaudeConversation) {
        let finish = { [weak self] in
            guard let self else { return }
            conversation.stop()
            WorkspaceNotifier.shared.setAgentState(conversation, "idle")
            let i = self.conversations.firstIndex { $0.id == conversation.id } ?? 0
            self.conversations.removeAll { $0.id == conversation.id }
            if self.selectedID == conversation.id, !self.conversations.isEmpty {
                self.select(self.conversations[min(i, self.conversations.count - 1)])
            }
            if self.conversations.isEmpty { self.selectedID = nil }
            self.stateDidChange()
            WorkspaceManager.shared.refresh()
        }
        guard conversation.isBusy, let controller else { finish(); return }
        controller.confirmClose(
            messageText: "Close Tab?",
            informativeText: "Claude Code is working in “\(conversation.title)”. If you close it, it will be stopped. You can resume the session later."
        ) { finish() }
    }

    // MARK: Terminals

    var selectedTerminalIndex: Int? { terminals.firstIndex { $0.id == selectedTerminalID } }

    /// The current tree of a terminal tab (the shown one is the controller's).
    func tree(of tab: TerminalTab) -> SplitTree<Ghostty.SurfaceView> {
        tab.id == selectedTerminalID ? (controller?.surfaceTree ?? tab.tree) : tab.tree
    }

    /// All terminals in the workspace, shown or not.
    var allSurfaces: [Ghostty.SurfaceView] {
        terminals.flatMap { Array(tree(of: $0)) }
    }

    func selectTerminal(_ id: UUID) {
        guard let controller, id != selectedTerminalID,
              let target = terminals.firstIndex(where: { $0.id == id }) else { return }
        if let current = selectedTerminalIndex { terminals[current].tree = controller.surfaceTree }
        selectedTerminalID = id
        controller.surfaceTree = terminals[target].tree
        focusTerminal()
        stateDidChange()
    }

    /// A new shell in a new terminal tab, in the project folder.
    func newTerminal(cwd explicitCwd: String? = nil) {
        guard let controller, let app = controller.ghostty.app else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = explicitCwd ?? cwd
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        if let current = selectedTerminalIndex { terminals[current].tree = controller.surfaceTree }
        let tab = TerminalTab(id: UUID(), tree: .init(view: view))
        terminals.insert(tab, at: (selectedTerminalIndex ?? terminals.count - 1) + 1)
        selectedTerminalID = tab.id
        controller.surfaceTree = tab.tree
        terminalVisible = true
        focusTerminal()
        stateDidChange()
    }

    /// Close a terminal tab (the shown one closes through Ghostty, which
    /// confirms if something is running).
    func closeTerminal(_ id: UUID) {
        guard let controller else { return }
        if id == selectedTerminalID {
            if let root = controller.surfaceTree.root {
                controller.closeSurface(root, withConfirmation: true)
            }
            return
        }
        guard let tab = terminals.first(where: { $0.id == id }) else { return }
        let drop = { [weak self] in
            self?.terminals.removeAll { $0.id == id }
            self?.stateDidChange()
        }
        if tab.tree.contains(where: { $0.needsConfirmQuit }) {
            controller.confirmClose(
                messageText: "Close Terminal?",
                informativeText: "The terminal still has a running process. If you close it the process will be killed.",
                completion: drop)
        } else {
            drop()
        }
    }

    /// The shown terminal tab's last terminal closed: show another tab, or
    /// start a fresh shell if it was the only one (and hide the panel).
    func shownTerminalClosed() {
        guard let controller, let i = selectedTerminalIndex else { return }
        terminals.remove(at: i)
        if terminals.isEmpty {
            guard let app = controller.ghostty.app else { return }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = cwd
            let tab = TerminalTab(id: UUID(), tree: .init(view: Ghostty.SurfaceView(app, baseConfig: config)))
            terminals = [tab]
            terminalVisible = false
        }
        let next = terminals[min(i, terminals.count - 1)]
        selectedTerminalID = next.id
        controller.surfaceTree = next.tree
        if terminalVisible { focusTerminal() } else { selected?.focusComposer() }
        stateDidChange()
    }

    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.controller,
                  let surface = controller.focusedSurface.flatMap({ controller.surfaceTree.contains($0) ? $0 : nil })
                    ?? controller.surfaceTree.first else { return }
            controller.focusSurface(surface)
        }
    }

    /// ⌃⌘T: show and focus the panel; if it's focused, hide it.
    func toggleTerminal() {
        let focused = (controller?.window?.firstResponder as? Ghostty.SurfaceView)
            .map { controller?.surfaceTree.contains($0) ?? false } ?? false
        if !terminalVisible {
            terminalVisible = true
            focusTerminal()
        } else if focused {
            terminalVisible = false
            selected?.focusComposer()
        } else {
            focusTerminal()
        }
    }

    func hideTerminal() {
        terminalVisible = false
        selected?.focusComposer()
    }

    /// Paste a command from Claude's reply into the shown terminal.
    func runInTerminal(_ command: String) {
        terminalVisible = true
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.controller,
                  let surface = controller.focusedSurface.flatMap({ controller.surfaceTree.contains($0) ? $0 : nil })
                    ?? controller.surfaceTree.first else { return }
            controller.focusSurface(surface)
            surface.mosttySendText(text)
        }
    }

    // MARK: State

    var isBusy: Bool { conversations.contains { $0.isBusy } }

    func stop() {
        conversations.forEach { $0.stop() }
    }

    private func stateDidChange() {
        controller?.window?.invalidateRestorableState()
    }

    struct Saved: Codable {
        var cwd: String
        var conversations: [ClaudeConversation.Saved]
        var selected: Int?
        var terminalVisible: Bool
        var terminalWidth: Double
        /// Terminal tabs other than the shown one (which is the window's
        /// surface tree), and where the shown one goes among them.
        var otherTerminals: [SplitTree<Ghostty.SurfaceView>]
        var shownTerminalIndex: Int
    }

    var saved: Saved {
        let shown = selectedTerminalIndex ?? 0
        return Saved(
            cwd: cwd,
            conversations: conversations.map(\.saved),
            selected: conversations.firstIndex { $0.id == selected?.id },
            terminalVisible: terminalVisible,
            terminalWidth: Double(terminalWidth),
            otherTerminals: terminals.enumerated().filter { $0.offset != shown }.map(\.element.tree),
            shownTerminalIndex: shown)
    }

    // MARK: Migration from older mostty windows

    /// A window saved by an older mostty (terminals only, maybe running
    /// Claude Code): its terminal becomes the panel's terminal, and Claude
    /// sessions that were open in it continue as conversation tabs (resumed
    /// natively instead of typing `claude --resume` into the shell).
    static func migrate(_ controller: TerminalController, sessions: [String: WorkspaceNotifier.ClaudeSession]) {
        let resume = UserDefaults.standard.object(forKey: "MosttyResumeClaude") as? Bool ?? true
        let folder = WorkspaceManager.shared.folder(for: controller.workspaceID)
        let found = resume ? sessions.values.filter { WorkspaceNotifier.transcriptURL(for: $0.id) != nil } : []
        let cwd = folder ?? found.first.map(\.cwd).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let w = ClaudeWorkspace(cwd: cwd)
        var seen = Set<String>()
        for s in found where seen.insert(s.id).inserted {
            w.add(ClaudeConversation(cwd: s.cwd.isEmpty ? cwd : s.cwd, sessionID: s.id), select: false)
        }
        if w.conversations.isEmpty { w.add(ClaudeConversation(cwd: cwd), select: true) }
        controller.enableWorkspace(w)
    }

    /// Fold another window of the same workspace (an older mostty's tab)
    /// into this one: its conversations and terminals move here, and its
    /// window closes without stopping anything.
    func absorb(_ other: TerminalController) {
        guard let theirs = other.workspace, theirs !== self else { return }
        let trees = theirs.terminals.map { theirs.tree(of: $0) }
        let moved = theirs.conversations
        theirs.conversations = []
        other.workspace = nil
        for c in moved { add(c, select: false) }
        for tree in trees where !tree.isEmpty {
            terminals.append(TerminalTab(id: UUID(), tree: tree))
        }
        // Empty chats that only stood in for "no session" make way for real ones.
        let unused = conversations.filter { $0.items.isEmpty && $0.sessionID == nil && $0.phase != .working && $0.requests.isEmpty }
        if unused.count < conversations.count {
            for c in unused {
                c.stop()
                conversations.removeAll { $0 === c }
            }
            if !conversations.contains(where: { $0.id == selectedID }), let first = conversations.first {
                select(first)
            }
        }
        // An empty tree closes the window; the surfaces now live here.
        other.surfaceTree = .init()
        stateDidChange()
    }

    /// Rebuild a saved workspace around a restored window.
    static func restore(_ saved: Saved, in controller: TerminalController) -> ClaudeWorkspace {
        let w = ClaudeWorkspace(cwd: saved.cwd, terminalVisible: saved.terminalVisible,
                                terminalWidth: CGFloat(saved.terminalWidth))
        var tabs = saved.otherTerminals.map { TerminalTab(id: UUID(), tree: $0) }
        let shown = TerminalTab(id: UUID(), tree: controller.surfaceTree)
        tabs.insert(shown, at: min(max(0, saved.shownTerminalIndex), tabs.count))
        w.terminals = tabs
        w.selectedTerminalID = shown.id
        for c in saved.conversations { w.add(ClaudeConversation(saved: c), select: false) }
        if let i = saved.selected, w.conversations.indices.contains(i) {
            w.selectedID = w.conversations[i].id
        }
        return w
    }
}
