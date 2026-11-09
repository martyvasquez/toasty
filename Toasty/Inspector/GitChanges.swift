import AppKit
import Combine

/// The workspace folder's git state for the inspector's Changes tab: the
/// branch, how far it is from its upstream, and every uncommitted file
/// with its line counts. Read-only: it never stages, commits or discards.
final class GitChanges: ObservableObject {
    nonisolated struct File: Identifiable, Equatable {
        /// Path relative to the repository root.
        let path: String
        /// The path before a rename or copy.
        let oldPath: String?
        let status: Status
        /// Lines added and removed; nil for binary files.
        let added: Int?
        let removed: Int?
        /// The repository root, to resolve `path`.
        let root: String

        var id: String { path }
        var url: URL { URL(fileURLWithPath: root).appendingPathComponent(path) }
        var name: String { (path as NSString).lastPathComponent }
        var directory: String {
            let d = (path as NSString).deletingLastPathComponent
            return d.isEmpty ? "" : d
        }
    }

    nonisolated enum Status: String {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "U"
        case conflicted = "!"
        case typeChanged = "T"

        /// The letter shown on the row. A new file reads "N" whether or
        /// not it's staged: git's "A" vs "U" split means nothing to most people.
        var mark: String {
            switch self {
            case .added, .untracked: "N"
            default: rawValue
            }
        }

        var label: String {
            switch self {
            case .modified: "Modified"
            case .added: "New"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .untracked: "New"
            case .conflicted: "Conflicted"
            case .typeChanged: "Type Changed"
            }
        }
    }

    nonisolated enum State: Equatable {
        case loading
        case notRepository
        case failed(String)
        case loaded
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var branch: String?
    @Published private(set) var upstream: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var files: [File] = []
    @Published private(set) var root: String?

    var folder: String
    private var running = false
    private var again = false

    init(folder: String) {
        self.folder = folder
    }

    var totalAdded: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var totalRemoved: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }

    /// Read the status again (coalesced while a read is running).
    func refresh() {
        if running { again = true; return }
        running = true
        let folder = folder
        Task.detached(priority: .utility) {
            let snapshot = Self.read(folder: folder)
            await MainActor.run { self.apply(snapshot) }
        }
    }

    private func apply(_ s: Snapshot) {
        running = false
        if state != s.state { state = s.state }
        if branch != s.branch { branch = s.branch }
        if upstream != s.upstream { upstream = s.upstream }
        if ahead != s.ahead { ahead = s.ahead }
        if behind != s.behind { behind = s.behind }
        if root != s.root { root = s.root }
        if files != s.files { files = s.files }
        if again { again = false; refresh() }
    }

    // MARK: Reading (off the main thread)

    nonisolated struct Snapshot: Sendable {
        var state: State = .loading
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var root: String?
        var files: [File] = []
    }

    nonisolated static func read(folder: String) -> Snapshot {
        var s = Snapshot()
        let top = git(["rev-parse", "--show-toplevel"], in: folder)
        guard top.status == 0 else {
            s.state = top.error.contains("not a git repository") ? .notRepository : .failed(top.error.isEmpty ? "git failed" : top.error)
            return s
        }
        let root = top.text.trimmingCharacters(in: .whitespacesAndNewlines)
        s.root = root

        let status = git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root)
        guard status.status == 0 else {
            s.state = .failed(status.error)
            return s
        }
        // Line counts for tracked changes (staged and unstaged, against HEAD).
        let hasHead = git(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).status == 0
        let numstat = git(hasHead ? ["diff", "HEAD", "--numstat", "-z", "-M"] : ["diff", "--cached", "--numstat", "-z"], in: root)
        let counts = parseNumstat(numstat.text)

