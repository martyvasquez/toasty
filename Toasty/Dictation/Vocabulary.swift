import Foundation
import os

/// The vocabulary (plan §10.4–10.5): terms that bias the engine (rescoring
/// checks the audio), replacements applied to the text, and casing fixes.
/// Two plain-text files, re-read whenever they change:
/// - global: ~/Library/Application Support/<app name>/vocabulary.txt
///   (created from a commented template on first use; the Debug build's
///   own folder for Toasty Debug);
/// - project: <workspace folder>/.toasty/vocabulary.txt (optional).
nonisolated enum Vocabulary {
    private static let log = Logger(subsystem: "com.martyvasquez.toasty", category: "vocabulary")

    struct Term: Equatable, Sendable {
        var text: String
        var soundsLike: [String] = []
        /// `Term!`: fix the casing even though it's a dictionary word.
        var forced = false
    }

    struct Replacement: Equatable, Sendable {
        var from: String
        var to: String
    }

    struct File: Equatable, Sendable {
        var terms: [Term] = []
        var replacements: [Replacement] = []
        var warnings: [String] = []
    }

    /// What one dictation uses.
    struct Effective: Sendable {
        var engine = VocabularySnapshot()
        var replacements: [Replacement] = []
        var casing: [Term] = []
        /// Where each engine term came from (project, global, conversation…).
        var sources: [String] = []
        /// The repo's paths, for spoken paths (nil outside a repo).
        var repo: RepoPaths.Index?
    }

    // MARK: Parsing

    /// One entry per line; `#` comments and blank lines ignored.
    ///   Claude Code                        a term
    ///   libghostty = lib ghostty, lib ghosty   a term with sounds-like spellings (≤ 16)
    ///   cloud code -> Claude Code          a replacement (text only, always applied)
    ///   PTY!                               force the casing fix for a dictionary word
    static func parse(_ text: String) -> File {
        var file = File()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let arrow = line.range(of: "->") {
                let from = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty else { file.warnings.append("“\(line)”: nothing to replace"); continue }
                if from.filter(\.isLetter).count <= 3 {
                    file.warnings.append("“\(from)” is very short; it may replace more than you mean.")
                } else if !from.contains(" "), isDictionaryWord(from) {
                    file.warnings.append("“\(from)” is an ordinary word; every “\(from)” will become “\(to)”.")
                }
                file.replacements.append(Replacement(from: from, to: to))
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            var name = parts[0]
            var forced = false
            if name.hasSuffix("!") { forced = true; name.removeLast(); name = name.trimmingCharacters(in: .whitespaces) }
            guard !name.isEmpty else { continue }
            if name.count > DictationConfig.maxTermCharacters || name.contains(where: { "/\\".contains($0) }) {
                file.warnings.append("“\(name)” skipped: terms are at most \(DictationConfig.maxTermCharacters) characters, without / or \\.")
                continue
            }
            let spellings = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            if !name.contains(" ") && isDictionaryWord(name) {
                file.warnings.append("“\(name)” is also an ordinary word, so it may replace words that sound like it. A longer form (e.g. “Claude Code”, not “Claude”) is safer.")
            }
            file.terms.append(Term(text: name, soundsLike: Array(spellings.prefix(DictationConfig.maxSoundsLikePerTerm)), forced: forced))
        }
        return file
    }

    /// Project before global; duplicates (case-insensitive) dropped; at most
    /// 64 engine terms (the rest logged). Replacements: project first.
    static func combine(project: File?, global: File?, context: [ContextVocabulary.Found] = []) -> Effective {
        var effective = Effective()
        var seen = Set<String>()
        var dropped: [String] = []
        let all = (project?.terms ?? []).map { ($0, "project file") }
            + (global?.terms ?? []).map { ($0, "global file") }
            + context.map { (Term(text: $0.text), $0.source.rawValue) }
        for (term, source) in all {
            guard seen.insert(term.text.lowercased()).inserted else { continue }
            effective.casing.append(term)
            if effective.engine.terms.count < DictationConfig.maxVocabularyTerms {
                effective.engine.terms.append(.init(text: term.text, soundsLike: term.soundsLike))
                effective.sources.append(source)
            } else if source.hasSuffix("file") {
                dropped.append(term.text)
            }
        }
        if !dropped.isEmpty {
            log.warning("vocabulary over \(DictationConfig.maxVocabularyTerms) terms; not sent to the engine: \(dropped.joined(separator: ", "), privacy: .public)")
        }
        // The shipped catalogue fixes casing and known mishearings after the
        // user's own entries (theirs win: first match, first rule).
        for entry in DevVocabulary.catalogue.entries where seen.insert(entry.term.text.lowercased()).inserted {
            effective.casing.append(entry.term)
        }
        effective.replacements = (project?.replacements ?? []) + (global?.replacements ?? [])
            + DevVocabulary.catalogue.replacements
        return effective
    }

    // MARK: Files

    static var globalURL: URL {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Toasty"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("vocabulary.txt")
    }

    static func projectURL(folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(".toasty", isDirectory: true)
            .appendingPathComponent("vocabulary.txt")
    }

    /// Creates the global file from the template if it doesn't exist.
    @discardableResult
    static func ensureGlobalFile() -> URL {
        let url = globalURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Creates `<folder>/.toasty/vocabulary.txt` from the project template if missing.
    @discardableResult
    static func ensureProjectFile(folder: String) -> URL {
        let url = projectURL(folder: folder)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? projectTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    static let projectTemplate = """
    # Dictation vocabulary for this project (it comes before your own
    # vocabulary). Same format; commit it to share it with the team.
    #
    #   Product Name                      a term
    #   libfoo = lib foo                  a term plus how it may be heard
    #   foo bar -> FooBar                 a replacement
    #   Widget!                           fix the casing of an ordinary word

    """

    /// The vocabulary for a dictation in `projectFolder` (cheap: files are
    /// re-parsed only when their modification date changes).
    static func effective(projectFolder: String?, context: [ContextVocabulary.Found] = []) -> Effective {
        let global = cache.load(ensureGlobalFile())
        let project = projectFolder.flatMap { cache.load(projectURL(folder: $0)) }
        return combine(project: project, global: global, context: context)
    }

    private static let cache = FileCache()

    private final class FileCache: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [URL: (date: Date, file: File)] = [:]

        func load(_ url: URL) -> File? {
            guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                return nil
            }
            if let hit = lock.withLock({ files[url] }), hit.date == date { return hit.file }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let file = parse(text)
            for warning in file.warnings {
                Vocabulary.log.warning("\(url.path, privacy: .public): \(warning, privacy: .public)")
            }
            lock.withLock { files[url] = (date, file) }
            return file
        }
    }

    // MARK: Dictionary words (/usr/share/dict/words)

    /// Loads the system word list in the background (call at launch).
    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = words }
    }

    private static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()

    /// Whether every word of `phrase` is an ordinary word (case-insensitive).
    /// The system list has no inflections, so "resumed", "scrolls",
    /// "running" are checked by their stem too.
    static func isDictionaryWord(_ phrase: String) -> Bool {
        let parts = phrase.lowercased().split { !$0.isLetter }
        return !parts.isEmpty && parts.allSatisfy { isWord(String($0)) }
    }

    private static func isWord(_ word: String) -> Bool {
        if words.contains(word) { return true }
        return stems(word).contains { $0.count >= 3 && words.contains($0) }
    }

    /// Candidate stems for an inflected English word.
    static func stems(_ word: String) -> [String] {
        var out: [String] = []
        func strip(_ suffix: String, _ replacements: [String] = [""]) {
            guard word.hasSuffix(suffix), word.count > suffix.count + 2 else { return }
            let base = String(word.dropLast(suffix.count))
            for r in replacements { out.append(base + r) }
            // stopped → stop, running → run
            if let last = base.last, base.count >= 3, base.dropLast().last == last, !"aeiou".contains(last) {
                out.append(String(base.dropLast()))
            }
        }
        strip("ies", ["y"]); strip("ied", ["y"]); strip("ier", ["y"]); strip("iest", ["y"])
        strip("es"); strip("s"); strip("ed", ["", "e"]); strip("ing", ["", "e"])
        strip("ers", ["", "e"]); strip("er", ["", "e"]); strip("est", ["", "e"])
        strip("ly"); strip("ily", ["y"]); strip("ness")
        return out
    }

    // MARK: Template

    static let template = """
    # Toasty dictation vocabulary: names and terms you say in prompts.
    # One entry per line. Lines starting with # are ignored.
    #
    #   Claude Code                       a term, written exactly as it should appear.
    #                                     The speech engine favours it when the audio
    #                                     supports it, and its casing is fixed in text.
    #   libghostty = lib ghostty          a term plus how it may be heard (sounds-like).
    #   nimblest -> Nimbalyst             a replacement: always applied to the text.
    #   Codex!                            "!" also fixes the casing of an ordinary word
    #                                     ("codex" → "Codex" everywhere).
    #
    # Tips:
    # - Prefer multi-word terms. A single short or ordinary word ("Claude", "Node")
    #   can turn words that sound like it into the term ("cloud" → "Claude").
    # - Casing is only fixed for words that aren't ordinary English words, unless
    #   marked with "!".
    # - Up to 64 terms reach the engine; a project's own file
    #   (<project>/.toasty/vocabulary.txt) comes first.

    # Toasty already knows common developer names (Claude Code, TypeScript,
    # Supabase, Next.js, …) and the names in your project. Add what it
    # doesn't: your product, teammates, internal tools.
    #
    # Single words that sound like ordinary ones: add only if you say them
    # often (remove the "# ").
    # Codex!
    # worktree
    """
}

