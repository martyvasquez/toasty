import AppKit

/// mostty: Turns Claude's Markdown into native attributed text.
///
/// Block structure (headings, paragraphs, lists, quotes, tables, fences) is
/// parsed here; inline formatting (bold, italic, code, links) is parsed by
/// Foundation's Markdown support. Consecutive prose blocks become one
/// attributed string so a selection can run across them; code blocks and
/// rules are separate so they can get their own chrome (copy button, etc.).
enum ClaudeMarkdown {
    enum Block: Equatable {
        case text(NSAttributedString)
        case code(language: String, code: String)
        case table(NSAttributedString)
        case rule
    }

    struct Style {
        var baseSize: CGFloat = ClaudeStyle.bodySize
        var codeSize: CGFloat = ClaudeStyle.codeSize
        /// Directory that relative file references are resolved against.
        var cwd: String?

        var body: NSFont { .systemFont(ofSize: baseSize) }
        var mono: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }
    }

    // MARK: Parsing

    private enum RawBlock {
        case heading(Int, String)
        case paragraph(String)
        case list(ordered: Bool, start: Int, items: [(indent: Int, text: String, task: Bool?, number: Int)])
        case quote([String])
        case table([[String]])
        case code(String, String)
        case rule
    }

    static func blocks(_ markdown: String, style: Style = .init()) -> [Block] {
        let raw = parse(markdown)
        var out: [Block] = []
        var pending = NSMutableAttributedString()
        var afterHeading = false

        func flush() {
            guard pending.length > 0 else { return }
            // Drop the trailing paragraph break.
            if pending.string.hasSuffix("\n") {
                pending.deleteCharacters(in: NSRange(location: pending.length - 1, length: 1))
            }
            out.append(.text(pending))
            pending = NSMutableAttributedString()
        }

        for block in raw {
            switch block {
            case .code(let lang, let code):
                flush()
                out.append(.code(language: lang, code: code))
                afterHeading = false
            case .rule:
                flush()
                out.append(.rule)
                afterHeading = false
            case .table(let rows):
                flush()
                out.append(.table(table(rows, style: style)))
                afterHeading = false
            default:
                // Space above: none at the top of a block, a full line between
                // paragraphs, less right under a heading (it belongs to it).
                let gap: CGFloat = pending.length == 0 ? 0
                    : afterHeading ? (ClaudeTypography.paragraphGap * 0.4).rounded()
                    : ClaudeTypography.paragraphGap
                pending.append(render(block, style: style, gap: gap))
                if case .heading = block { afterHeading = true } else { afterHeading = false }
            }
        }
        flush()
        return out
    }

    private static func parse(_ markdown: String) -> [RawBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [RawBlock] = []
        var i = 0
        var paragraph: [String] = []

        func endParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if let fence = fenceMarker(trimmed) {
                endParagraph()
                let lang = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix(fence),
                       l.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first }) {
                        break
                    }
                    // Remove the fence's own indentation (fences inside lists).
                    var stripped = Substring(l)
                    var n = indent
                    while n > 0, stripped.first == " " { stripped = stripped.dropFirst(); n -= 1 }
                    code.append(String(stripped))
                    i += 1
                }
                i += 1
                blocks.append(.code(lang.split(separator: " ").first.map(String.init) ?? "", code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                endParagraph()
                i += 1
                continue
            }

            // Heading
            if let h = heading(trimmed) {
                endParagraph()
                blocks.append(.heading(h.0, h.1))
                i += 1
                continue
            }

            // Horizontal rule
            if isRule(trimmed) {
                endParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Table: a row of pipes followed by a separator row.
            if trimmed.hasPrefix("|") || (trimmed.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1])),
               i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                endParagraph()
                var rows: [[String]] = [tableCells(trimmed)]
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(tableCells(t))
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                endParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quote.append(String(rest))
                    i += 1
                }
                blocks.append(.quote(quote))
                continue
            }

            // List
            if let first = listItem(line) {
                endParagraph()
                var items: [(indent: Int, text: String, task: Bool?, number: Int)] = []
                let ordered = first.ordered
                while i < lines.count {
                    let l = lines[i]
                    if let item = listItem(l) {
                        items.append((item.indent, item.text, item.task, item.number))
                        i += 1
                    } else if !l.trimmingCharacters(in: .whitespaces).isEmpty,
                              l.hasPrefix("  ") || l.hasPrefix("\t"),
                              fenceMarker(l.trimmingCharacters(in: .whitespaces)) == nil,
                              !items.isEmpty {
                        // Continuation of the previous item.
                        items[items.count - 1].text += " " + l.trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else if l.trimmingCharacters(in: .whitespaces).isEmpty,
                              i + 1 < lines.count, listItem(lines[i + 1]) != nil {
                        // Loose list: blank line between items.
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, start: first.number, items: items))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        endParagraph()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for f in ["````", "```", "~~~"] where trimmed.hasPrefix(f) { return f }
        return nil
    }

    private static func heading(_ t: String) -> (Int, String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = t.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func tableCells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        // Split on pipes not escaped and not inside inline code.
        var cells: [String] = []
        var current = ""
        var inCode = false
        var prev: Character = " "
        for ch in t {
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode && prev != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            prev = ch
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int, indent: Int, text: String, task: Bool?)? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let t = expanded.dropFirst(indent)
        var ordered = false
        var number = 1
        var rest: Substring
        if let c = t.first, "-*+".contains(c), t.dropFirst().first == " " {
            rest = t.dropFirst(2)
        } else {
            let digits = t.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 10 else { return nil }
            let after = t.dropFirst(digits.count)
            guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            rest = after.dropFirst(2)
        }
        var task: Bool?
        if rest.hasPrefix("[ ] ") { task = false; rest = rest.dropFirst(4) }
        else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { task = true; rest = rest.dropFirst(4) }
        return (ordered, number, indent / 2, String(rest), task)
    }

    // MARK: Rendering

    private typealias T = ClaudeTypography

    /// Body attributes for a paragraph: fixed line height, half-leading.
    private static func finish(_ s: NSMutableAttributedString, font: NSFont, multiple: CGFloat = T.lineHeightMultiple,
                               paragraph: NSParagraphStyle) {
        let all = NSRange(location: 0, length: s.length)
        s.addAttribute(.paragraphStyle, value: paragraph, range: all)
        // One baseline offset for the whole line, so inline code (a smaller
        // font) shares the text's baseline.
        s.addAttribute(.baselineOffset, value: T.baselineOffset(font, multiple), range: all)
    }

    /// Line breaks inside a paragraph (Markdown's two-space breaks, or
    /// Claude's one-item-per-line text) are line separators: same paragraph,
    /// no paragraph gap.
    private static func lineBreaks(_ s: NSMutableAttributedString) -> NSMutableAttributedString {
        let text = s.mutableString
        text.replaceOccurrences(of: "  \n", with: "\n", options: [], range: NSRange(location: 0, length: text.length))
        text.replaceOccurrences(of: "\\\n", with: "\n", options: [], range: NSRange(location: 0, length: text.length))
        text.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: 0, length: text.length))
        return s
    }

    private static func newline(_ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: font])
    }

    private static func render(_ block: RawBlock, style: Style, gap: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()

        switch block {
        case .heading(let level, let text):
            let font = T.heading(level)
            let s = inline(text, font: font, style: style)
            let before = gap == 0 ? 0 : gap + (font.pointSize * T.headingSpacingBefore).rounded()
            finish(s, font: font, multiple: T.headingLineHeightMultiple,
                   paragraph: T.paragraphStyle(font: font, multiple: T.headingLineHeightMultiple, spacingBefore: before))
            out.append(s)
            out.append(newline(font))

        case .paragraph(let text):
            let s = lineBreaks(inline(text, font: T.body, style: style))
            finish(s, font: T.body, paragraph: T.paragraphStyle(spacingBefore: gap))
            out.append(s)
            out.append(newline(T.body))

        case .list(let ordered, let start, let items):
            var counters: [Int: Int] = [:]
            let font = T.body
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            // A numbered list's text edge leaves room for its widest number
            // (so "10." never touches its text), and all its items share it.
            var textOffset = T.listTextOffset
            if ordered {
                let widest = items.map { ("\($0.number)." as NSString).size(withAttributes: [.font: numberFont]).width }.max() ?? 0
                textOffset = max(textOffset, (widest + T.listNumberGap + 2).rounded())
            }
            for (n, item) in items.enumerated() {
                let level = min(item.indent, 6)
                // Deeper levels restart their numbering.
                counters = counters.filter { $0.key <= level }
                let levelX = CGFloat(level) * max(T.listLevelStep, textOffset)
                let textX = levelX + textOffset
                let spacing: CGFloat = n == 0 ? gap : 3
                let line = NSMutableAttributedString()
                let paragraph: NSMutableParagraphStyle

                if let task = item.task {
                    // A placeholder the layout manager draws as a checkbox.
                    let used = ("•" as NSString).size(withAttributes: [.font: font]).width
                    line.append(NSAttributedString(string: "•", attributes: [
                        .font: font, .foregroundColor: NSColor.clear,
                        .claudeTask: task, .kern: textOffset - used]))
                    paragraph = T.paragraphStyle(headIndent: textX, firstLineIndent: levelX, spacingBefore: spacing)
                } else if ordered {
                    // The number as written (Claude numbers its own lists;
                    // a list that starts at 9 stays at 9).
                    let k = item.number
                    counters[level] = k + 1
                    let number = "\(k)."
                    let width = (number as NSString).size(withAttributes: [.font: numberFont]).width
                    // Numbers are right-aligned to the text edge.
                    line.append(NSAttributedString(string: number + "\t", attributes: [
                        .font: numberFont, .foregroundColor: T.accent]))
                    paragraph = T.paragraphStyle(headIndent: textX,
                                                 firstLineIndent: max(levelX, textX - T.listNumberGap - width),
                                                 spacingBefore: spacing)
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: textX)]
                } else {
                    // A placeholder the layout manager draws as a shape; its
                    // kern carries the text to the list's text edge.
                    let used = ("•" as NSString).size(withAttributes: [.font: font]).width
                    line.append(NSAttributedString(string: "•", attributes: [
                        .font: font, .foregroundColor: NSColor.clear,
                        .claudeBullet: level, .kern: textOffset - used]))
                    paragraph = T.paragraphStyle(headIndent: textX, firstLineIndent: levelX, spacingBefore: spacing)
                }
                line.append(inline(item.text, font: font, style: style))
                finish(line, font: font, paragraph: paragraph)
                out.append(line)
                out.append(newline(font))
            }

        case .quote(let lines):
            // Quotes are prose with an accent bar per level ("> >" nests).
            var paragraphs: [(depth: Int, text: [String])] = []
            var lastBlank = true
            for line in lines {
                var depth = 1
                var rest = Substring(line)
                while rest.first == ">" {
                    depth += 1
                    rest = rest.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                }
                let text = rest.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { lastBlank = true; continue }
                if lastBlank || paragraphs.last?.depth != depth {
                    paragraphs.append((depth, [text]))
                } else {
                    paragraphs[paragraphs.count - 1].text.append(text)
                }
                lastBlank = false
            }
            for (i, p) in paragraphs.enumerated() {
                let s = lineBreaks(inline(p.text.joined(separator: "\n"), font: T.body, style: style))
                s.addAttribute(.foregroundColor, value: T.secondaryText, range: NSRange(location: 0, length: s.length))
                let indent = CGFloat(p.depth) * T.quoteIndent
                let spacing = i == 0 ? gap : (T.paragraphGap * 0.5).rounded()
                finish(s, font: T.body, paragraph: T.paragraphStyle(headIndent: indent, spacingBefore: spacing))
                // The paragraph break belongs to the quote too, so a quote's
                // paragraphs share one continuous bar.
                s.append(newline(T.body))
                s.addAttribute(.claudeQuote, value: p.depth, range: NSRange(location: 0, length: s.length))
                out.append(s)
            }

        case .table, .code, .rule:
            break
        }
        return out
    }

    /// A Bear-style table: header shading, alternate rows, inner grid lines
    /// (the outline is drawn rounded by the view around it).
    private static func table(_ rows: [[String]], style: Style) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return out }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        let font = NSFont.systemFont(ofSize: T.bodySize - 0.5)
        let headerFont = T.adding(bold: true, italic: false, to: font)

        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(T.tableCellPadding, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(T.tableCellPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(T.tableRowPadding, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(T.tableRowPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
                // Inner grid only.
                cell.setWidth(c > 0 ? 1 : 0, type: .absoluteValueType, for: .border, edge: .minX)
                cell.setWidth(r > 0 ? 1 : 0, type: .absoluteValueType, for: .border, edge: .minY)
                cell.setBorderColor(T.tableBorder)
                if r == 0 {
                    cell.backgroundColor = T.tableHeader
                } else if r % 2 == 0 {
                    cell.backgroundColor = T.tableAlternateRow
                }
                let f = r == 0 ? headerFont : font
                let text = c < row.count ? row[c] : ""
                let s = inline(text.isEmpty ? " " : text, font: f, style: style)
                s.append(NSAttributedString(string: "\n", attributes: [.font: f]))
                let p = T.paragraphStyle(font: f, multiple: 1.35)
                p.textBlocks = [cell]
                finish(s, font: f, multiple: 1.35, paragraph: p)
                out.append(s)
            }
        }
        if out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    // MARK: Inline

    /// Inline Markdown (bold, italic, code, links, strikethrough) on the
    /// given font, in the reply's text color. Bare URLs and file references
    /// become links.
    static func inline(_ text: String, font: NSFont, style: Style) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let out = NSMutableAttributedString()

        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: T.text]
            var f = intent.contains(.code) ? T.code(matching: font) : font
            f = T.adding(bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized), to: f)
            attrs[.font] = f
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.foregroundColor] = T.secondaryText
            }
            if intent.contains(.code) { attrs[.claudeInlineCode] = true }
            if let link = run.link {
                attrs[.link] = link
            } else if intent.contains(.code), let file = ClaudeFileLinks.url(for: piece, cwd: style.cwd) {
                attrs[.link] = file
            }

            let isCode = intent.contains(.code)
            // Room for the code background's padding, without adding
            // characters (copying stays exact).
            if isCode, out.length > 0 {
                out.addAttribute(.kern, value: 3, range: NSRange(location: out.length - 1, length: 1))
            }
            let span = NSMutableAttributedString(string: piece, attributes: attrs)
            if isCode, span.length > 0 {
                span.addAttribute(.kern, value: 3, range: NSRange(location: span.length - 1, length: 1))
            }
            out.append(span)
        }
        ClaudeFileLinks.linkify(out, cwd: style.cwd)
        return out
    }
}

