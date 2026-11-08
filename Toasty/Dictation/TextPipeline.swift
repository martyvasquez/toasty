import Foundation

/// Turning the engine's text into what's inserted (plan §10). Pure and fast.
/// Order (Hex dictation/processor.rs:293-417):
/// 1. trim; 2. spoken formatting; 3. spoken symbols; 4. filler words;
/// 5. replacements (project, then global); 6. casing fixes; 7. composer finishing.
nonisolated enum TextPipeline {
    /// Steps 1–6 (finishing needs the text before the caret: `forComposer`).
    static func process(_ raw: String, vocabulary: Vocabulary.Effective) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var text = applyFormatting(trimmed)
        text = applySymbols(text)
        text = removeFillers(text)
        text = applyReplacements(text, vocabulary.replacements)
        text = fixCasing(text, vocabulary.casing)
        return text
    }

    // MARK: Shared helpers

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    /// Whitespace other than a line break.
    private static func isSpace(_ c: Character) -> Bool { c.isWhitespace && c != "\n" }

    private static func trimEnd(_ out: inout [Character], also: Set<Character> = [], floor: Int = 0) {
        while out.count > floor, let last = out.last, isSpace(last) || also.contains(last) { out.removeLast() }
    }

    private static func skip(_ chars: [Character], _ index: Int, also: Set<Character> = []) -> Int {
        var i = index
        while i < chars.count, isSpace(chars[i]) || also.contains(chars[i]) { i += 1 }
        return i
    }

    /// Where the words of `phrase` (separated by at least one space in the
    /// text) start at `start` and end as a whole word; case-insensitive.
    private static func phraseEnd(_ chars: [Character], at start: Int, _ phrase: [String]) -> Int? {
        var position = start
        for (n, word) in phrase.enumerated() {
            if n > 0 {
                let spaces = chars[position...].prefix { $0.isWhitespace }.count
                guard spaces > 0 else { return nil }
                position += spaces
            }
            for expected in word {
                guard position < chars.count, chars[position].lowercased() == String(expected) else { return nil }
                position += 1
            }
        }
        return position == chars.count || !isWordChar(chars[position]) ? position : nil
    }

    private static func wordStart(_ chars: [Character], _ i: Int) -> Bool { i == 0 || !isWordChar(chars[i - 1]) }

    // MARK: 2. Spoken formatting (Hex spoken_formatting.rs, English)

    private enum FormatCommand { case breakLine(String), openQuote, closeQuote }

    private static let formatCommands: [([String], FormatCommand)] = [
        (["new", "paragraph"], .breakLine("\n\n")),
        (["new", "line"], .breakLine("\n")),
        (["line", "break"], .breakLine("\n")),
        (["open", "quote"], .openQuote),
        (["close", "quote"], .closeQuote),
    ]

    /// "new line", "new paragraph", "line break", "open/close quote", and
    /// "quote … unquote" around at least one word.
    static func applyFormatting(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var index = 0
        var pendingUnquote: Int?
        while index < chars.count {
            let start = wordStart(chars, index)
            if pendingUnquote == index {
                pendingUnquote = nil
                index = emitFormat(&out, .closeQuote, chars, index + "unquote".count)
                continue
            }
            if start, let (command, end) = formatCommands.lazy.compactMap({ words, command in
                phraseEnd(chars, at: index, words).map { (command, $0) }
            }).first {
                index = emitFormat(&out, command, chars, end)
                continue
            }
            if start, pendingUnquote == nil, let end = phraseEnd(chars, at: index, ["quote"]),
               let close = unquoteAfter(chars, end) {
                pendingUnquote = close
                index = emitFormat(&out, .openQuote, chars, end)
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    /// The first whole-word "unquote" after `from`, if words come between.
    private static func unquoteAfter(_ chars: [Character], _ from: Int) -> Int? {
        var wordsBetween = false
        for i in from..<chars.count {
            if wordStart(chars, i), phraseEnd(chars, at: i, ["unquote"]) != nil { return wordsBetween ? i : nil }
            if isWordChar(chars[i]) { wordsBetween = true }
        }
        return nil
    }

    private static func emitFormat(_ out: inout [Character], _ command: FormatCommand, _ chars: [Character], _ end: Int) -> Int {
        switch command {
        case .breakLine(let breaks):
            trimEnd(&out, also: [",", ";"])
            out += Array(breaks)
            return skip(chars, end, also: [",", ".", ";", ":"])
        case .openQuote:
            trimEnd(&out)
            if let last = out.last, !"\n([\"".contains(last) { out.append(" ") }
            out.append("\"")
            return skip(chars, end, also: [",", "."])
        case .closeQuote:
            trimEnd(&out, also: [","])
            out.append("\"")
            let next = skip(chars, end)
            if next < chars.count, isWordChar(chars[next]) { out.append(" ") }
            return next
        }
    }

    // MARK: 3. Spoken symbols (Hex spoken_symbols.rs + Toasty additions)

    enum Join {
        /// Attaches to the next word: "#release".
        case next
        /// No space either side: "my_variable".
        case both
        /// Attaches to the previous word, one space after: "done, thanks".
        case previous
        /// A space either side: "a = b".
        case spaced
        /// An opening bracket: spaced before, attached after, except an empty
        /// pair attaches to the word before: "foo()" but "note (see docs)".
        case open
        /// A closing bracket: attached before; one space after before a word.
        case close
    }

    static let symbols: [([String], String, Join)] = [
        // Hex
        (["hashtag"], "#", .next),
        (["hash", "sign"], "#", .next),
        (["at", "sign"], "@", .next),
        (["underscore"], "_", .both),
        (["hyphen"], "-", .both),
        (["slash"], "/", .both),
        (["comma"], ",", .previous),
        (["semicolon"], ";", .previous),
        (["colon"], ":", .previous),
        // Toasty (plan §10.2): exact phrases only.
        (["dot"], ".", .both),
        (["backslash"], "\\", .both),
        (["dash", "dash"], "--", .next),
        (["tilde"], "~", .next),
        (["equals", "sign"], "=", .spaced),
        (["pipe", "symbol"], "|", .spaced),
        (["pipe", "sign"], "|", .spaced),
        (["open", "paren"], "(", .open),
        (["close", "paren"], ")", .close),
        (["open", "bracket"], "[", .open),
        (["close", "bracket"], "]", .close),
        (["open", "brace"], "{", .open),
        (["close", "brace"], "}", .close),
    ]

    static func applySymbols(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        // Where the last symbol written ends: trimming never goes below it.
        var floor = 0
        var index = 0
        while index < chars.count {
            if wordStart(chars, index), let (symbol, join, end) = symbolAt(chars, index) {
                index = emitSymbol(&out, &floor, symbol, join, chars, end)
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    private static func symbolAt(_ chars: [Character], _ start: Int) -> (String, Join, Int)? {
        for (words, symbol, join) in symbols {
            if let end = phraseEnd(chars, at: start, words) { return (symbol, join, end) }
        }
        return nil
    }

    private static func emitSymbol(_ out: inout [Character], _ floor: inout Int, _ symbol: String, _ join: Join,
                                   _ chars: [Character], _ end: Int) -> Int {
        let next = skip(chars, end, also: [",", "."])
        switch join {
        case .next:
            break
        case .both, .previous, .close:
            trimEnd(&out, also: [","], floor: floor)
        case .spaced:
            trimEnd(&out, also: [","], floor: floor)
            if let last = out.last, !last.isWhitespace { out.append(" ") }
        case .open:
            // An empty pair ("open paren close paren") is a call: attach.
            let closesRightAway = symbolAt(chars, next).map { $0.1 == .close } ?? false
            if closesRightAway {
                trimEnd(&out, also: [","], floor: floor)
            } else {
                trimEnd(&out, floor: floor)
                if let last = out.last, !last.isWhitespace, !"([{".contains(last) { out.append(" ") }
            }
        }
        // The model sometimes writes the symbol and then its word too
        // ("source/slash model"): don't double a character it wrote itself
        // (beyond `floor`; spoken repeats like "underscore underscore" stay).
        if join == .both, out.count > floor, String(out.suffix(symbol.count)) == symbol {
            floor = out.count
            return next
        }
        out += Array(symbol)
        floor = out.count
        let followedBy = next < chars.count ? chars[next] : nil
        switch join {
        case .previous:
            if let c = followedBy, !"\n,.;:!?)]\"".contains(c) { out.append(" ") }
        case .spaced:
            if followedBy != nil { out.append(" ") }
        case .close:
            if let c = followedBy, isWordChar(c), symbolAt(chars, next) == nil { out.append(" ") }
        default:
            break
        }
        return next
    }

    // MARK: 4. Filler words (Hex filler_words.rs, English)

    private static let fillers = ["um", "umm", "uh", "uhh", "erm", "er", "ah"]

    private static func joinsWord(_ c: Character) -> Bool { isWordChar(c) || "-'’".contains(c) }

    static func removeFillers(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var removed = false
        var capitalize = false
        var index = 0
        while index < chars.count {
            if let end = fillerAt(chars, index) {
                trimEnd(&out)
                if !removed { capitalize = chars[index].isUppercase && sentenceStart(out) }
                index = afterFiller(chars, end)
                removed = true
                continue
            }
            let c = chars[index]
            index += 1
            if removed {
                if isSpace(c) { continue }
                if c == "\n" {
                    removed = false
                    capitalize = false
                    out.append(c)
                    continue
                }
                if ".!?,".contains(c), sentenceStart(out) { continue }
                removed = false
                let closing = ".,;:!?)]}”’…".contains(c)
                    || (c == "\"" && (index >= chars.count || !isWordChar(chars[index])))
                if closing {
                    trimEnd(&out, also: [","])
                    capitalize = false
                } else {
                    if needsSpace(out) { out.append(" ") }
                    if capitalize {
                        capitalize = false
                        out += Array(String(c).uppercased())
                        continue
                    }
                }
            }
            out.append(c)
        }
        if removed { trimEnd(&out, also: [","]) }
        return String(out)
    }

    /// A filler as a whole word: lowercase, or with only its first letter capitalized.
    private static func fillerAt(_ chars: [Character], _ start: Int) -> Int? {
        if start > 0, joinsWord(chars[start - 1]) { return nil }
        for word in fillers {
            let end = start + word.count
            guard end <= chars.count else { continue }
            let matches = zip(chars[start..<end], word).enumerated().allSatisfy { n, pair in
                pair.0 == pair.1 || (n == 0 && String(pair.0) == String(pair.1).uppercased())
            }
            if matches, end == chars.count || !joinsWord(chars[end]) { return end }
        }
        return nil
    }

    /// Past the filler's own comma or ellipsis.
    private static func afterFiller(_ chars: [Character], _ end: Int) -> Int {
        var i = skip(chars, end)
        if i < chars.count {
            if chars[i] == "," || chars[i] == "…" {
                i += 1
            } else if chars[i] == ".", i + 2 < chars.count, chars[i + 1] == ".", chars[i + 2] == "." {
                i += 3
            }
        }
        return skip(chars, i)
    }

    private static func sentenceStart(_ out: [Character]) -> Bool {
        guard let last = out.last else { return true }
        return ".!?\n".contains(last)
    }

    private static func needsSpace(_ out: [Character]) -> Bool {
        guard let last = out.last else { return false }
        if "\n([{“‘".contains(last) { return false }
        if last == "\"" { return out.count >= 2 && !out[out.count - 2].isWhitespace }
        return true
    }

    // MARK: 5. Replacements (Hex text_replacements.rs selection and tidy-up; Portal's matcher)

    /// Whole phrases, case-insensitive; a phrase's words may be run together
    /// or hyphenated ("cloud code" matches "CloudCode", "cloud-code"); `_`
    /// is part of a word. All matches of all rules compete: longest first,
    /// then leftmost, then rule order; non-overlapping ones win. Single pass:
    /// output is never matched again. An empty replacement deletes the phrase
    /// and tidies the spacing and punctuation around it.
    static func applyReplacements(_ input: String, _ rules: [Vocabulary.Replacement]) -> String {
        let text = input.precomposedStringWithCanonicalMapping
        let ns = text as NSString
        struct Candidate { var start: Int; var end: Int; var rule: Int }
        var candidates: [Candidate] = []
        for (n, rule) in rules.enumerated() {
            let parts = rule.from.precomposedStringWithCanonicalMapping
                .split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
            guard !parts.isEmpty,
                  let regex = try? NSRegularExpression(pattern: parts.map(NSRegularExpression.escapedPattern(for:))
                      .joined(separator: "[\\s\\-]*"), options: [.caseInsensitive]) else { continue }
            var from = 0
            while from < ns.length, let m = regex.firstMatch(in: text, range: NSRange(location: from, length: ns.length - from)) {
                if boundary(ns, m.range.location, m.range.location + m.range.length) {
                    candidates.append(Candidate(start: m.range.location, end: m.range.location + m.range.length, rule: n))
                    from = m.range.location + max(m.range.length, 1)
                } else {
                    from = m.range.location + ns.rangeOfComposedCharacterSequence(at: m.range.location).length
                }
            }
        }
        candidates.sort {
            let (l, r) = ($0.end - $0.start, $1.end - $1.start)
            if l != r { return l > r }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.rule < $1.rule
        }
        var selected: [Candidate] = []
        for c in candidates where !selected.contains(where: { c.start < $0.end && $0.start < c.end }) {
            selected.append(c)
        }
        guard !selected.isEmpty else { return text }
        selected.sort { $0.start < $1.start }

        func sub(_ a: Int, _ b: Int) -> String { ns.substring(with: NSRange(location: a, length: b - a)) }
        let horizontal: Set<Character> = [" ", "\t"]
        let clause: Set<Character> = [".", "!", "?", ",", ";", ":"]
        func dropLeading(_ s: Substring, _ set: Set<Character>) -> Substring { s.drop { set.contains($0) } }

        var output = ""
        var cursor = 0
        var capitalizeNext = false
        for (i, c) in selected.enumerated() {
            if cursor < c.start { pushSegment(&output, sub(cursor, c.start), &capitalizeNext) }
            let replacement = rules[c.rule].to
            if !replacement.isEmpty {
                pushSegment(&output, replacement, &capitalizeNext)
                cursor = c.end
                continue
            }
            let nextLimit = i + 1 < selected.count ? selected[i + 1].start : ns.length
            let between = sub(c.end, nextLimit)
            if atSentenceStart(output) {
                if sub(c.start, c.end).first(where: \.isLetter)?.isUppercase == true { capitalizeNext = true }
                let afterSpaces = dropLeading(dropLeading(between[...], clause), horizontal)
                cursor = c.end + (between.utf16.count - afterSpaces.utf16.count)
                if (afterSpaces.isEmpty && nextLimit == ns.length) || afterSpaces.hasPrefix("\n") {
                    trimTrailingHorizontal(&output)
                }
            } else {
                let remaining = dropLeading(sub(c.end, ns.length)[...], horizontal)
                if between.first.map({ clause.contains($0) }) == true || remaining.isEmpty || remaining.hasPrefix("\n") {
                    trimTrailingHorizontal(&output)
                    if output.hasSuffix(",") { output.removeLast() }
                    if remaining.isEmpty || remaining.hasPrefix("\n") {
                        let afterSpaces = dropLeading(between[...], horizontal)
                        cursor = c.end + (between.utf16.count - afterSpaces.utf16.count)
                    } else {
                        cursor = c.end
                    }
                } else if output.last.map({ horizontal.contains($0) }) == true {
                    let afterSpaces = dropLeading(between[...], horizontal)
                    cursor = c.end + (between.utf16.count - afterSpaces.utf16.count)
                } else {
                    cursor = c.end
                }
            }
        }
        if cursor < ns.length { pushSegment(&output, sub(cursor, ns.length), &capitalizeNext) }
        return output
    }

    private static func atSentenceStart(_ output: String) -> Bool {
        let trimmed = output.reversed().drop { $0 == " " || $0 == "\t" }
        guard let last = trimmed.first else { return true }
        return ".!?\n".contains(last)
    }

    private static func trimTrailingHorizontal(_ output: inout String) {
        while let last = output.last, last == " " || last == "\t" { output.removeLast() }
    }

    private static func pushSegment(_ output: inout String, _ segment: String, _ capitalizeNext: inout Bool) {
        guard capitalizeNext, !segment.isEmpty else {
            output += segment
            if segment.contains(where: { !$0.isWhitespace }) { capitalizeNext = false }
            return
        }
        guard let index = segment.firstIndex(where: { !$0.isWhitespace }) else { output += segment; return }
        output += segment[..<index]
        let c = segment[index]
        output += c.isLowercase && atSentenceStart(output) ? c.uppercased() : String(c)
        output += segment[segment.index(after: index)...]
        capitalizeNext = false
    }

    /// A phrase stands alone: no word character (letter, digit, `_`) touches
    /// it, except characters of scripts written without spaces.
    private static func boundary(_ ns: NSString, _ start: Int, _ end: Int) -> Bool {
        func wordChar(_ s: String) -> Bool {
            guard let c = s.first else { return false }
            if c.unicodeScalars.contains(where: { unspacedScript($0) }) { return false }
            return c.isLetter || c.isNumber || c == "_"
        }
        let before = start > 0 ? ns.substring(with: ns.rangeOfComposedCharacterSequence(at: start - 1)) : ""
        let after = end < ns.length ? ns.substring(with: ns.rangeOfComposedCharacterSequence(at: end)) : ""
        return !wordChar(before) && !wordChar(after)
    }

    private static func unspacedScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x309F, 0x30A0...0x30FF, 0xAC00...0xD7AF,
             0x1100...0x11FF, 0x0E00...0x0E7F, 0x0E80...0x0EFF, 0x1780...0x17FF, 0x1000...0x109F, 0x0F00...0x0FFF:
            true
        default:
            false
        }
    }

    // MARK: 7. Composer finishing (plan §10.6; Hex paste.rs:710-816)

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
        if first.isWhitespace || ",.?!;:)]}".contains(first) { return false }
        return previous.isLetter || previous.isNumber || ".,;:!?…)]}”’»".contains(previous)
    }

    /// At the start of the text, or after `. ? !` (closing quotes/brackets
    /// and whitespace ignored).
    static func startsSentence(after before: String) -> Bool {
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let core = trimmed.reversed().drop { "'\")]}”’".contains($0) }
        return core.first.map { ".?!".contains($0) } ?? false
    }

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
