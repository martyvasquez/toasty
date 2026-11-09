import CryptoKit
import Foundation
import os

/// Which Claude Agent SDK conversation tabs run with.
///
/// Claude Code updates itself almost daily; the SDK bundled with Toasty
/// doesn't. So Toasty keeps the SDK in step with the installed `claude` on
/// its own: when a conversation tab starts, it gets the best SDK already on
/// disk (`choice`), and `refresh` checks in the background whether a closer
/// match exists, downloading it from npm for the next tab. No timer: a new
/// tab is what says Toasty is in use.
///
/// The rule: the newest SDK built for a Claude Code version no newer than
/// the installed `claude` (an SDK ahead of Claude Code may send it options
/// it doesn't know). A download is checked against npm's published
/// checksum, must say in its `manifest.json` which Claude Code it was built
/// for, and must pass the bridge's `selftest` before any tab uses it.
///
/// Fallback order: the newest good download, the one before it, then the
/// bundled copy, which is always there. A tab whose SDK dies before Claude
/// Code says anything restarts once on the next one (see
/// `ClaudeConversation.agentExited`); if that works, the first is marked bad
/// and never used again.
@MainActor
final class ClaudeSDK {
    static let shared = ClaudeSDK()
    private static let logger = Logger(subsystem: "com.martyvasquez.toasty", category: "claude-sdk")

    /// An SDK a tab can run with.
    nonisolated struct Option: Equatable, Sendable {
        /// The SDK's version, e.g. "0.3.319".
        let version: String
        /// The Claude Code version it was built for, e.g. "2.1.319".
        let claudeCode: String
        /// Its `sdk.mjs`; nil for the bundled copy.
        let path: String?
        var isBundled: Bool { path == nil }
    }

    /// The bundled SDK, from `Bridge/claude-agent-sdk-VERSION.txt`.
    nonisolated static let bundled: Option? = {
        guard let url = Bundle.main.url(forResource: "claude-agent-sdk-VERSION", withExtension: "txt", subdirectory: "Bridge"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseBundled(text)
    }()

    /// "@anthropic-ai/claude-agent-sdk 0.3.319 (sdk.mjs, built for Claude Code 2.1.319), …"
    nonisolated static func parseBundled(_ text: String) -> Option? {
        guard let sdk = text.firstMatch(of: #/claude-agent-sdk (\d+\.\d+\.\d+)/#)?.1,
              let cc = text.firstMatch(of: #/Claude Code (\d+\.\d+\.\d+)/#)?.1 else { return nil }
        return Option(version: String(sdk), claudeCode: String(cc), path: nil)
    }

    /// Downloaded SDKs: `<root>/<version>/package/{sdk.mjs,manifest.json}`.
    /// Per app (the Debug build keeps its own).
    nonisolated static var root: URL {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Toasty"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SDK", isDirectory: true)
    }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let bad = "ClaudeSDKBad"
        static let claudeKey = "ClaudeSDKClaudeKey"
        static let claudeVersion = "ClaudeSDKClaudeVersion"
        static let checkedFor = "ClaudeSDKCheckedFor"
    }

    /// The installed `claude`'s version, as last read.
    private(set) var claudeVersion: String?
    /// Downloaded SDKs that passed their checks.
    private(set) var installed: [Option] = []
    /// SDK versions that failed; never chosen or downloaded again.
    private(set) var bad: Set<String>
    private var refreshing = false
    /// The last failed registry check, so an offline Mac doesn't retry on
    /// every new tab.
    private var lastFailure: Date?

    private init() {
        bad = Set(defaults.stringArray(forKey: Key.bad) ?? [])
        claudeVersion = defaults.string(forKey: Key.claudeVersion)
        installed = Self.scanInstalled(at: Self.root)
    }

    // MARK: Choosing

    /// The SDK a tab starting now runs with. `excluding` skips a version
    /// suspected of failing (the restart after an early exit).
    func choice(excluding: String? = nil) -> Option {
        let options = installed + (Self.bundled.map { [$0] } ?? [])
        var skip = bad
        if let excluding { skip.insert(excluding) }
        return Self.pick(options, claude: claudeVersion, skip: skip)
            ?? Self.bundled
            ?? Option(version: "bundled", claudeCode: "?", path: nil)
    }

    /// The newest option built for a Claude Code no newer than `claude`.
    /// Unknown `claude` version: the bundled copy only.
    nonisolated static func pick(_ options: [Option], claude: String?, skip: Set<String>) -> Option? {
        let usable = options.filter { o in
            guard !skip.contains(o.version) || o.isBundled else { return false }
            guard let claude else { return o.isBundled }
            return compare(o.claudeCode, claude) != .orderedDescending
        }
        return usable.max { compare($0.version, $1.version) == .orderedAscending }
    }

    /// Versions on npm worth having for `claude`, best first: same release
    /// line as the bundled SDK (0.3.x for Claude Code 2.1.x), patch no
    /// higher than `claude`'s, no prereleases. Not every Claude Code release
    /// gets an SDK, so the best may be a few behind. Empty when `claude` is
    /// on a line the bundled SDK doesn't know (a scheme change: leave it to
    /// a Toasty update).
    nonisolated static func candidates(available: [String], claude: String, bundled: Option) -> [String] {
        let c = numbers(claude), bc = numbers(bundled.claudeCode), bs = numbers(bundled.version)
        guard c.count == 3, bc.count == 3, bs.count == 3, c[0] == bc[0], c[1] == bc[1] else { return [] }
        return available
            .filter { v in
                let n = numbers(v)
                return n.count == 3 && !v.contains("-") && n[0] == bs[0] && n[1] == bs[1] && n[2] <= c[2]
            }
            .sorted { compare($0, $1) == .orderedDescending }
    }

    nonisolated static func numbers(_ v: String) -> [Int] {
        v.split(separator: "-").first.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
    }

    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Failures

    /// A version that kept a tab from starting while an older one worked.
    func markBad(_ version: String) {
        guard Self.bundled?.version != version else { return }
        bad.insert(version)
        defaults.set(Array(bad).sorted(), forKey: Key.bad)
        installed.removeAll { $0.version == version }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(version))
        Self.logger.error("SDK \(version, privacy: .public) marked bad")
    }

