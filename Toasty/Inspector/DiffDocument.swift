import AppKit
import SwiftUI

/// The full-page diff of one changed file: a single scrolling text view
/// (so a long diff stays fast and code can be selected and copied across
/// lines) with the old and new line numbers in a gutter, each changed line
/// tinted the full width, syntax colors, and the changed words inside a
/// changed line marked more strongly. The gutter and the tints are drawn
/// by the layout manager, not typed into the text, so a copy is only code.

// MARK: - Lines

nonisolated struct DiffLine: Sendable, Equatable {
    enum Kind: Sendable { case context, added, removed, hunk, note }
    let kind: Kind
    /// The line's text; for a hunk, the function or section it's in.
    let text: String
    let old: Int?
    let new: Int?
}

extension GitChanges {
    /// The file's diff against the last commit, parsed into lines with
    /// their numbers.
    nonisolated static func diffLines(_ file: File) -> [DiffLine] {
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
        return parseDiff(result.text)
    }

    nonisolated static func parseDiff(_ text: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var inHunk = false
        var old = 0, new = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                // "@@ -12,6 +12,8 @@ func name()": the starts, and the context.
                let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                let context = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
                    .map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                lines.append(DiffLine(kind: .hunk, text: context, old: nil, new: nil))
            } else if inHunk, let first = line.first, "+- ".contains(first) {
                let body = String(line.dropFirst())
                switch first {
                case "+":
                    lines.append(DiffLine(kind: .added, text: body, old: nil, new: new)); new += 1
                case "-":
                    lines.append(DiffLine(kind: .removed, text: body, old: old, new: nil)); old += 1
                default:
                    lines.append(DiffLine(kind: .context, text: body, old: old, new: new)); old += 1; new += 1
                }
            } else if line.hasPrefix("Binary files") {
                lines.append(DiffLine(kind: .note, text: "Binary file", old: nil, new: nil))
            } else if line.hasPrefix("diff --git") {
                inHunk = false
            }
        }
        while let last = lines.last, last.kind == .context, last.text.isEmpty { lines.removeLast() }
        // The first hunk's separator says nothing the numbers don't.
        if lines.first?.kind == .hunk { lines.removeFirst() }
        return lines
    }
}

// MARK: - Text

extension NSAttributedString.Key {
    /// A diff line's kind and numbers, on the whole line (newline included).
    nonisolated static let diffLine = NSAttributedString.Key("toasty.diffLine")
}

nonisolated final class DiffLineInfo: NSObject {
    let kind: DiffLine.Kind
    let old: Int?
    let new: Int?

    init(_ line: DiffLine) {
        kind = line.kind
        old = line.old
        new = line.new
    }
}

