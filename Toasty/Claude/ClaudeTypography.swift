import AppKit

/// The typography of Claude's replies. Modeled on Marker (the
/// author's Markdown editor), whose proportions were tuned side by side
/// against Bear: 14.5pt SF Pro on a 1.5 line pitch with the leading split
/// evenly above and below each line, a full line between paragraphs, soft
/// graphite text, semibold for emphasis, and the accent color as the only
/// color (bullets, numbers, quote bars, links).
///
/// One deliberate difference: headings. In a document they're titles; in a
/// chat reply they're section labels, so the scale is gentler.
nonisolated enum ClaudeTypography {
    // MARK: Sizes

    // Tuned against Conductor for density: a touch smaller than Marker,
    // which is set for documents rather than a conversation.
    static let bodySize: CGFloat = 14
    static let codeSize: CGFloat = 13
    static let headingSizes: [CGFloat] = [21, 18, 15.5, 14.5, 14, 14]

    static let lineHeightMultiple: CGFloat = 1.5
    static let headingLineHeightMultiple: CGFloat = 1.2
    static let codeLineHeightMultiple: CGFloat = 1.45
    /// Space above a heading beyond the paragraph gap, as a fraction of its
    /// size: a heading sits closer to its own text than to what came before.
    static let headingSpacingBefore: CGFloat = 0.45

    /// The column: replies and the composer share this width and edges.
    static let composerWidth: CGFloat = 900
    static var measure: CGFloat { composerWidth }

    static let codeBlockPadding: CGFloat = 14
    static let tableCellPadding: CGFloat = 12
    static let tableRowPadding: CGFloat = 7

    // List geometry, scaled with the body size (Marker's values).
    static var listLevelStep: CGFloat { (bodySize * 1.6).rounded() }
    static var listTextOffset: CGFloat { (bodySize * 1.6).rounded() }
    static var bulletCenterOffset: CGFloat { (bodySize * 0.6).rounded() }
    static var listNumberGap: CGFloat { (bodySize * 0.45).rounded() }
    static let quoteBarWidth: CGFloat = 3
    static var quoteIndent: CGFloat { (bodySize * 1.25).rounded() }

    // MARK: Colors

    /// Soft graphite rather than pure black/white (Bear: #444 / #DFE0E0).
    static let text = NSColor.dynamic(light: NSColor(srgbHex: 0x444444), dark: NSColor(srgbHex: 0xDFE0E0))
    static let secondaryText = NSColor.dynamic(light: NSColor(srgbHex: 0x888888), dark: NSColor(srgbHex: 0xA2A3A4))
    static let accent = NSColor.controlAccentColor
    static let link = NSColor.linkColor
    static let linkUnderline = NSColor.linkColor.withAlphaComponent(0.4)
    static let codeBackground = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let tableBorder = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    static let tableHeader = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.05))
    static let tableAlternateRow = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.065))
    static let rule = NSColor.separatorColor

    // Code: Bear's Dark Graphite (dark) and Red Graphite (light) palettes.
    static let syntaxKeyword = NSColor.dynamic(light: NSColor(srgbHex: 0xAD3DA4), dark: NSColor(srgbHex: 0x70B8D7))
    static let syntaxType = NSColor.dynamic(light: NSColor(srgbHex: 0x4A838B), dark: NSColor(srgbHex: 0xAAC97F))
    static let syntaxString = NSColor.dynamic(light: NSColor(srgbHex: 0xD12F1B), dark: NSColor(srgbHex: 0xE6945E))
    static let syntaxNumber = NSColor.dynamic(light: NSColor(srgbHex: 0x0095C9), dark: NSColor(srgbHex: 0xE6945E))
    static let syntaxComment = NSColor.dynamic(light: NSColor(srgbHex: 0x8A95A0), dark: NSColor(srgbHex: 0x7F8C97))

    // MARK: Fonts

    static var body: NSFont { .systemFont(ofSize: bodySize) }
    static var code: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }

    static func heading(_ level: Int) -> NSFont {
        .systemFont(ofSize: headingSizes[min(max(level, 1), 6) - 1], weight: .semibold)
    }

    /// Inline code at the size that matches the surrounding text.
    static func code(matching font: NSFont) -> NSFont {
        .monospacedSystemFont(ofSize: (font.pointSize * codeSize / bodySize).rounded(), weight: .regular)
    }

    // MARK: Line rhythm

    // Lines get a fixed height with the extra leading split evenly above and
    // below the text ("half-leading", like CSS line-height). TextKit would
    // otherwise put all of it above each line, which makes the gap after a
    // block look bigger than the gap before it.

    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func lineHeight(_ font: NSFont, _ multiple: CGFloat = lineHeightMultiple) -> CGFloat {
        (naturalLineHeight(font) * multiple).rounded()
    }

    /// Raises glyphs to the vertical middle of a fixed-height line.
    static func baselineOffset(_ font: NSFont, _ multiple: CGFloat = lineHeightMultiple) -> CGFloat {
        max(0, ((lineHeight(font, multiple) - naturalLineHeight(font)) / 2).rounded())
    }

    /// The gap between paragraphs: a little over half a line. Tighter than
    /// a document's blank line; replies read as one continuous answer.
    static var paragraphGap: CGFloat { (lineHeight(body) * 0.6).rounded() }

    static func paragraphStyle(
        font: NSFont = body, multiple: CGFloat = lineHeightMultiple,
        headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
        spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        let height = lineHeight(font, multiple)
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineIndent ?? headIndent
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.lineBreakStrategy = .standard
        p.hyphenationFactor = 0
        return p
    }

    static var linkAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: link,
         .underlineStyle: NSUnderlineStyle.single.rawValue,
         .underlineColor: linkUnderline,
         .cursor: NSCursor.pointingHand]
    }

    /// "Bold" is semibold on regular text (SF Bold reads heavy next to body
    /// text) and bold on text that's already semibold, like headings.
    static func adding(bold: Bool, italic: Bool, to font: NSFont) -> NSFont {
        var f = font
        if bold {
            let traits = f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any] ?? [:]
            let weight = traits[.weight] as? CGFloat ?? 0
            let target: NSFont.Weight = weight >= NSFont.Weight.semibold.rawValue ? .bold : .semibold
            var t = traits
            t[.weight] = target.rawValue
            f = NSFont(descriptor: f.fontDescriptor.addingAttributes([.traits: t]), size: f.pointSize) ?? f
        }
        if italic {
            var traits = f.fontDescriptor.symbolicTraits
            traits.insert(.italic)
            f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f
        }
        return f
    }
}