    // MARK: Refreshing

    /// Reads the installed `claude`'s version and, when it moved since the
    /// last check, downloads the matching SDK in the background. Cheap when
    /// nothing changed: a file stat, no process, no network.
    func refresh(environment env: ClaudeEnvironment.Resolved, force: Bool = false) {
        guard !refreshing, let claudePath = env.claude, let bundled = Self.bundled,
              let bridge = Bundle.main.url(forResource: "toasty-agent", withExtension: "mjs", subdirectory: "Bridge") else { return }
        if !force, let lastFailure, Date().timeIntervalSince(lastFailure) < 600 { return }
        refreshing = true
        let known = (key: defaults.string(forKey: Key.claudeKey), version: defaults.string(forKey: Key.claudeVersion))
        let checkedFor = force ? nil : defaults.string(forKey: Key.checkedFor)
        let have = Set(installed.map(\.version)).union([bundled.version])
        let bad = self.bad

        Task.detached(priority: .utility) {
            let current = Self.claudeVersion(at: claudePath, environment: env.variables, known: known)
            await MainActor.run { ClaudeSDK.shared.noteClaude(current) }
            guard let claude = current?.version else {
                await MainActor.run { ClaudeSDK.shared.finish(failed: true) }
                return
            }
            if checkedFor == claude {
                await MainActor.run { ClaudeSDK.shared.finish(failed: false) }
                return
            }
            let outcome = await Self.update(claude: claude, bundled: bundled, have: have, bad: bad,
                                            node: env.node, bridge: bridge.path, environment: env.variables)
            await MainActor.run { ClaudeSDK.shared.finish(claude: claude, outcome: outcome) }
        }
    }

    private func noteClaude(_ current: (key: String, version: String)?) {
        guard let current else { return }
        // A new `claude` gives every SDK a fresh chance: a bad mark may have
        // come from something else failing (network, sign-in) the one time
        // that version was tried.
        if let previous = defaults.string(forKey: Key.claudeVersion), previous != current.version, !bad.isEmpty {
            Self.logger.notice("Claude Code \(previous, privacy: .public) → \(current.version, privacy: .public): clearing bad SDK marks")
            bad = []
            defaults.removeObject(forKey: Key.bad)
        }
        claudeVersion = current.version
        defaults.set(current.key, forKey: Key.claudeKey)
        defaults.set(current.version, forKey: Key.claudeVersion)
    }

