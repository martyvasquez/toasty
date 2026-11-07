import Foundation
import os

/// Runs Claude Code for a conversation tab.
///
/// The agent is the official Claude Agent SDK, driven by a tiny Node script
/// bundled with the app (`toasty-agent.mjs`). The SDK runs the installed
/// `claude` executable (the same one the terminal uses) with the Claude Code
/// system prompt and the user/project/local settings, so the agent loop,
/// tools, CLAUDE.md, hooks, MCP servers, skills, plugins and permissions are
/// Claude Code's own. The bridge only relays SDK messages and permission
/// prompts as JSON lines; nothing in Toasty decides what Claude does.
@MainActor
final class ClaudeAgentProcess {
    private static let logger = Logger(subsystem: "com.martyvasquez.toasty", category: "claude-agent")

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var buffer = Data()
    private var stderrTail: [String] = []
    private let onMessage: ([String: Any]) -> Void
    private let onExit: (_ status: Int32, _ stderr: String) -> Void
    private(set) var isRunning = false

    init(onMessage: @escaping ([String: Any]) -> Void,
         onExit: @escaping (_ status: Int32, _ stderr: String) -> Void) {
        self.onMessage = onMessage
        self.onExit = onExit
    }

    /// Start the bridge. `options` are passed to the bridge's `start`
    /// message (cwd, resume, …).
    func start(environment env: ClaudeEnvironment.Resolved, options: [String: Any]) throws {
        guard let script = Bundle.main.url(forResource: "toasty-agent", withExtension: "mjs", subdirectory: "Bridge") else {
            throw ClaudeAgentError.missingBridge
        }
        process.executableURL = URL(fileURLWithPath: env.node)
        process.arguments = [script.path]
        process.environment = env.variables
        process.currentDirectoryURL = URL(fileURLWithPath: options["cwd"] as? String ?? NSHomeDirectory())
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.receiveStderr(text) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in self?.didExit(status) }
        }

        try process.run()
        isRunning = true
        var start = options
        start["type"] = "start"
        if let claude = env.claude { start["pathToClaudeCodeExecutable"] = claude }
        send(start)
    }

    func send(_ message: [String: Any]) {
        guard isRunning,
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
        } catch {
            Self.logger.error("write to agent failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ends the session: closing stdin makes the bridge end its query, which
    /// stops the claude process. Killed if it doesn't exit promptly.
    func terminate() {
        guard isRunning else { return }
        try? stdin.fileHandleForWriting.close()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { p.terminate() }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            onMessage(obj)
        }
    }

    private func receiveStderr(_ text: String) {
        Self.logger.debug("agent stderr: \(text, privacy: .public)")
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
    }

    private func didExit(_ status: Int32) {
        guard isRunning else { return }
        isRunning = false
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        onExit(status, stderrTail.joined(separator: "\n"))
    }
}

enum ClaudeAgentError: LocalizedError {
    case missingBridge
    case noNode
    case noClaude

    var errorDescription: String? {
        switch self {
        case .missingBridge: "Toasty's Claude bridge is missing from the app bundle."
        case .noNode: "Couldn't find Node.js (needed by the Claude Agent SDK). Install it, or make sure `node` is on the PATH of your login shell."
        case .noClaude: "Couldn't find the `claude` command. Install Claude Code, or make sure `claude` is on the PATH of your login shell."
        }
    }
}

/// The environment Claude Code gets in a conversation tab: the user's
/// login-shell environment, exactly as a terminal tab would have it, so
/// PATH (node, claude, MCP servers, hook commands), API keys and the like
/// match the CLI. Resolved once per launch.
nonisolated enum ClaudeEnvironment {
    struct Resolved: Sendable {
        let variables: [String: String]
        let node: String
        let claude: String?
    }

    @MainActor private static var cached: Resolved?
    @MainActor private static var waiters: [(Result<Resolved, Error>) -> Void] = []
    @MainActor private static var resolving = false

    @MainActor
    static func resolve(_ completion: @escaping (Result<Resolved, Error>) -> Void) {
        if let cached { completion(.success(cached)); return }
        waiters.append(completion)
        guard !resolving else { return }
        resolving = true

        DispatchQueue.global(qos: .userInitiated).async {
            let vars = loginShellEnvironment()
            let result: Result<Resolved, Error>
            if let node = find("node", in: vars) {
                result = .success(Resolved(variables: vars, node: node, claude: find("claude", in: vars)))
            } else {
                result = .failure(ClaudeAgentError.noNode)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .success(let r) = result { cached = r }
                    resolving = false
                    let w = waiters
                    waiters = []
                    w.forEach { $0(result) }
                }
            }
        }
    }

    /// Variables that describe Toasty's own process or terminal, not the
    /// user's environment.
    private static let dropped: Set<String> = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM", "COLORTERM", "TERMINFO",
        "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "GHOSTTY_SHELL_FEATURES", "GHOSTTY_SHELL_INTEGRATION_NO_SUDO",
        "SHLVL", "_", "OLDPWD", "PWD", "XPC_SERVICE_NAME", "XPC_FLAGS",
        "__CF_USER_TEXT_ENCODING", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
    ]

    private static func loginShellEnvironment() -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__TOASTY_ENV_\(UUID().uuidString)__"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // Interactive + login, like a terminal tab, so .zshrc (nvm, PATH
        // additions) is read. Print a marker first: rc files may print too.
        p.arguments = ["-i", "-l", "-c", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        p.environment = base.filter { !dropped.contains($0.key) && !$0.key.hasPrefix("GHOSTTY_") }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        var result: [String: String] = [:]
        do {
            try p.run()
            let deadline = DispatchTime.now() + 8
            let group = DispatchGroup()
            var data = Data()
            group.enter()
            DispatchQueue.global().async {
                data = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            if group.wait(timeout: deadline) == .timedOut {
                p.terminate()
            } else if let s = String(data: data, encoding: .utf8),
                      let r = s.range(of: marker) {
                for entry in s[r.upperBound...].split(separator: "\0") {
                    guard let eq = entry.firstIndex(of: "=") else { continue }
                    result[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
                }
            }
        } catch {}

        if result["PATH"] == nil {
            // Fall back to the app's environment plus common locations.
            let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            base["PATH"] = (extra + [base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
            result = base
        }
        return result.filter { !dropped.contains($0.key) && !$0.key.hasPrefix("GHOSTTY_") }
    }

    private static func find(_ name: String, in env: [String: String]) -> String? {
        let fm = FileManager.default
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        if name == "node" {
            // nvm installs that the shell didn't activate.
            let nvm = "\(NSHomeDirectory())/.nvm/versions/node"
            let versions = (try? fm.contentsOfDirectory(atPath: nvm))?.sorted {
                $0.compare($1, options: .numeric) == .orderedDescending
            } ?? []
            dirs += versions.map { "\(nvm)/\($0)/bin" }
        }
        dirs += ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