/// Colors and measures of the diff page.
enum DiffStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: ClaudeTypography.codeSize, weight: .regular)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: Theme.Size.caption, weight: .regular)
    static let lineMultiple: CGFloat = 1.4

    static let added = NSColor.systemGreen.withAlphaComponent(0.12)
    static let addedGutter = NSColor.systemGreen.withAlphaComponent(0.16)
    static let addedWord = NSColor.systemGreen.withAlphaComponent(0.28)
    static let removed = NSColor.systemRed.withAlphaComponent(0.10)
    static let removedGutter = NSColor.systemRed.withAlphaComponent(0.16)
    static let removedWord = NSColor.systemRed.withAlphaComponent(0.28)
    static let hunk = NSColor.labelColor.withAlphaComponent(0.06)
    static let number = NSColor.tertiaryLabelColor

    /// From the page's left edge: margin, old numbers, new numbers, the
    /// +/- mark, then the code.
    static let margin: CGFloat = 16
    static let columnGap: CGFloat = 10
    static let markWidth: CGFloat = 12
    static let codeGap: CGFloat = 6

    static func digitWidth() -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: numberFont]).width
    }

    /// Width of one number column for numbers up to `maxNumber`.
    static func numberColumn(_ maxNumber: Int) -> CGFloat {
        CGFloat(max(3, String(maxNumber).count)) * digitWidth()
    }

    /// The language `ClaudeSyntax` knows a file by, from its extension.
    static func language(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt", "rtf", "csv", "lock", "": return "text"
        case "py": return "python"
        case "rb": return "ruby"
        case "yml": return "yaml"
        default: return ext
        }
    }

    /// The whole diff as one string: syntax colors, line attributes, and
    /// the changed part of each paired -/+ line marked.
    static func text(_ lines: [DiffLine], path: String, gutter: CGFloat) -> NSAttributedString {
        let joined = lines.map(\.text).joined(separator: "\n")
        let s = NSMutableAttributedString(attributedString:
            ClaudeSyntax.highlight(joined, language: language(for: path), font: font))
        let height = ClaudeTypography.lineHeight(font, lineMultiple)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = height
        para.maximumLineHeight = height
        para.headIndent = gutter
        para.firstLineHeadIndent = gutter
        para.lineBreakMode = .byCharWrapping
        let full = NSRange(location: 0, length: s.length)
        s.addAttribute(.paragraphStyle, value: para, range: full)
        s.addAttribute(.baselineOffset, value: ClaudeTypography.baselineOffset(font, lineMultiple), range: full)

        var ranges: [NSRange] = []
        var location = 0
        for (i, line) in lines.enumerated() {
            let length = (line.text as NSString).length + (i < lines.count - 1 ? 1 : 0)
            let range = NSRange(location: location, length: length)
            ranges.append(range)
            s.addAttribute(.diffLine, value: DiffLineInfo(line), range: range)
            if line.kind == .hunk || line.kind == .note {
                s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            }
            location += length
        }

        // Pair each run of removed lines with the added run after it, line
        // by line, and mark what differs between the two.
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .removed else { i += 1; continue }
            var j = i
            while j < lines.count, lines[j].kind == .removed { j += 1 }
            var k = j
            while k < lines.count, lines[k].kind == .added { k += 1 }
            for n in 0..<min(j - i, k - j) {
                markChange(old: lines[i + n].text, new: lines[j + n].text,
                           oldAt: ranges[i + n].location, newAt: ranges[j + n].location, in: s)
            }
            i = max(k, i + 1)
        }
        return s
    }

    /// Marks the middle that differs between two lines (after their common
    /// start and end), when they still have most of it in common.
    private static func markChange(old: String, new: String, oldAt: Int, newAt: Int, in s: NSMutableAttributedString) {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        guard !a.isEmpty, !b.isEmpty else { return }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let common = prefix + suffix
        // Too little in common: the whole line changed; a word mark would
        // only add noise.
        guard common >= 4, Double(common) / Double(max(a.count, b.count)) >= 0.3 else { return }
        let oldLength = a.count - common, newLength = b.count - common
        if oldLength > 0 {
            s.addAttribute(.backgroundColor, value: removedWord, range: NSRange(location: oldAt + prefix, length: oldLength))
        }
        if newLength > 0 {
            s.addAttribute(.backgroundColor, value: addedWord, range: NSRange(location: newAt + prefix, length: newLength))
        }
    }
}

// MARK: - Drawing

