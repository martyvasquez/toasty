import AppKit
import SwiftUI

/// Design tokens shared by the window chrome and the conversation (§5).
/// System colors and fonts throughout, so everything follows light/dark
/// mode and the accent color; only spacing and sizes are chosen here.
/// (Phase 3 merges the rest of mostty's `ClaudeStyle` in.)
enum ClaudeStyle {
    /// The conversation's page (and a selected tab).
    static var background: NSColor { .textBackgroundColor }

    /// Toolbar surfaces (the titlebar row over both columns): a step away
    /// from the page so the bars read as one toolbar, like Safari/Xcode.
    static let chrome = NSColor(name: "toastyChrome") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.165, alpha: 1)   // #2A2A2A
            : NSColor(white: 0.933, alpha: 1)   // #EEEEEE
    }

    /// Raised surfaces you type into or answer (composer, prompt cards).
    static let field = NSColor(name: "toastyField") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.19, alpha: 1)
            : NSColor.white
    }

    /// The transcript and the composer share one width.
    static let composerWidth: CGFloat = 900
    static let cornerRadius: CGFloat = 10
}

extension Color {
    static var claudeBackground: Color { Color(nsColor: ClaudeStyle.background) }
    static var claudeChrome: Color { Color(nsColor: ClaudeStyle.chrome) }
    static var claudeField: Color { Color(nsColor: ClaudeStyle.field) }
    /// Hairline separators.
    static var claudeSeparator: Color { Color(nsColor: .separatorColor) }
    /// Subtle fill for cards and code.
    static var claudeFill: Color { Color.primary.opacity(0.045) }
}
