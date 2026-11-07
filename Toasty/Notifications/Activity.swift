import AppKit

/// What Claude is doing in each conversation, for everything outside the
/// conversation itself: tab and sidebar status, and (Phase 5) the dock
/// badge, sounds, toasts, macOS notifications, keep-awake and quit
/// warnings.
@MainActor
final class Activity {
    static let shared = Activity()

    enum State: String { case idle, working, waiting }

    private(set) var states: [UUID: State] = [:]

    private init() {
        // Coming back to Toasty: the conversation on screen has been seen.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let c = WorkspaceStore.shared.active?.selected { c.attention = false }
            }
        }
    }

    func state(of conversation: ClaudeConversation) -> State {
        states[conversation.id] ?? .idle
    }

    func setAgentState(_ conversation: ClaudeConversation, _ raw: String) {
        let state = State(rawValue: raw) ?? .idle
        states[conversation.id] = state
    }

    /// Something happened in a conversation the user should know about
    /// (finished, stopped, needs them).
    func present(source conversation: ClaudeConversation, title: String, body: String) {
        if !isVisible(conversation) { conversation.attention = true }
    }

    /// The conversation is on screen: its tab is selected in the shown
    /// workspace and Toasty is frontmost.
    func isVisible(_ conversation: ClaudeConversation) -> Bool {
        guard NSApp.isActive, let w = conversation.workspace else { return false }
        return w.store?.activeID == w.id && w.selectedID == conversation.id
    }

    /// Claude Code's saved transcript for a session:
    /// `~/.claude/projects/<project>/<session>.jsonl`.
    nonisolated static func transcriptURL(for id: String) -> URL? {
        let fm = FileManager.default
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = configDir.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        return dirs
            .map { $0.appendingPathComponent("\(id).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }
}
