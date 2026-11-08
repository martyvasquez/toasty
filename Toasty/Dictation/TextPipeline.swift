import Foundation

/// Turning the engine's text into what's inserted (plan §10). Pure and fast;
/// runs on the main actor. (Spoken symbols, fillers, replacements and
/// casing fixes join this in phase D4.)
nonisolated enum TextPipeline {
    // MARK: Composer finishing (plan §10.6; Hex paste.rs:710-816)

    /// `text` as inserted after `before` (the text before the caret): one
    /// leading space where it belongs, a capital at a sentence start, and a
    /// lowercased first word mid-sentence only for small joining words (so
    /// "GitHub" stays). Never a trailing space or newline.
    static func forComposer(_ text: String, before: String) -> String {
        var next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return "" }
        next = setInitialCase(next, uppercase: startsSentence(after: before))
        if let previous = before.last, needsLeadingSpace(previous: previous, text: next) {
            next = " " + next
        }
        return next
    }

    /// After a letter, digit, sentence punctuation or a closing bracket or
    /// quote; never after whitespace, opening punctuation or symbols such as
    /// `@` `$` `/` `-`; never before text starting with whitespace or
    /// closing punctuation.
    static func needsLeadingSpace(previous: Character, text: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isWhitespace || isClosing(first) { return false }
        return previous.isLetter || previous.isNumber || ".,;:!?…)]}”’»".contains(previous)
    }

    /// At the start of the text, or after `. ? !` (closing quotes/brackets
    /// and whitespace ignored).
    static func startsSentence(after before: String) -> Bool {
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let core = trimmed.trimmingTrailing { "'\")]}”’".contains($0) }
        return core.last.map { ".?!".contains($0) } ?? false
    }

    private static func isClosing(_ c: Character) -> Bool { ",.?!;:)]}".contains(c) }

    private static let joiningWords: Set<String> = [
        "a", "an", "and", "as", "because", "but", "for", "if", "nor", "or", "so",
        "the", "then", "though", "to", "when", "while", "yet",
    ]

    static func setInitialCase(_ text: String, uppercase: Bool) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        let c = text[index]
        if uppercase, c.isLowercase {
            return text.replacingCharacters(in: index...index, with: c.uppercased())
        }
        if !uppercase, c.isUppercase {
            let word = text[index...].prefix { $0.isLetter || $0 == "'" }
            if joiningWords.contains(word.lowercased()) {
                return text.replacingCharacters(in: index...index, with: c.lowercased())
            }
        }
        return text
    }
}

nonisolated private extension String {
    func trimmingTrailing(while predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) { end = index(before: end) }
        return self[..<end]
    }
}
