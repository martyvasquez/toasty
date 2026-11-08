import AppKit
import Darwin

/// Git worktrees: a workspace's branch checked out in its own folder under
/// `~/Toasty Worktrees/<repo>/<branch>`, shown nested under the workspace.
///
/// Creating one copies the repository's ignored *files* (`.env`,
/// `config/local.json`, …) into it, but not ignored *folders*
/// (`node_modules/`, `.venv/`, `build/`): those are big, rebuildable or
/// hold absolute paths. A `.worktreeinclude` (Claude Code's convention,
/// gitignore syntax) adds ignored paths to copy. Removing one deletes its
/// folder and branch: worktrees are for experiments.
nonisolated enum Worktrees {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Toasty Worktrees", isDirectory: true)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Listing

    struct Entry: Equatable, Sendable {
        let path: String
        /// nil when detached.
        let branch: String?
        let prunable: Bool
    }

    /// The repository's worktrees; the first is the main one.
    static func list(in folder: String) -> [Entry]? {
        let r = git(["worktree", "list", "--porcelain"], in: folder)
        guard r.status == 0 else { return nil }
        var entries: [Entry] = []
        for block in r.text.components(separatedBy: "\n\n") {
            var path: String?, branch: String?, prunable = false, bare = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("branch ") {
                    let ref = line.dropFirst(7)
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref)
                }
                else if line.hasPrefix("prunable") { prunable = true }
                else if line == "bare" { bare = true }
            }
            if let path, !bare { entries.append(Entry(path: path, branch: branch, prunable: prunable)) }
        }
        return entries
    }

    /// Whether `folder` is in a git repository (cheap: looks for `.git`).
    static func isInRepository(_ folder: String) -> Bool {
        var dir = URL(fileURLWithPath: folder).standardizedFileURL
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
            dir.deleteLastPathComponent()
        }
        return false
    }

    // MARK: Creating

    struct Created: Sendable {
        let path: String
        let branch: String
        /// Ignored files copied in, relative to the worktree.
        let copied: [String]
    }

    /// A branch name from what the user typed: spaces become dashes.
    static func branchName(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Check out `branch` (made from the main worktree's HEAD if it doesn't
    /// exist) in a new folder, then copy the ignored files in.
    static func create(from folder: String, branch typed: String) throws -> Created {
        guard let main = list(in: folder)?.first?.path else {
            throw Failure("“\((folder as NSString).abbreviatingWithTildeInPath)” isn't in a git repository.")
        }
        let branch = branchName(typed)
        guard !branch.isEmpty, git(["check-ref-format", "--branch", branch], in: main).status == 0 else {
            throw Failure("“\(typed)” isn't a valid branch name.")
        }
        let repoDir = root.appendingPathComponent((main as NSString).lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let base = branch.replacingOccurrences(of: "/", with: "-")
        var dir = repoDir.appendingPathComponent(base).path
        var n = 2
        while FileManager.default.fileExists(atPath: dir) {
            dir = repoDir.appendingPathComponent("\(base)-\(n)").path
            n += 1
        }
        let exists = git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: main).status == 0
        let add = git(exists ? ["worktree", "add", dir, branch] : ["worktree", "add", "-b", branch, dir], in: main)
        guard add.status == 0 else {
            throw Failure(add.error.isEmpty ? "git worktree add failed." : add.error)
        }
        return Created(path: dir, branch: branch, copied: copyIgnoredFiles(from: main, to: dir))
    }

    /// The ignored files to bring into a new worktree, relative to `main`.
    static func ignoredFilesToCopy(in main: String) -> [String] {
        // With --directory, a wholly ignored folder is one entry ending in
        // "/" (skipped); loose ignored files are listed one by one.
        let listed = git(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], in: main)
        var paths = listed.text.split(separator: "\0").map(String.init)
            .filter { !$0.hasSuffix("/") && ($0 as NSString).lastPathComponent != ".DS_Store" }
        // .worktreeinclude: more paths, copied only if they're ignored too.
        let include = (main as NSString).appendingPathComponent(".worktreeinclude")
        if FileManager.default.fileExists(atPath: include) {
            let matched = git(["ls-files", "-z", "--others", "--ignored", "--exclude-from=\(include)"], in: main)
                .text.split(separator: "\0").map(String.init)
            if !matched.isEmpty {
                let ignored = git(["check-ignore", "-z", "--stdin"], in: main,
                                  input: Data(matched.joined(separator: "\0").utf8))
                paths += ignored.text.split(separator: "\0").map(String.init)
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.sorted()
    }

    /// APFS clones (instant, no extra space until changed); never
    /// overwrites a file git checked out.
    static func copyIgnoredFiles(from main: String, to worktree: String) -> [String] {
        let fm = FileManager.default
        var copied: [String] = []
        for path in ignoredFilesToCopy(in: main) {
            let src = (main as NSString).appendingPathComponent(path)
            let dst = (worktree as NSString).appendingPathComponent(path)
            guard !fm.fileExists(atPath: dst) else { continue }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW)) == 0 {
                copied.append(path)
            }
        }
        return copied
    }

    // MARK: Removing

    struct Removal: Sendable {
        let main: String
        let path: String
        /// The branch to delete with it (nil when detached, or when it's the
        /// repository's main branch).
        let branch: String?
        /// Changed and untracked files.
        let uncommitted: Int
        /// Commits on the branch that aren't on any other branch or remote.
        let unsaved: Int
    }

    /// What removing the worktree at `path` would delete.
    static func removal(of path: String) -> Removal? {
        guard let entries = list(in: path), let main = entries.first?.path,
              let entry = entries.dropFirst().first(where: { Worktrees.normalize($0.path) == Worktrees.normalize(path) })
        else { return nil }
        let exists = FileManager.default.fileExists(atPath: entry.path)
        let uncommitted = exists
            ? git(["status", "--porcelain"], in: entry.path).text.split(separator: "\n").count : 0
        var branch = entry.branch
        let ref = branch.map { "refs/heads/\($0)" } ?? "HEAD"
        var args = ["rev-list", "--count", ref, "--not"]
        if let branch { args.append("--exclude=\(branch)") }  // bare name with --branches
        args += ["--branches", "--remotes"]
        let unsaved = Int(git(args, in: exists ? entry.path : main).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // Never delete the main branch, whatever is checked out here.
        if let b = branch, b == defaultBranch(in: main) || b == entries.first?.branch { branch = nil }
        return Removal(main: main, path: entry.path, branch: branch, uncommitted: uncommitted, unsaved: unsaved)
    }

    private static func defaultBranch(in main: String) -> String {
        let r = git(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], in: main)
        let name = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0, let slash = name.firstIndex(of: "/") { return String(name[name.index(after: slash)...]) }
        return "main"
    }

    /// Delete the worktree's folder (whatever is in it) and its branch.
    static func remove(_ r: Removal) throws {
        let gone = !FileManager.default.fileExists(atPath: r.path)
        let result = git(["worktree", "remove", "--force", "--force", r.path], in: r.main)
        if result.status != 0 {
            if gone { _ = git(["worktree", "prune"], in: r.main) }
            else { throw Failure(result.error.isEmpty ? "git worktree remove failed." : result.error) }
        }
        if let branch = r.branch { _ = git(["branch", "-D", branch], in: r.main) }
        // Tidy the repository's folder under ~/Toasty Worktrees.
        let parent = (r.path as NSString).deletingLastPathComponent
        if Worktrees.normalize((parent as NSString).deletingLastPathComponent) == Worktrees.normalize(root.path),
           (try? FileManager.default.contentsOfDirectory(atPath: parent).filter { $0 != ".DS_Store" }.isEmpty) == true {
            try? FileManager.default.removeItem(atPath: parent)
        }
    }

    static func normalize(_ path: String) -> String { WorkspaceStore.normalize(path) }

    static func isPath(_ path: String, inside folder: String) -> Bool {
        let p = normalize(path), f = normalize(folder)
        return p == f || p.hasPrefix(f == "/" ? "/" : f + "/")
    }

    // MARK: git

    static func git(_ args: [String], in dir: String, input: Data? = nil) -> GitChanges.GitResult {
        guard let input else { return GitChanges.git(args, in: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=off"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let inPipe = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return GitChanges.GitResult(status: -1, text: "", error: error.localizedDescription) }
        DispatchQueue.global().async {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return GitChanges.GitResult(status: p.terminationStatus, text: String(decoding: data, as: UTF8.self),
                                    error: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - The store's side

extension WorkspaceStore {
    /// Ask for a branch name, then make the worktree.
    func requestNewWorktree(for id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        let parent = w.parent ?? w
        guard Worktrees.isInRepository(parent.folder) else {
            showError("“\(parent.name)” isn't in a git repository.", title: "Can't Create a Worktree")
            return
        }
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        let main = Worktrees.list(in: parent.folder)?.first
        let repo = (main?.path as NSString?)?.lastPathComponent ?? parent.name
        let from = main?.branch.map { " from “\($0)”" } ?? ""
        alert.informativeText = "Creates a branch\(from) and checks it out in ~/Toasty Worktrees/\(repo). Ignored files like .env are copied in."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Branch name"
        alert.accessoryView = field
        let create = alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        create.isEnabled = false
        let observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
            MainActor.assumeIsolated { create.isEnabled = !Worktrees.branchName(field.stringValue).isEmpty }
        }
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            NotificationCenter.default.removeObserver(observer)
            guard response == .alertFirstButtonReturn else { return }
            self?.createWorktree(for: parent, branch: field.stringValue)
        }
        if let window = AppDelegate.shared.windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Make a worktree of `parent` and open it, nested under `parent`, with
    /// a new tab.
    func createWorktree(for parent: Workspace, branch: String, completion: ((Result<Workspace, Error>) -> Void)? = nil) {
        let pending = PendingWorktree(parentID: parent.id, name: Worktrees.branchName(branch))
        pendingWorktrees.append(pending)
        let folder = parent.folder
        Task {
            let result = await Task.detached { Result { try Worktrees.create(from: folder, branch: branch) } }.value
            self.pendingWorktrees.removeAll { $0.id == pending.id }
            switch result {
            case .success(let made):
                let w = self.workspaces.first { Self.normalize($0.folder) == Self.normalize(made.path) }
                    ?? self.create(folder: made.path, name: made.branch, activate: false, parent: parent)
                w.copiedFiles = made.copied
                self.activate(w.id)
                completion?(.success(w))
            case .failure(let error):
                self.showError(error.localizedDescription, title: "Couldn't Create the Worktree")
                completion?(.failure(error))
            }
        }
    }

    /// Confirm, then delete the worktree's folder and branch and close it.
    func requestRemoveWorktree(_ id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }), w.isWorktree else { return }
        let folder = w.folder
        Task {
            guard let removal = await Task.detached(operation: { Worktrees.removal(of: folder) }).value else {
                // Not a worktree any more (removed outside Toasty).
                self.close(id)
                return
            }
            self.confirmRemoval(of: w, removal)
        }
    }

    /// The removal message: what will be lost, if anything.
    nonisolated static func removalMessage(_ r: Worktrees.Removal, running: String?) -> String {
        var lost: [String] = []
        if r.uncommitted > 0 { lost.append(r.uncommitted == 1 ? "1 uncommitted change" : "\(r.uncommitted) uncommitted changes") }
        if r.unsaved > 0 { lost.append(r.unsaved == 1 ? "1 commit that isn't merged or pushed" : "\(r.unsaved) commits that aren't merged or pushed") }
        var text = lost.isEmpty
            ? (r.branch.map { "Its folder and the branch “\($0)” will be deleted." } ?? "Its folder will be deleted.")
            : "\(lost.joined(separator: " and ")) will be deleted."
        text = text.prefix(1).uppercased() + text.dropFirst()
        if let running { text += " " + running }
        return text
    }

    private func confirmRemoval(of w: Workspace, _ removal: Worktrees.Removal) {
        let running = Activity.shared.closeWarning(conversations: w.conversations, terminals: w.terminals, action: "remove it")
        let alert = NSAlert()
        alert.messageText = "Remove “\(w.name)”?"
        alert.informativeText = Self.removalMessage(removal, running: running)
        alert.alertStyle = removal.uncommitted + removal.unsaved > 0 || running != nil ? .warning : .informational
        let remove = alert.addButton(withTitle: "Remove")
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.removeWorktree(w.id, removal)
        }
        if let window = AppDelegate.shared.windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func removeWorktree(_ id: UUID, _ removal: Worktrees.Removal) {
        // Stop Claude and the shells first: they hold the folder open.
        close(id)
        Task {
            let result = await Task.detached { Result { try Worktrees.remove(removal) } }.value
            if case .failure(let error) = result {
                self.showError(error.localizedDescription, title: "Couldn't Remove the Worktree")
                self.syncWorktrees()
            }
        }
    }

    /// Show the repositories' worktrees under their workspaces, including
    /// ones made outside Toasty (`git worktree add`, Claude Code's own), and
    /// drop worktrees whose folder is gone.
    func syncWorktrees() {
        let tops = workspaces.filter { !$0.isWorktree }.map { ($0.id, $0.folder) }
        Task {
            let found = await Task.detached(priority: .utility) {
                var found: [(UUID, [Worktrees.Entry])] = []
                for (id, folder) in tops where Worktrees.isInRepository(folder) {
                    // Skip a workspace that is itself a linked worktree.
                    guard let entries = Worktrees.list(in: folder), let main = entries.first,
                          Worktrees.isPath(folder, inside: main.path) else { continue }
                    found.append((id, Array(entries.dropFirst())))
                }
                return found
            }.value
            self.applyWorktrees(found)
        }
    }

    private func applyWorktrees(_ found: [(UUID, [Worktrees.Entry])]) {
        for (parentID, entries) in found {
            guard let parent = workspaces.first(where: { $0.id == parentID }) else { continue }
            let live = entries.filter { !$0.prunable }
            for entry in live where !workspaces.contains(where: { Self.normalize($0.folder) == Self.normalize(entry.path) }) {
                create(folder: entry.path, name: entry.branch ?? (entry.path as NSString).lastPathComponent,
                       activate: false, parent: parent)
            }
            // A worktree removed outside Toasty: close it if nothing's running.
            for child in children(of: parentID) where !FileManager.default.fileExists(atPath: child.folder)
                && !child.isWorking && !child.needsAttention {
                close(child.id)
            }
        }
    }

    func showError(_ message: String, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = AppDelegate.shared.windowController?.window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// A worktree being created: a placeholder row under its parent.
struct PendingWorktree: Identifiable, Equatable {
    let id = UUID()
    let parentID: UUID
    let name: String
}
