import Foundation

/// Terms Toasty gathers by itself for each dictation (the user's choice:
/// "context vocabulary"), after the user's own files, in this order:
/// 1. code names in the current conversation, newest first;
/// 2. names of the files being changed (git status);
/// 3. names of files changed in recent commits;
/// 4. the project's own names (project.yml, Package.swift, package.json, Cargo.toml).
///
/// Only names that look like code or aren't ordinary English get in (see
/// `isEligible`): ordinary words as terms turn real speech into the term
/// ("cloud" → "Claude"), which is the main risk of a vocabulary.
nonisolated enum ContextVocabulary {
    struct Input: Sendable {
        var folder: String?
        /// Conversation text, newest first (messages, tool inputs).
        var conversation: [String] = []
        /// Paths changed in the working tree.
        var changed: [String] = []
    }

    struct Found: Equatable, Sendable {
        var text: String
        var source: Source
    }

    enum Source: String, Sendable { case conversation, changed, recent, project }

    /// Per-source caps, so one source can't crowd out the others.
    static let caps: [Source: Int] = [.conversation: 24, .changed: 12, .recent: 12, .project: 8]

    /// Does file and git I/O: call off the main thread.
    static func gather(_ input: Input) -> [Found] {
        var found: [Found] = []
        var seen = Set<String>()
        func add(_ names: [String], _ source: Source) {
            var count = 0
            for name in names where count < caps[source, default: 0] {
                guard isEligible(name), seen.insert(name.lowercased()).inserted else { continue }
                found.append(Found(text: name, source: source))
                count += 1
            }
        }
        add(input.conversation.flatMap(names(in:)), .conversation)
        add(input.changed.compactMap(stem), .changed)
        if let folder = input.folder {
            add(recentFiles(in: folder).compactMap(stem), .recent)
            add(projectNames(in: folder), .project)
        }
        return found
    }

    // MARK: Eligibility

    /// Whether `name` may become an automatic term:
    /// - a type-style compound (`MicCapture`, `TerminalView`, `NSTextView`);
    /// - a lower-camel compound with a part that isn't an ordinary word
    ///   (`useSWR` yes, `isEmpty`/`fileName` no: "is empty" is speech);
    /// - letters with digits (`Context7`, `utf8`), at least 3 letters;
    /// - a single word of 5+ letters that isn't in the system dictionary
    ///   (`Supabase`, `nonisolated`, `libghostty`).
    /// Never: all-caps acronyms, underscores (the engine can't write them),
    /// anything under 4 characters or over 64.
    static func isEligible(_ name: String, isDictionaryWord: (String) -> Bool = Vocabulary.isDictionaryWord) -> Bool {
        guard (4...DictationConfig.maxTermCharacters).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              name.first?.isLetter == true else { return false }
        let letters = name.filter(\.isLetter)
        if letters.allSatisfy(\.isUppercase) { return false }
        if name.contains(where: \.isNumber) { return letters.count >= 3 }
        let parts = camelParts(name)
        if parts.count > 1 {
            if name.first!.isUppercase { return true }
            return !parts.allSatisfy { isDictionaryWord($0) }
        }
        return name.count >= 5 && !isDictionaryWord(name)
    }

    /// `MicCapture` → [Mic, Capture]; `NSTextView` → [NS, Text, View]; `useSWR` → [use, SWR].
    static func camelParts(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(name)
        for (i, c) in chars.enumerated() {
            let startsWord = c.isUppercase && i > 0 && (chars[i - 1].isLowercase
                || (i + 1 < chars.count && chars[i + 1].isLowercase && chars[i - 1].isUppercase))
            if startsWord, !current.isEmpty { parts.append(current); current = "" }
            current.append(c)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: Sources

    /// Identifier-like words in `text`, in order of appearance.
    static func names(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for c in text {
            if c.isASCII && (c.isLetter || c.isNumber || c == "_") { current.append(c) } else {
                if !current.isEmpty { out.append(current); current = "" }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// `Toasty/Dictation/MicCapture.swift` → `MicCapture`.
    static func stem(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? nil : base
    }

    /// Files touched by the last 30 commits, newest first (cached briefly).
    static func recentFiles(in folder: String) -> [String] {
        recentCache.value(for: folder) {
            let out = run("/usr/bin/git", ["-C", folder, "log", "-n", "30", "--name-only", "--pretty=format:"])
            var seen = Set<String>()
            return out.split(whereSeparator: \.isNewline).map(String.init).filter { seen.insert($0).inserted }
        }
    }

    /// Names a project declares about itself.
    static func projectNames(in folder: String) -> [String] {
        let root = URL(fileURLWithPath: folder)
        func read(_ name: String) -> String? { try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        var names: [String] = [root.lastPathComponent]
        if let yml = read("project.yml") {
            names += matches(#"(?m)^name:\s*["']?([A-Za-z0-9]+)"#, in: yml)
            if let targets = yml.range(of: "\ntargets:") {
                names += matches(#"(?m)^  ([A-Za-z][A-Za-z0-9]*):\s*$"#, in: String(yml[targets.upperBound...]))
            }
        }
        if let swift = read("Package.swift") { names += matches(#"name:\s*"([A-Za-z0-9]+)""#, in: swift) }
        if let json = read("package.json"),
           let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
            if let name = object["name"] as? String { names.append(name) }
            for key in ["dependencies", "devDependencies"] {
                names += ((object[key] as? [String: Any])?.keys.sorted() ?? []).map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            }
        }
        if let toml = read("Cargo.toml") {
            names += matches(#"(?m)^name\s*=\s*"([A-Za-z0-9]+)""#, in: toml)
            if let deps = toml.range(of: "[dependencies]") {
                let section = toml[deps.upperBound...].prefix { $0 != "[" }
                names += matches(#"(?m)^([A-Za-z0-9]+)\s*="#, in: String(section))
            }
        }
        return names
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static let recentCache = TimedCache()

    private final class TimedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (at: Date, value: [String])] = [:]
        func value(for key: String, compute: () -> [String]) -> [String] {
            if let hit = lock.withLock({ entries[key] }), Date().timeIntervalSince(hit.at) < 60 { return hit.value }
            let value = compute()
            lock.withLock { entries[key] = (Date(), value) }
            return value
        }
    }
}
