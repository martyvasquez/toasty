import AppKit
import Darwin

/// A program serving a port from one of the user's folders: a dev server,
/// usually. Whoever started it (Claude in Toasty, Claude somewhere else, the
/// user in a terminal), it's listed in Window ▸ Local Servers.
nonisolated struct LocalServer: Identifiable, Equatable, Sendable {
    let process: ProcessTable.Entry
    /// The ports it listens on, lowest first.
    let ports: [Int]
    /// The folder it runs in.
    let folder: String
    /// What it is, in a couple of words ("astro dev").
    let command: String
    /// Started by Claude Code (in any app).
    let startedByClaude: Bool

    var id: String { "\(process.pid)-\(Int(process.started.timeIntervalSince1970))" }
    var name: String { (folder as NSString).lastPathComponent }
    var url: URL? { ports.first.flatMap { URL(string: "http://localhost:\($0)") } }

    /// "localhost:4321", or "localhost:4321, 4322" for several ports.
    var address: String {
        "localhost:" + ports.map(String.init).joined(separator: ", ")
    }
}

nonisolated enum LocalServers {
    /// A process as the list sees it; the scan reads these from the kernel,
    /// tests make them up.
    struct Candidate: Sendable {
        var process: ProcessTable.Entry
        var ports: [Int]
        var folder: String
        var arguments: [String]
        var startedByClaude: Bool
    }

    /// Every local server running now.
    static func scan() -> [LocalServer] {
        let me = getpid()
        var candidates: [Candidate] = []
        for entry in ProcessTable.mine() where entry.pid != me {
            let ports = ProcessTable.listeningPorts(entry.pid)
            guard !ports.isEmpty, let folder = ProcessTable.folder(entry.pid) else { continue }
            let read = ProcessTable.arguments(entry.pid)
            candidates.append(Candidate(process: entry, ports: ports, folder: folder,
                                        arguments: read?.arguments ?? [],
                                        startedByClaude: read?.environment.contains("CLAUDECODE=1") ?? false))
        }
        return servers(from: candidates, home: NSHomeDirectory())
    }

    /// The candidates worth listing, in order: by folder name, then port.
    static func servers(from candidates: [Candidate], home: String) -> [LocalServer] {
        let listed = candidates.filter { isUserFolder($0.folder, home: home) }
        let byPID = Dictionary(listed.map { ($0.process.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return listed.compactMap { c -> LocalServer? in
            // A worker sharing its parent's port is the same server.
            if c.process.parent != c.process.pid, let parent = byPID[c.process.parent], Set(c.ports).isSubset(of: parent.ports) { return nil }
            return LocalServer(process: c.process, ports: c.ports, folder: c.folder,
                               command: command(c.arguments), startedByClaude: c.startedByClaude)
        }
        .sorted {
            let a = $0.name.localizedStandardCompare($1.name)
            return a != .orderedSame ? a == .orderedAscending : ($0.ports.first ?? 0) < ($1.ports.first ?? 0)
        }
    }

    /// A folder of the user's: in their home folder, but not its Library
    /// (where apps' own helpers run). System services and apps run from `/`.
    static func isUserFolder(_ folder: String, home: String) -> Bool {
        guard folder == home || folder.hasPrefix(home + "/") else { return false }
        return folder != home + "/Library" && !folder.hasPrefix(home + "/Library/")
    }

    // MARK: Naming

    private static let interpreters: Set<String> = ["node", "bun", "deno", "tsx", "ts-node", "ruby", "php", "java"]

    /// What a process is, from its arguments: the tool and what it was asked
    /// to do ("astro dev", "node server.js", "python -m http.server"),
    /// without paths or options.
    static func command(_ arguments: [String]) -> String {
        guard var first = arguments.first, !first.isEmpty else { return "" }
        // A program that renamed itself: "next-server (v16.3.4)".
        if let paren = first.range(of: " (") { first = String(first[..<paren.lowerBound]) }
        let program = (first as NSString).lastPathComponent
        // "python3", "python3.12", and the framework build's "Python".
        let python = program.lowercased().hasPrefix("python")
        var rest = Array(arguments.dropFirst())
        var words: [String]
        if python, let m = rest.firstIndex(of: "-m"), m + 1 < rest.count {
            words = ["python", "-m", rest[m + 1]]
            rest = []
        } else if interpreters.contains(program) || python {
            // The script: the first argument that isn't an option.
            guard let i = rest.firstIndex(where: { !$0.hasPrefix("-") }) else { return program }
            let script = rest[i]
            rest = Array(rest[(i + 1)...])
            if let tool = packageTool(script) {
                words = [tool]
            } else {
                words = [python ? "python" : program, (script as NSString).lastPathComponent]
            }
        } else {
            words = [program]
        }
        // What it was asked to do: the words before the first option.
        for word in rest.prefix(2) {
            guard !word.isEmpty, !word.hasPrefix("-"), !word.contains("/") else { break }
            words.append(word)
        }
        return words.joined(separator: " ")
    }

    /// The tool a script inside `node_modules` belongs to:
    /// `…/node_modules/astro/bin/astro.mjs` and `…/node_modules/.bin/astro`
    /// are both "astro".
    private static func packageTool(_ script: String) -> String? {
        let parts = script.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count else { return nil }
        var name = parts[i + 1]
        if name == ".bin" || name.hasPrefix("@") {
            guard i + 2 < parts.count else { return nil }
            name = parts[i + 2]
        }
        return name
    }

    // MARK: Stopping

    /// Everything to stop with a server: its own children, and the
    /// commands that ran it (`npm run dev` → `next dev` → the server), since
    /// some of those start it again when it stops. The walk up ends at
    /// whatever isn't part of the job: a different process group, a shell,
    /// an app, or (for a server Claude started) Claude Code itself.
    static func family(of server: ProcessTable.Entry, in processes: [ProcessTable.Entry],
                       isWrapper: (ProcessTable.Entry) -> Bool) -> [ProcessTable.Entry] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var family = [server]
        var seen: Set<pid_t> = [server.pid]
        // Down: children, their children, …
        var queue = [server.pid]
        while let pid = queue.popLast() {
            for child in processes where child.parent == pid && seen.insert(child.pid).inserted {
                family.append(child)
                queue.append(child.pid)
            }
        }
        // Up: the commands that ran it.
        var current = server
        while let parent = byPID[current.parent], parent.pid > 1, parent.group == server.group,
              seen.insert(parent.pid).inserted, isWrapper(parent) {
            family.append(parent)
            current = parent
        }
        return family
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login", "tmux", "screen"]

    /// True for a command that only ran the server (`npm run dev`), false
    /// for what hosts it: Toasty, a shell, an app, Claude Code.
    static func isWrapper(_ entry: ProcessTable.Entry, serverStartedByClaude: Bool) -> Bool {
        guard entry.pid != getpid(), let path = ProcessTable.executable(entry.pid) else { return false }
        // An app (a terminal, an editor), as opposed to a command that
        // happens to live in a bundle, like the framework build of Python.
        if NSRunningApplication(processIdentifier: entry.pid) != nil { return false }
        let name = (path as NSString).lastPathComponent
        if shells.contains(name) || name == "claude" { return false }
        // What Claude Code runs carries its mark; Claude Code itself doesn't.
        if serverStartedByClaude, ProcessTable.environment("CLAUDECODE", of: entry.pid) != "1" { return false }
        return true
    }

    /// Stop a server and what belongs to it. Blocks for up to two seconds
    /// (while it waits for them to end): call it off the main thread.
    static func stop(_ server: LocalServer) {
        guard ProcessTable.isAlive(server.process) else { return }
        let family = family(of: server.process, in: ProcessTable.mine()) {
            isWrapper($0, serverStartedByClaude: server.startedByClaude)
        }
        ProcessReaper.stop(family, reason: "stopped in Local Servers")
    }
}