nonisolated extension NSAttributedString.Key {
    /// Inline code span: ClaudeLayoutManager draws its background.
    static let claudeInlineCode = NSAttributedString.Key("toastyInlineCode")
    /// A list bullet placeholder (value: nesting level); drawn as a shape.
    static let claudeBullet = NSAttributedString.Key("toastyBullet")
    /// A task list checkbox placeholder (value: checked); drawn as a box.
    static let claudeTask = NSAttributedString.Key("toastyTask")
    /// A quote paragraph (value: nesting depth); drawn as accent bars.
    static let claudeQuote = NSAttributedString.Key("toastyQuote")
}

nonisolated extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// TextKit 1 layout manager for Claude's replies: draws the inline
/// code backgrounds, list bullets and quote bars (Marker's drawing).
nonisolated final class ClaudeLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            drawQuoteBars(in: chars, storage: storage, container: container, origin: origin)
            drawInlineCode(in: chars, storage: storage, container: container, origin: origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.claudeBullet, in: chars) { value, range, _ in
            guard let level = value as? Int else { return }
            drawBullet(level: level, at: range.location, storage: storage, container: container, origin: origin)
        }
        storage.enumerateAttribute(.claudeTask, in: chars) { value, range, _ in
            guard let checked = value as? Bool else { return }
            drawCheckbox(checked: checked, at: range.location, storage: storage, container: container, origin: origin)
        }
    }

    /// A rounded square (with a check when done), centered on the x-height.
    private func drawCheckbox(checked: Bool, at index: Int, storage: NSTextStorage, container: NSTextContainer, origin: NSPoint) {
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return }
        let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? ClaudeTypography.body
        let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let side = (font.pointSize * 1.0).rounded()
        let stroke: CGFloat = 1.2
        let midY = baselineY(forGlyphAt: glyph) - font.capHeight / 2
        let square = NSRect(x: (origin.x + rect.minX + 1).rounded(), y: (origin.y + midY - side / 2).rounded(),
                            width: side, height: side)
        let color = checked ? ClaudeTypography.accent : ClaudeTypography.secondaryText
        if checked {
            color.setFill()
            NSBezierPath(roundedRect: square, xRadius: side * 0.24, yRadius: side * 0.24).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: square.minX + side * 0.27, y: square.minY + side * 0.52))
            check.line(to: NSPoint(x: square.minX + side * 0.44, y: square.minY + side * 0.69))
            check.line(to: NSPoint(x: square.minX + side * 0.74, y: square.minY + side * 0.33))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            let outline = NSBezierPath(roundedRect: square.insetBy(dx: stroke / 2, dy: stroke / 2),
                                       xRadius: side * 0.24 - stroke / 2, yRadius: side * 0.24 - stroke / 2)
            outline.lineWidth = stroke
            color.setStroke()
            outline.stroke()
        }
    }

    /// Rounded backgrounds behind inline code, one tight box per visual line.
    private func drawInlineCode(in chars: NSRange, storage: NSTextStorage, container: NSTextContainer, origin: NSPoint) {
        let text = storage.string as NSString
        storage.enumerateAttribute(.claudeInlineCode, in: chars) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? ClaudeTypography.code
            enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
                var part = NSIntersectionRange(lineGlyphs, glyphs)
                // Drop whitespace where the span wraps.
                while part.length > 0 {
                    let c = text.character(at: self.characterIndexForGlyph(at: NSMaxRange(part) - 1))
                    guard c == 0x20 || c == 0x09 || c == 0x0A else { break }
                    part.length -= 1
                }
                guard part.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: part, in: container)
                // The trailing kern is padding, not glyph.
                if let kern = storage.attribute(.kern, at: self.characterIndexForGlyph(at: NSMaxRange(part) - 1),
                                                effectiveRange: nil) as? CGFloat {
                    rect.size.width -= kern
                }
                let baseline = self.baselineY(forGlyphAt: part.location)
                let box = NSRect(x: origin.x + rect.minX - 3,
                                 y: origin.y + baseline - font.ascender - 2,
                                 width: rect.width + 6,
                                 height: font.ascender - font.descender + 4)
                ClaudeTypography.codeBackground.setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    /// One accent bar per quote level, spanning its paragraph's lines so
    /// adjacent quote lines join.
    private func drawQuoteBars(in chars: NSRange, storage: NSTextStorage, container: NSTextContainer, origin: NSPoint) {
        let text = storage.string as NSString
        let paragraphs = text.paragraphRange(for: chars)
        storage.enumerateAttribute(.claudeQuote, in: paragraphs) { value, run, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude, bottom: CGFloat = 0
            var first = true
            enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
                // The quote's first line: from its text, not the paragraph
                // gap above it. Later lines join up through their gaps.
                let lineTop = first ? used.maxY - ClaudeTypography.lineHeight(ClaudeTypography.body) : rect.minY
                first = false
                top = min(top, lineTop)
                bottom = max(bottom, rect.maxY)
            }
            guard bottom > top else { return }
            ClaudeTypography.accent.withAlphaComponent(0.85).setFill()
            for level in 0..<depth {
                let x = origin.x + CGFloat(level) * ClaudeTypography.quoteIndent
                let bar = NSRect(x: x, y: origin.y + top, width: ClaudeTypography.quoteBarWidth, height: bottom - top)
                let r = ClaudeTypography.quoteBarWidth / 2
                NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
            }
        }
    }

    /// Dot, ring, diamond by nesting level, in the accent color.
    private func drawBullet(level: Int, at index: Int, storage: NSTextStorage, container: NSTextContainer, origin: NSPoint) {
        let glyph = glyphIndexForCharacter(at: index)
        guard glyph < numberOfGlyphs else { return }
        let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? ClaudeTypography.body
        let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let center = NSPoint(x: origin.x + rect.minX + ClaudeTypography.bulletCenterOffset,
                             y: origin.y + baselineY(forGlyphAt: glyph) - font.xHeight / 2)
        let r = ((font.pointSize * 0.17) * 10).rounded() / 10
        let dot = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ClaudeTypography.accent.set()
        switch level % 3 {
        case 0:
            NSBezierPath(ovalIn: dot).fill()
        case 1:
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1.2
            ring.stroke()
        default:
            let d = r * 1.15
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: center.x, y: center.y - d))
            diamond.line(to: NSPoint(x: center.x + d, y: center.y))
            diamond.line(to: NSPoint(x: center.x, y: center.y + d))
            diamond.line(to: NSPoint(x: center.x - d, y: center.y))
            diamond.close()
            diamond.fill()
        }
    }

    /// Baseline of a glyph's line, in container coordinates (flipped).
    private func baselineY(forGlyphAt glyph: Int) -> CGFloat {
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + location(forGlyphAt: glyph).y
    }
}
