import AppKit
import SwiftUI

/// mostty: Design tokens for native Claude tabs. System colors and fonts
/// throughout, so tabs follow light/dark mode and the accent color like any
/// Mac app; only spacing and sizes are chosen here.
enum ClaudeStyle {
    static var bodySize: CGFloat { ClaudeTypography.bodySize }
    static var codeSize: CGFloat { ClaudeTypography.codeSize }
    static let lineHeight: CGFloat = 1.3
    /// Comfortable reading measure for the transcript (about 70 characters).
    static var readingWidth: CGFloat { ClaudeTypography.measure }
    static let horizontalPadding: CGFloat = 28

    /// The conversation's background (and the Claude tab's window).
    static var background: NSColor { .textBackgroundColor }
    /// Toolbar surfaces (the tab row, the terminal panel's tab row): a step
    /// away from the page so the bars read as one toolbar, like Safari/Xcode.
    static let chrome = NSColor(name: "mosttyChrome") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.165, alpha: 1)   // #2a2a2a, the terminal theme's too
            : NSColor(white: 0.933, alpha: 1)   // #eeeeee
    }

    /// Raised surfaces you type into or answer (composer, prompt cards):
    /// lifted off the page in dark mode, plain white in light mode.
    static let field = NSColor(name: "mosttyField") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.19, alpha: 1)
            : NSColor.white
    }


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

