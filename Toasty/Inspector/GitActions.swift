import Foundation

/// What the Git widget's buttons do: commit the files left checked (with
/// or without pushing), push, and pull. One at a time; each reads the
/// status again when it's done, and a failure's message is kept for the
/// widget to show.
extension GitChanges {
    /// The files the next commit takes: every change not unchecked.
    var included: [File] { files.filter { !excluded.contains($0.path) } }

    var canCommit: Bool {
        busy == nil && !included.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toggleIncluded(_ file: File) {
        if excluded.contains(file.path) { excluded.remove(file.path) } else { excluded.insert(file.path) }
    }

    /// Commit the checked files with the typed message; then push, if asked.
    func commit(andPush push: Bool) {
        guard canCommit, let root else { return }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Renames commit both sides; deletions are staged as such by `add -A`.
        let paths = included.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        let needsUpstream = upstream == nil
        run(push ? "Committing and Pushing…" : "Committing…") {
            var r = Self.git(["add", "-A", "--"] + paths, in: root)
            guard r.status == 0 else { return r }
            r = Self.git(["commit", "-m", message, "--only", "--"] + paths, in: root)
            guard r.status == 0, push else { return r }
            return Self.git(needsUpstream ? ["push", "-u", "origin", "HEAD"] : ["push"], in: root, timeout: 120)
        } done: { [weak self] ok in
            guard let self, ok else { return }
            self.message = ""
            self.excluded = []
        }
    }

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

    private func run(_ label: String, _ work: @escaping @Sendable () -> GitResult,
                     done: ((Bool) -> Void)? = nil) {
        busy = label
        actionError = nil
        Task {
            let r = await Task.detached(priority: .userInitiated) { work() }.value
            busy = nil
            let ok = r.status == 0
            if !ok {
                let text = (r.error.isEmpty ? r.text : r.error).trimmingCharacters(in: .whitespacesAndNewlines)
                actionError = text.isEmpty ? "git failed" : String(text.prefix(300))
            }
            done?(ok)
            refresh()
        }
    }
}