        let entries = status.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [File] = []
        var i = 0
        while i < entries.count {
            let e = entries[i]
            i += 1
            if e.hasPrefix("# branch.head ") {
                let b = String(e.dropFirst(14))
                s.branch = b == "(detached)" ? nil : b
            } else if e.hasPrefix("# branch.upstream ") {
                s.upstream = String(e.dropFirst(18))
            } else if e.hasPrefix("# branch.ab ") {
                let parts = e.dropFirst(12).split(separator: " ")
                if parts.count == 2 {
                    s.ahead = Int(parts[0].dropFirst()) ?? 0
                    s.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if e.hasPrefix("1 ") || e.hasPrefix("2 ") || e.hasPrefix("u ") {
                let isRename = e.hasPrefix("2 ")
                // Fields before the path: 1 → 8, 2 → 9, u → 10.
                let fieldCount = e.hasPrefix("1 ") ? 8 : isRename ? 9 : 10
                let parts = e.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard parts.count == fieldCount + 1 else { continue }
                let xy = Array(parts[1])
                let path = String(parts[fieldCount])
                var oldPath: String?
                if isRename, i < entries.count { oldPath = entries[i]; i += 1 }
                let status: Status
                if e.hasPrefix("u ") {
                    status = .conflicted
                } else {
                    // The more significant of the staged and unstaged codes.
                    let codes = xy.filter { $0 != "." }
                    switch codes.first(where: { "RCAD".contains($0) }) ?? codes.first ?? "M" {
                    case "A": status = .added
                    case "D": status = .deleted
                    case "R": status = .renamed
                    case "C": status = .copied
                    case "T": status = .typeChanged
                    default: status = .modified
                    }
                }
                let c = counts[path]
                files.append(File(path: path, oldPath: oldPath, status: status,
                                  added: c?.0 ?? (status == .deleted ? nil : 0), removed: c?.1 ?? 0, root: root))
            } else if e.hasPrefix("? ") {
                let path = String(e.dropFirst(2))
                let lines = lineCount(URL(fileURLWithPath: root).appendingPathComponent(path))
                files.append(File(path: path, oldPath: nil, status: .untracked, added: lines, removed: lines == nil ? nil : 0, root: root))
            }
        }
        s.files = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        s.state = .loaded
        return s
    }

    /// `added\tremoved\tpath\0`, or for renames `added\tremoved\t\0old\0new\0`.
    nonisolated private static func parseNumstat(_ text: String) -> [String: (Int?, Int?)] {
        var out: [String: (Int?, Int?)] = [:]
        let parts = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < parts.count {
            let fields = parts[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard fields.count == 3 else { continue }
            let added = Int(fields[0]), removed = Int(fields[1])
            if fields[2].isEmpty {
                // Rename: the next two entries are the old and new paths.
                guard i + 1 < parts.count else { break }
                out[parts[i + 1]] = (added, removed)
                i += 2
            } else {
                out[String(fields[2])] = (added, removed)
            }
        }
        return out
    }

    /// Lines in a new file; nil if it looks binary or is too big to read.
    nonisolated private static func lineCount(_ url: URL) -> Int? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 8_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        if data.isEmpty { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return newlines + (data.last == 0x0A ? 0 : 1)
    }

    // MARK: Diffs

    /// Unified diff lines of one file against HEAD, for `ClaudeDiffView`.
    nonisolated static func diff(_ file: File) -> [(Character, String)] {
        let root = file.root
        let result: GitResult
        if file.status == .untracked {
            result = git(["diff", "--no-index", "--no-color", "--", "/dev/null", file.path], in: root)
        } else {
            let hasHead = git(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).status == 0
            var args = ["diff", "--no-color", "-M"]
            args += hasHead ? ["HEAD"] : ["--cached"]
            args += ["--"] + (file.oldPath.map { [$0] } ?? []) + [file.path]
            result = git(args, in: root)
        }
        var lines: [(Character, String)] = []
        var inHunk = false
        for line in result.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                inHunk = true
                // Keep the function context after the second @@, if any.
                lines.append(("@", String(line)))
            } else if inHunk, let first = line.first, "+- ".contains(first) {
                lines.append((first, String(line.dropFirst())))
            } else if line.hasPrefix("Binary files") {
                lines.append(("@", "Binary file"))
            } else if line.hasPrefix("diff --git") {
                inHunk = false
            }
        }
        while let last = lines.last, last.0 == " ", last.1.isEmpty { lines.removeLast() }
        return lines
    }

    // MARK: Running git

    nonisolated struct GitResult: Sendable {
        let status: Int32
        let text: String
        let error: String
    }

    nonisolated static func git(_ args: [String], in dir: String) -> GitResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.quotepath=off"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        // Never take the index lock (a status poll mustn't block the
        // user's or Claude's git commands), and never prompt.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return GitResult(status: -1, text: "", error: error.localizedDescription) }
        // Read before waiting so a large output can't fill the pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return GitResult(status: p.terminationStatus,
                         text: String(decoding: data, as: UTF8.self),
                         error: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
