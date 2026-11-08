import Foundation

/// Spoken paths become the repo's real paths: after spoken symbols turn
/// "source slash temp" into `source/temp`, a repo with `src/tmp/` gets
/// `src/tmp`. Each part must match the real one: same name ignoring case,
/// a common abbreviation (source ≈ src, temp ≈ tmp, library ≈ lib),
/// singular/plural (model ≈ models), or one letter off for longer names.
/// A path is rewritten only when exactly one real path fits best;
/// otherwise the text stays as said.
nonisolated enum RepoPaths {
    /// The repo's files and folders (relative), from `git ls-files` (cached briefly).
    static func index(folder: String) -> Index {
        cache.value(for: folder) {
            let out = run(["-C", folder, "ls-files", "--cached", "--others", "--exclude-standard"])
            return Index(files: out.split(whereSeparator: \.isNewline).map(String.init))
        }
    }

    struct Index: Sendable {
        /// Every file and every folder, as segment arrays.
        let paths: [[String]]

        init(files: [String]) {
            var all = Set<String>()
            for file in files.prefix(50_000) {
                var parts = file.split(separator: "/").map(String.init)
                all.insert(parts.joined(separator: "/"))
                while parts.count > 1 { parts.removeLast(); all.insert(parts.joined(separator: "/")) }
            }
            paths = all.sorted().map { $0.split(separator: "/").map(String.init) }
        }
    }

    /// Rewrites path-like tokens (with a `/`) in `text` to real repo paths.
    static func resolve(_ text: String, in index: Index) -> String {
        guard !index.paths.isEmpty, text.contains("/") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"[~A-Za-z0-9_.\-]*(?:/[A-Za-z0-9_.\-]+)+/?|[A-Za-z0-9_\-]+/(?=[\s,;:)]|$)"#) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var token = ns.substring(with: match.range)
            // A sentence's own period isn't part of the path.
            var trailing = ""
            while token.hasSuffix(".") { token.removeLast(); trailing += "." }
            guard let real = best(for: token, in: index), real != token else { continue }
            let range = Range(match.range, in: result)!
            result.replaceSubrange(range, with: real + trailing)
        }
        return result
    }

    /// The single best real path for `token`, keeping a leading `~/`, `./`
    /// or `/` and a trailing `/` as said.
    static func best(for token: String, in index: Index) -> String? {
        var body = token
        var prefix = ""
        for p in ["~/", "./", "/"] where body.hasPrefix(p) { prefix = p; body.removeFirst(p.count); break }
        if prefix == "~/" { return nil }  // outside the repo
        let slash = body.hasSuffix("/") ? "/" : ""
        if !slash.isEmpty { body.removeLast() }
        let spoken = body.split(separator: "/").map(String.init)
        guard spoken.count >= 2 || (spoken.count == 1 && !slash.isEmpty), !spoken.contains(where: \.isEmpty) else { return nil }

        var bestScore = Int.max
        var bestPaths = Set<String>()
        for path in index.paths where path.count >= spoken.count {
            // The spoken parts may name the end of a deeper path, or (with a
            // leading "/" or "./") must start at the root.
            let starts = prefix.isEmpty ? Array(0...(path.count - spoken.count)) : [0]
            for start in starts {
                var score = 0
                for (i, part) in spoken.enumerated() {
                    guard let s = similarity(part, path[start + i]) else { score = Int.max; break }
                    score += s
                }
                guard score != Int.max else { continue }
                // Prefer shorter real paths (fewer unspoken folders before).
                let total = score * 10 + start
                let real = path[start..<(start + spoken.count)].joined(separator: "/")
                if total < bestScore { bestScore = total; bestPaths = [real] } else if total == bestScore { bestPaths.insert(real) }
            }
        }
        guard bestPaths.count == 1, let real = bestPaths.first else { return nil }
        return prefix + real + slash
    }

    /// How far a spoken part is from a real one: 0 same, 1 abbreviation or
    /// plural, 2 one letter off; nil when unrelated.
    static func similarity(_ spoken: String, _ real: String) -> Int? {
        let a = spoken.lowercased(), b = real.lowercased()
        if a == b { return 0 }
        let (aName, aExt) = split(a), (bName, bExt) = split(b)
        // A spoken extension must match ("user.rs" is never "user.ts").
        if !aExt.isEmpty, aExt != bExt { return nil }
        if aExt.isEmpty, !bExt.isEmpty { return nil }
        if aName == bName { return 0 }
        if abbreviations[aName]?.contains(bName) == true || abbreviations[bName]?.contains(aName) == true { return 1 }
        if aName + "s" == bName || bName + "s" == aName || aName + "es" == bName || bName + "es" == aName { return 1 }
        let squash = { (s: String) in s.filter { $0.isLetter || $0.isNumber } }
        if squash(aName) == squash(bName), !squash(aName).isEmpty { return 1 }  // user-models ≈ user_models
        if min(aName.count, bName.count) >= 5, editDistance(aName, bName) <= 1 { return 2 }
        return nil
    }

    private static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Spoken word → names folders are commonly given.
    static let abbreviations: [String: Set<String>] = [
        "source": ["src"], "sources": ["src", "srcs"],
        "temp": ["tmp"], "temporary": ["tmp", "temp"],
        "library": ["lib"], "libraries": ["lib", "libs"],
        "documents": ["docs", "doc"], "documentation": ["docs", "doc"], "doc": ["docs"],
        "configuration": ["config", "conf", "cfg"], "configurations": ["configs", "config"], "config": ["conf", "cfg"],
        "application": ["app"], "applications": ["apps"],
        "binary": ["bin"], "binaries": ["bin"],
        "package": ["pkg"], "packages": ["pkg", "pkgs"],
        "include": ["inc"], "includes": ["include", "inc"],
        "utilities": ["utils", "util"], "utility": ["util", "utils"], "utils": ["util"],
        "development": ["dev"], "production": ["prod"],
        "environment": ["env"], "environments": ["envs", "env"],
        "test": ["tests", "spec", "specs"], "tests": ["test", "spec", "specs", "__tests__"],
        "component": ["components"], "public": ["pub"],
        "javascript": ["js"], "typescript": ["ts"], "python": ["py"], "markdown": ["md"],
        "image": ["img", "images"], "images": ["img"],
        "assets": ["asset"], "scripts": ["script", "bin"],
        "vendor": ["vendors"], "node modules": ["node_modules"],
    ]

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    // MARK: git

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static let cache = IndexCache()

    private final class IndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (at: Date, value: Index)] = [:]
        func value(for key: String, compute: () -> Index) -> Index {
            if let hit = lock.withLock({ entries[key] }), Date().timeIntervalSince(hit.at) < 60 { return hit.value }
            let value = compute()
            lock.withLock { entries[key] = (Date(), value) }
            return value
        }
    }
}