    private func finish(failed: Bool) {
        refreshing = false
        if failed { lastFailure = Date() }
    }

    private func finish(claude: String, outcome: UpdateOutcome) {
        refreshing = false
        switch outcome {
        case .upToDate:
            defaults.set(claude, forKey: Key.checkedFor)
            lastFailure = nil
        case .installed(let version):
            defaults.set(claude, forKey: Key.checkedFor)
            lastFailure = nil
            Self.logger.notice("SDK \(version, privacy: .public) installed for Claude Code \(claude, privacy: .public)")
        case .rejected(let version, let reason):
            // Counts as checked: the next candidate is tried the next time
            // `claude` changes (or on a forced refresh).
            defaults.set(claude, forKey: Key.checkedFor)
            Self.logger.error("SDK \(version, privacy: .public) rejected: \(reason, privacy: .public)")
            markBad(version)
        case .unavailable(let reason):
            lastFailure = Date()
            Self.logger.notice("SDK update skipped: \(reason, privacy: .public)")
        }
        installed = Self.scanInstalled(at: Self.root)
        prune()
    }

    /// Keeps the two newest usable downloads (the current one and the one
    /// before it); a tab already running keeps its loaded copy regardless.
    private func prune() {
        let keep = Set(installed
            .filter { !bad.contains($0.version) }
            .sorted { Self.compare($0.version, $1.version) == .orderedDescending }
            .prefix(2).map(\.version))
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Self.root.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: Self.root.appendingPathComponent(name))
        }
        installed.removeAll { !keep.contains($0.version) }
    }

    // MARK: Background work

    nonisolated enum UpdateOutcome: Sendable {
        case upToDate
        case installed(String)
        case rejected(String, String)
        case unavailable(String)
    }

    /// Finds the best SDK for `claude` on npm and installs it if it's new.
    nonisolated static func update(claude: String, bundled: Option, have: Set<String>, bad: Set<String>,
                                           node: String, bridge: String, environment: [String: String]) async -> UpdateOutcome {
        let registry = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk")!
        var request = URLRequest(url: registry, timeoutInterval: 20)
        // The abbreviated document: versions with their tarball and checksum.
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = doc["versions"] as? [String: Any] else {
            return .unavailable("couldn't read the npm registry")
        }
        guard let target = candidates(available: Array(versions.keys), claude: claude, bundled: bundled)
            .first(where: { !bad.contains($0) }) else { return .upToDate }
        if have.contains(target) { return .upToDate }
        guard let dist = (versions[target] as? [String: Any])?["dist"] as? [String: Any],
              let tarballString = dist["tarball"] as? String, let tarball = URL(string: tarballString),
              tarball.scheme == "https", let integrity = dist["integrity"] as? String else {
            return .unavailable("npm lists no download for \(target)")
        }
        guard let (archive, tarResponse) = try? await URLSession.shared.data(for: URLRequest(url: tarball, timeoutInterval: 60)),
              (tarResponse as? HTTPURLResponse)?.statusCode == 200 else {
            return .unavailable("couldn't download \(target)")
        }
        // A mismatch may be a bad download, not a bad release: try again later.
        guard verify(archive, integrity: integrity) else { return .unavailable("\(target) failed its checksum") }
        return install(archive, version: target, claude: claude, node: node, bridge: bridge, environment: environment)
    }

    /// npm's `dist.integrity`: "sha512-<base64>".
    nonisolated static func verify(_ data: Data, integrity: String) -> Bool {
        guard integrity.hasPrefix("sha512-"),
              let expected = Data(base64Encoded: String(integrity.dropFirst("sha512-".count))) else { return false }
        return Data(SHA512.hash(data: data)) == expected
    }

    /// Unpacks into a staging folder, checks the manifest and runs the
    /// bridge's selftest against it, then moves it into place.
    nonisolated private static func install(_ archive: Data, version: String, claude: String,
                                            node: String, bridge: String, environment: [String: String]) -> UpdateOutcome {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let file = staging.appendingPathComponent("package.tgz")
            try archive.write(to: file)
            guard run("/usr/bin/tar", ["-xzf", file.path, "-C", staging.path], environment: [:], timeout: 30)?.status == 0 else {
                return .rejected(version, "couldn't unpack")
            }
            try? fm.removeItem(at: file)
        } catch {
            return .unavailable("couldn't write \(root.path): \(error.localizedDescription)")
        }
        guard let option = readInstalled(staging, version: version) else {
            return .rejected(version, "no sdk.mjs or manifest version")
        }
        guard compare(option.claudeCode, claude) != .orderedDescending else {
            return .rejected(version, "built for Claude Code \(option.claudeCode), newer than \(claude)")
        }
        var env = environment
        env["TOASTY_SDK_PATH"] = option.path
        guard let test = run(node, [bridge, "selftest"], environment: env, timeout: 30),
              test.status == 0, test.output.contains("\"ok\":true") else {
            return .rejected(version, "selftest failed")
        }
        let dest = root.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: staging, to: dest) } catch {
            return .unavailable("couldn't move \(version) into place: \(error.localizedDescription)")
        }
        return .installed(version)
    }

    nonisolated static func scanInstalled(at root: URL) -> [Option] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap {
            readInstalled(root.appendingPathComponent($0, isDirectory: true), version: $0)
        }
    }

    nonisolated private static func readInstalled(_ dir: URL, version: String) -> Option? {
        let package = dir.appendingPathComponent("package", isDirectory: true)
        let sdk = package.appendingPathComponent("sdk.mjs")
        guard FileManager.default.fileExists(atPath: sdk.path),
              let data = try? Data(contentsOf: package.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cc = manifest["version"] as? String, numbers(cc).count == 3 else { return nil }
        return Option(version: version, claudeCode: cc, path: sdk.path)
    }

    /// `claude --version`, run only when the executable changed (its
    /// resolved path or modification date), else the remembered answer.
    nonisolated private static func claudeVersion(at path: String, environment: [String: String],
                                                  known: (key: String?, version: String?)) -> (key: String, version: String)? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolved)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(resolved)|\(Int(modified))"
        if key == known.key, let v = known.version { return (key, v) }
        guard let result = run(path, ["--version"], environment: environment, timeout: 15),
              result.status == 0,
              let match = result.output.firstMatch(of: #/(\d+\.\d+\.\d+)/#) else { return nil }
        return (key, String(match.1))
    }

    /// Runs a tool and collects its output; nil if it couldn't start or
    /// ran past `timeout`.
    nonisolated private static func run(_ tool: String, _ args: [String], environment: [String: String],
                                        timeout: TimeInterval) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if !environment.isEmpty { p.environment = environment }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let group = DispatchGroup()
        do { try p.run() } catch { return nil }
        group.enter()
        DispatchQueue.global().async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }

    #if DEBUG
    /// A fake SDK, newer than anything real and built for the installed
    /// `claude`, whose sdk.mjs throws on load.
    func debugInstallBroken() throws {
        guard let claude = claudeVersion else { throw ClaudeDebugError("claude version not known yet; open a conversation first") }
        let package = Self.root.appendingPathComponent("9.9.9/package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"throw new Error("Toasty debug: broken SDK");"#.write(to: package.appendingPathComponent("sdk.mjs"), atomically: true, encoding: .utf8)
        try #"{"version": "\#(claude)"}"#.write(to: package.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        installed = Self.scanInstalled(at: Self.root)
    }

    func debugReset() {
        try? FileManager.default.removeItem(at: Self.root)
        bad = []
        installed = []
        for key in [Key.bad, Key.checkedFor] { defaults.removeObject(forKey: key) }
    }

    struct ClaudeDebugError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
    #endif

    // MARK: Display

    /// For the About panel: "Claude Code 2.1.319 through the official Claude
    /// Agent SDK 0.3.319 (auto-updated)."
    var summary: String {
        let sdk = choice()
        let cc = claudeVersion.map { "Claude Code \($0)" } ?? "Claude Code"
        return "\(cc) through the official Claude Agent SDK \(sdk.version)\(sdk.isBundled ? "" : " (auto-updated)")."
    }
}