/// Draws each line's tint across the page and its numbers in the gutter.
nonisolated final class DiffLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Every row's height: AppKit gives an empty line its font's natural
    /// height, ignoring the paragraph's fixed one.
    var lineHeight: CGFloat = 0

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let missing = lineHeight - lineFragmentRect.pointee.height
        guard missing > 0.5 else { return false }
        lineFragmentRect.pointee.size.height = lineHeight
        lineFragmentUsedRect.pointee.size.height = lineHeight
        baselineOffset.pointee += missing / 2
        return true
    }

    var oldColumn: CGFloat = 24
    var newColumn: CGFloat = 24
    // DiffStyle's, copied in by the view (drawing isn't on the main actor).
    var margin: CGFloat = 16
    var columnGap: CGFloat = 10
    var markWidth: CGFloat = 12
    var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var colors: [DiffLine.Kind: (fill: NSColor, gutter: NSColor?)] = [:]

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawLines(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawLines(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width
        let gutterEnd = margin + oldColumn + columnGap + newColumn + columnGap + markWidth
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        var index = chars.location
        while index < NSMaxRange(chars) {
            var lineRange = NSRange()
            // The longest range: a plain effective range stops at every
            // syntax color, and the line would be tinted once per token.
            guard let info = storage.attribute(.diffLine, at: index, longestEffectiveRange: &lineRange,
                                               in: NSRange(location: 0, length: storage.length)) as? DiffLineInfo else {
                index = NSMaxRange(lineRange) > index ? NSMaxRange(lineRange) : index + 1
                continue
            }
            index = NSMaxRange(lineRange)
            let glyphs = glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let band = NSRect(x: origin.x, y: origin.y + first.minY, width: width, height: last.maxY - first.minY)

            let fill = colors[info.kind]?.fill, gutter = colors[info.kind]?.gutter
            if let fill { fill.setFill(); band.fill(using: .sourceOver) }
            if let gutter {
                gutter.setFill()
                NSRect(x: band.minX, y: band.minY, width: gutterEnd, height: band.height).fill(using: .sourceOver)
            }

            // Numbers and the mark on the line's first row, on its baseline.
            // An empty line has no glyph to take a baseline from: center.
            let empty = storage.attributedSubstring(from: lineRange).string.trimmingCharacters(in: .newlines).isEmpty
            let top = empty
                ? origin.y + first.minY + (first.height - (numberFont.ascender - numberFont.descender)) / 2
                : origin.y + first.minY + location(forGlyphAt: glyphs.location).y - numberFont.ascender
            func draw(_ text: String, right: CGFloat, attrs: [NSAttributedString.Key: Any]) {
                let size = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: origin.x + right - size.width, y: top), withAttributes: attrs)
            }
            let oldRight = margin + oldColumn
            let newRight = oldRight + columnGap + newColumn
            if let old = info.old { draw("\(old)", right: oldRight, attrs: numberAttrs) }
            if let new = info.new { draw("\(new)", right: newRight, attrs: numberAttrs) }
            if info.kind == .hunk {
                // Lines skipped between two hunks.
                draw("⋯", right: newRight, attrs: numberAttrs)
            }
            if info.kind == .added || info.kind == .removed {
                let mark = info.kind == .added ? "+" : "−"
                draw(mark, right: gutterEnd, attrs: [.font: numberFont,
                                                     .foregroundColor: info.kind == .added ? NSColor.systemGreen : NSColor.systemRed])
            }
        }
    }
}

// MARK: - View

/// The scrolling diff: one non-editable, selectable text view.
struct DiffTextView: NSViewRepresentable {
    let lines: [DiffLine]
    let path: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(usingTextLayoutManager: false)
        let layout = DiffLayoutManager()
        layout.allowsNonContiguousLayout = true
        text.textContainer?.replaceLayoutManager(layout)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        // Painted on every redraw, so the translucent tints never stack.
        text.drawsBackground = true
        text.backgroundColor = ClaudeStyle.background
        text.textContainerInset = NSSize(width: 0, height: 14)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        fill(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    private func fill(_ text: NSTextView) {
        guard let layout = text.layoutManager as? DiffLayoutManager else { return }
        layout.lineHeight = ClaudeTypography.lineHeight(DiffStyle.font, DiffStyle.lineMultiple)
        layout.margin = DiffStyle.margin
        layout.columnGap = DiffStyle.columnGap
        layout.markWidth = DiffStyle.markWidth
        layout.numberFont = DiffStyle.numberFont
        layout.colors = [.added: (DiffStyle.added, DiffStyle.addedGutter),
                         .removed: (DiffStyle.removed, DiffStyle.removedGutter),
                         .hunk: (DiffStyle.hunk, nil), .note: (DiffStyle.hunk, nil)]
        layout.oldColumn = DiffStyle.numberColumn(lines.compactMap(\.old).max() ?? 0)
        layout.newColumn = DiffStyle.numberColumn(lines.compactMap(\.new).max() ?? 0)
        let gutter = DiffStyle.margin + layout.oldColumn + DiffStyle.columnGap + layout.newColumn
            + DiffStyle.columnGap + DiffStyle.markWidth + DiffStyle.codeGap
        text.textStorage?.setAttributedString(DiffStyle.text(lines, path: path, gutter: gutter))
    }
}