// MARK: - Links to URLs and files

enum ClaudeFileLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Paths like `src/foo.swift`, `./a/b.ts:12`, `/abs/path.md:3:4`.
    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?<![\w/.~-])((?:~|\.{1,2})?/?(?:[\w.@+-]+/)*[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,10})(?::(\d+))?(?::\d+)?(?![\w/])"#)

    /// Adds links for bare URLs and existing file paths not already linked.
    static func linkify(_ s: NSMutableAttributedString, cwd: String?) {
        let full = NSRange(location: 0, length: s.length)
        let text = s.string
        var ranges: [(NSRange, URL)] = []

        detector?.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
            guard let m, let url = m.url, url.scheme == "http" || url.scheme == "https" else { return }
            ranges.append((m.range, url))
        }
        pathRegex?.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
            guard let m else { return }
            let r = m.range
            guard !ranges.contains(where: { NSIntersectionRange($0.0, r).length > 0 }),
                  let url = url(for: (text as NSString).substring(with: r), cwd: cwd) else { return }
            ranges.append((r, url))
        }
        for (range, url) in ranges where s.attribute(.link, at: range.location, effectiveRange: nil) == nil {
            s.addAttribute(.link, value: url, range: range)
        }
    }

    /// A `file://` URL (with an optional `#L<line>` fragment) for a reference
    /// to a file that exists, resolved against `cwd`.
    static func url(for reference: String, cwd: String?) -> URL? {
        var ref = reference.trimmingCharacters(in: CharacterSet(charactersIn: " `'\"()[],"))
        guard !ref.isEmpty, ref.count < 400, !ref.contains("://"), !ref.contains(" ") else { return nil }
        var line: Int?
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let n = Int(parts[1]) {
            line = n
            ref = String(parts[0])
        }
        let expanded = (ref as NSString).expandingTildeInPath
        let path: String
        if expanded.hasPrefix("/") {
            path = expanded
        } else if let cwd {
            path = (cwd as NSString).appendingPathComponent(expanded)
        } else {
            return nil
        }
        guard isFile(path) else { return nil }
        var url = URL(fileURLWithPath: path)
        if let line, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = "L\(line)"
            url = c.url ?? url
        }
        return url
    }

    /// Existence checks, cached briefly: text is re-rendered while it streams.
    private static var fileCache: [String: (Bool, Date)] = [:]
    private static let cacheLock = NSLock()

    private static func isFile(_ path: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let (exists, date) = fileCache[path], Date().timeIntervalSince(date) < 10 { return exists }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
        if fileCache.count > 2000 { fileCache.removeAll() }
        fileCache[path] = (exists, Date())
        return exists
    }

    /// Open a link from Claude's output: web links in the browser, files in
    /// their default app (or reveal folders in Finder).
    @MainActor
    static func open(_ url: URL) {
        if url.isFileURL {
            var plain = URLComponents(url: url, resolvingAgainstBaseURL: false)
            plain?.fragment = nil
            NSWorkspace.shared.open(plain?.url ?? url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Syntax highlighting

/// A small, dependency-free highlighter: comments, strings, numbers and
/// keywords for common languages. Good enough to make code readable; not a
/// full grammar.
enum ClaudeSyntax {
    private static let keywords: Set<String> = [
        // C-family / Swift / JS / TS / Go / Rust / Java / Kotlin
        "let", "var", "const", "func", "function", "fn", "def", "class", "struct", "enum", "interface",
        "protocol", "extension", "impl", "trait", "type", "typealias", "import", "export", "from", "package",
        "return", "if", "else", "elif", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "in", "of", "as", "is", "new", "delete", "try", "catch", "finally", "throw", "throws",
        "async", "await", "yield", "static", "public", "private", "protected", "internal", "fileprivate",
        "final", "override", "mutating", "guard", "defer", "where", "self", "Self", "super", "this",
        "true", "false", "nil", "null", "undefined", "None", "True", "False", "void", "int", "bool",
        "string", "pub", "mod", "use", "crate", "match", "loop", "mut", "ref", "go", "chan", "select",
        "with", "lambda", "pass", "raise", "except", "not", "and", "or", "extends", "implements",
        "abstract", "readonly", "keyof", "typeof", "instanceof", "lazy", "weak", "unowned", "init",
        "deinit", "some", "any", "inout", "where", "module", "require", "end", "then", "fi", "esac",
        "done", "echo", "local", "export", "source", "unless", "until", "begin", "rescue", "ensure",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN", "ON",
        "AND", "OR", "NOT", "NULL", "INTO", "VALUES", "SET", "ORDER", "BY", "GROUP", "LIMIT", "AS",
    ]

    private static let hashCommentLangs: Set<String> = [
        "sh", "bash", "zsh", "fish", "shell", "console", "python", "py", "ruby", "rb", "yaml", "yml",
        "toml", "make", "makefile", "dockerfile", "perl", "r", "nix", "conf", "ini", "env", "elixir",
    ]

    private static let tokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)"#)

    static func highlight(_ code: String, language: String, font: NSFont) -> NSAttributedString {
        let multiple = ClaudeTypography.codeLineHeightMultiple
        let s = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: ClaudeTypography.text,
            .paragraphStyle: ClaudeTypography.paragraphStyle(font: font, multiple: multiple),
            .baselineOffset: ClaudeTypography.baselineOffset(font, multiple),
        ])
        let lang = language.lowercased()
        guard lang != "text", lang != "plaintext", lang != "txt", code.utf16.count < 60_000 else { return s }
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)

        let string = ClaudeTypography.syntaxString
        let number = ClaudeTypography.syntaxNumber
        let keyword = ClaudeTypography.syntaxKeyword
        let type = ClaudeTypography.syntaxType
        let comment = ClaudeTypography.syntaxComment

        if lang == "diff" || lang == "patch" {
            ns.enumerateSubstrings(in: full, options: .byLines) { line, range, _, _ in
                guard let line else { return }
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    s.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: range)
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    s.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
                } else if line.hasPrefix("@@") {
                    s.addAttribute(.foregroundColor, value: comment, range: range)
                }
            }
            return s
        }

        tokenRegex?.enumerateMatches(in: code, options: [], range: full) { m, _, _ in
            guard let m else { return }
            if m.range(at: 1).location != NSNotFound {
                s.addAttribute(.foregroundColor, value: string, range: m.range(at: 1))
            } else if m.range(at: 2).location != NSNotFound {
                s.addAttribute(.foregroundColor, value: number, range: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                let word = ns.substring(with: m.range(at: 3))
                if keywords.contains(word) {
                    s.addAttribute(.foregroundColor, value: keyword, range: m.range(at: 3))
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
                          word.count > 1, word != word.uppercased() {
                    // CapitalizedNames are types in most languages.
                    s.addAttribute(.foregroundColor, value: type, range: m.range(at: 3))
                }
            }
        }

        // Comments last so they win over anything inside them.
        let hash = hashCommentLangs.contains(lang)
        let linePattern = hash ? #"(?m)(^|\s)#.*$"# : #"//.*$"#
        for pattern in [linePattern, #"/\*[\s\S]*?\*/"#, #"<!--[\s\S]*?-->"#] {
            if hash && pattern.hasPrefix("/\\*") { continue }
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            re.enumerateMatches(in: code, options: [], range: full) { m, _, _ in
                guard let m else { return }
                // Don't treat "://" in URLs as a comment.
                if pattern == #"//.*$"#, m.range.location > 0,
                   ns.substring(with: NSRange(location: m.range.location - 1, length: 1)) == ":" { return }
                s.addAttribute(.foregroundColor, value: comment, range: m.range)
            }
        }
        return s
    }
}
