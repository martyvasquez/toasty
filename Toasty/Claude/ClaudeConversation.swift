import Foundation
import Combine

/// One Claude Code conversation (a tab). Phase 2 stub: the identity, title
/// and status surface the shell needs. Phase 3 replaces this file with the
/// port of mostty's `ClaudeConversation`.
final class ClaudeConversation: ObservableObject, Identifiable {
    enum Phase { case idle, working }

    let id: UUID
    @Published var sessionID: String?
    @Published var cwd: String
    @Published var customTitle: String?
    /// The first prompt sent in this conversation (titles the tab).
    @Published var firstPrompt: String?
    @Published var phase: Phase = .idle
    /// Permission / question / plan requests waiting for the user.
    @Published var requests: [String] = []
    /// Finished while the user wasn't looking.
    @Published var attention = false

    weak var workspace: Workspace?

    init(id: UUID = UUID(), cwd: String, sessionID: String? = nil, customTitle: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.sessionID = sessionID
        self.customTitle = customTitle
    }

    /// Custom name, else the first line of the first prompt (≤40 chars),
    /// else "New Chat".
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let line = firstPrompt?.split(whereSeparator: \.isNewline).first {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t.count > 40 ? String(t.prefix(39)) + "…" : t }
        }
        return "New Chat"
    }

    func stop() {}
}
