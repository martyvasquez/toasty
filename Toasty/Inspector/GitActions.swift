import Foundation

/// What the Git widget's buttons do: push and pull. One at a time; each
/// reads the status again when it's done, and a failure's message is kept
/// for the widget to show.
extension GitChanges {
    func push() {
        guard busy == nil, let root else { return }
        let needsUpstream = upstream == nil
        run("Pushing…") {
            Self.git(needsUpstream ? ["push", "-u", "origin", "HEAD"] : ["push"], in: root, timeout: 120)
        }
    }

    func pull() {
        guard busy == nil, let root else { return }
        run("Pulling…") { Self.git(["pull", "--ff-only"], in: root, timeout: 120) }
    }

    private func run(_ label: String, _ work: @escaping @Sendable () -> GitResult) {
        busy = label
        actionError = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) { work() }.value
            busy = nil
            if r.status != 0 {
                let text = (r.error.isEmpty ? r.text : r.error).trimmingCharacters(in: .whitespacesAndNewlines)
                actionError = text.isEmpty ? "git failed" : String(text.prefix(300))
            }
            refresh()
        }
    }
}