// MARK: - Text step 6: casing fixes (plan §10.5)

nonisolated extension TextPipeline {
    private static let regexCache = OSAllocatedUnfairLockCache()

    private static func casingRegex(_ term: String) -> NSRegularExpression? {
        regexCache.value(term) {
            // Not inside a file name or path: "api.ts", "project.yaml", "src/json".
            let pattern = "(?<![\\p{L}\\p{N}_./])" + NSRegularExpression.escapedPattern(for: term)
                + "(?![\\p{L}\\p{N}_/])(?!\\.[\\p{L}\\p{N}])"
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    /// Casing fixes: each term with a capital letter replaces whole-word,
    /// case-insensitive occurrences with its exact casing, only if it isn't
    /// an ordinary word (or is marked `!`). “pty” → “PTY”; “node” stays.
    static func fixCasing(_ text: String, _ terms: [Vocabulary.Term],
                          isDictionaryWord: (String) -> Bool = Vocabulary.isDictionaryWord) -> String {
        var result = text
        for term in terms where term.text.contains(where: \.isUppercase) {
            guard term.forced || !isDictionaryWord(term.text) else { continue }
            guard let regex = casingRegex(term.text) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: term.text))
        }
        return result
    }
}

/// Compiled casing patterns, shared across dictations.
nonisolated final class OSAllocatedUnfairLockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var regexes: [String: NSRegularExpression] = [:]
    func value(_ key: String, make: () -> NSRegularExpression?) -> NSRegularExpression? {
        if let hit = lock.withLock({ regexes[key] }) { return hit }
        guard let made = make() else { return nil }
        lock.withLock { regexes[key] = made }
        return made
    }
}
