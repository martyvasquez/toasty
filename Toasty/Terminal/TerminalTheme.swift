import AppKit
import GhosttyVt

/// The terminal's look: macOS Terminal's "Apple System Colors" palette on
/// true black (dark) or #EEEEEE (light), SF Mono 13.
nonisolated struct TerminalTheme: Sendable {
    var background: RGB
    var foreground: RGB
    var cursor: RGB
    var cursorText: RGB
    var selectionBackground: RGB
    var selectionForeground: RGB
    var palette: [RGB]

    struct RGB: Equatable, Hashable, Sendable {
        var r: UInt8, g: UInt8, b: UInt8
        init(_ hex: UInt32) { r = UInt8(hex >> 16 & 0xFF); g = UInt8(hex >> 8 & 0xFF); b = UInt8(hex & 0xFF) }
        init(_ c: GhosttyColorRgb) { r = c.r; g = c.g; b = c.b }
        var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
        var cgColor: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
        func cgColor(alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
        }
    }

    private static let basePalette: [UInt32] = [
        0x1A1A1A, 0xCC372E, 0x26A439, 0xCDAC08, 0x0869CB, 0x9647BF, 0x479EC2, 0x98989D,
        0x464646, 0xFF453A, 0x32D74B, 0xFFD60A, 0x0A84FF, 0xBF5AF2, 0x76D6FF, 0xFFFFFF,
    ]

    static let dark = TerminalTheme(
        background: RGB(0x000000), foreground: RGB(0xFFFFFF),
        cursor: RGB(0x98989D), cursorText: RGB(0xFFFFFF),
        selectionBackground: RGB(0x3F638B), selectionForeground: RGB(0xFFFFFF),
        palette: basePalette.map(RGB.init))

    static let light: TerminalTheme = {
        var p = basePalette
        p[11] = 0xE5BC00
        p[14] = 0x69C9F2
        return TerminalTheme(
            background: RGB(0xEEEEEE), foreground: RGB(0x000000),
            cursor: RGB(0x98989D), cursorText: RGB(0xFFFFFF),
            selectionBackground: RGB(0xABD8FF), selectionForeground: RGB(0x000000),
            palette: p.map(RGB.init))
    }()

    static func current(for appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    /// Padding inside the terminal, around the cell grid.
    static let paddingX: CGFloat = 12
    static let paddingY: CGFloat = 8
}

/// Font and cell metrics for the grid.
nonisolated struct TerminalFont: @unchecked Sendable {
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Distance from the top of a cell to the baseline.
    let baseline: CGFloat
    let underlinePosition: CGFloat
    let underlineThickness: CGFloat

    init(size: CGFloat = 13) {
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        regular = base as CTFont
        bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold) as CTFont
        let italicDesc = (base.fontDescriptor).withSymbolicTraits(.italic)
        italic = (NSFont(descriptor: italicDesc, size: size) ?? base) as CTFont
        let boldBase = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        boldItalic = (NSFont(descriptor: boldBase.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? boldBase) as CTFont

        var glyph = CGGlyph(0)
        var ch = UniChar(0x4D) // "M"
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)
        cellWidth = advance.width
        let ascent = CTFontGetAscent(regular), descent = CTFontGetDescent(regular), leading = CTFontGetLeading(regular)
        cellHeight = ceil(ascent + descent + leading)
        baseline = ceil(ascent + leading / 2)
        underlinePosition = CTFontGetUnderlinePosition(regular)
        underlineThickness = max(1, CTFontGetUnderlineThickness(regular))
    }

    func font(bold b: Bool, italic i: Bool) -> CTFont {
        switch (b, i) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        default: regular
        }
    }
}
