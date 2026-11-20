import AppKit
import SwiftUI

/// Toasty's visual standard: every font size, weight, fill, radius and
/// spacing a view uses comes from here, never a literal. Modeled on Things 3
/// (which keeps its whole design in one theme file): a few values, reused
/// everywhere, with hierarchy carried by weight and ink rather than size.
///
/// Colors stay system colors (ink is `.primary` / `.secondary` /
/// `.tertiary` / `.quaternary`; the accent is the user's), so everything
/// follows light/dark mode and the accent setting.
enum Theme {
    // MARK: Type

    /// The type scale. Six sizes; pick by role, not by eye.
    enum Size {
        /// Badges, counts, shortcut hints.
        static let caption: CGFloat = 11
        /// The second line under a title, timestamps, small labels.
        static let meta: CGFloat = 12
        /// Controls: tabs, buttons, inspector rows, toolbars, tooltips.
        static let control: CGFloat = 13
        /// Reading and the main lists: the conversation, the composer,
        /// sidebar rows and headings.
        static let body: CGFloat = 14
        /// Titles of panels and sheets.
        static let title: CGFloat = 17
        /// Empty states and first-run screens.
        static let display: CGFloat = 23
    }

    /// SF Symbols used as marks rather than icons beside text.
    enum Glyph {
        /// Chevrons, close and play/pause marks (always semibold).
        static let small: CGFloat = 9
        /// The large faint icon of an empty state (always light).
        static let hero: CGFloat = 28
        /// A new conversation's icon: Things' large, faint empty-list mark.
        static let emptyState: CGFloat = 56
    }

    /// Your messages in the conversation: a deep, slightly muted blue with
    /// white text (as the Claude app's), from the accent so it follows the
    /// system setting; in light mode the accent itself.
    static let bubbleBlue = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? (NSColor.controlAccentColor.blended(withFraction: 0.64, of: NSColor(white: 0.25, alpha: 1)) ?? .controlAccentColor)
            : .controlAccentColor
    })

    /// The headings' blue: the accent, softened toward white in dark mode
    /// (as Things' heading blue).
    static let headingBlue = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? (NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor)
            : .controlAccentColor
    })

    // MARK: Fills

    /// Backgrounds laid over a surface: hover, selection, pressed, chips.
    /// One ladder of `primary` opacities, so every gray agrees.
    enum Fill {
        /// The selected row of a menu or list that has focus, an option
        /// that's on.
        static let accent = Color.accentColor.opacity(0.16)
        /// Large quiet surfaces inside the page: cards, code, options.
        static let faint = Color.primary.opacity(0.04)
        /// Pointer over a row or button.
        static let hover = Color.primary.opacity(0.06)
        /// Small quiet surfaces: chips, badges, key caps, fields.
        static let subtle = Color.primary.opacity(0.07)
        /// The selected row.
        static let selected = Color.primary.opacity(0.10)
        /// Mouse down.
        static let pressed = Color.primary.opacity(0.14)
    }

    /// Outlines of cards, fields and chips (widths vary; the color doesn't).
    enum Stroke {
        static let border = Color.primary.opacity(0.10)
        /// Between a bar and what it sits on (Things' toolbar divider: a
        /// darker line, black 20% in dark mode, navy 6% in light).
        static let barDivider = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0, alpha: 0.20)
                : NSColor(srgbRed: 0, green: 0x13 / 255.0, blue: 0x30 / 255.0, alpha: 0.06)
        })
        /// A bar button under the pointer: a hairline capsule.
        static let hover = Color.primary.opacity(0.15)
        /// The rule under a heading (Things': white 15% / navy 10%).
        static let rule = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.15)
                : NSColor(srgbRed: 0, green: 0x19 / 255.0, blue: 0x3d / 255.0, alpha: 0.10)
        })
    }

    /// Tooltips (see Tooltip.swift): a small popover-like panel.
    enum Tooltip {
        static let background = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.265, alpha: 1) : .white
        })
        /// A light inner edge (dark mode) and a dark outer hairline.
        static let innerBorder = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.12) : .clear
        })
        static let outerBorder = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.6) : NSColor(white: 0, alpha: 0.12)
        })
        /// The shortcut and the detail line: a step below the title.
        static let secondaryOpacity: Double = 0.75
        static let maxTextWidth: CGFloat = 200
    }

    // MARK: Shape

    enum Radius {
        /// Small buttons, chips, badges.
        static let small: CGFloat = 6
        /// Rows and their selection, menus' items, small cards.
        static let row: CGFloat = 8
        /// Cards, bubbles, popovers.
        static let card: CGFloat = 12
        /// The composer, request cards and sheets.
        static let large: CGFloat = 18
        /// Your messages: Things' card radius (its expanded to-do).
        static let message: CGFloat = 14
    }

    // MARK: Elevation

    /// Surfaces that float over the page: the composer, request cards.
    /// One shadow, so they read as the same layer.
    enum Elevation {
        static let raisedColor = Color.black.opacity(0.10)
        static let raisedRadius: CGFloat = 8
        static let raisedY: CGFloat = 3
        /// Menus and toasts, over everything.
        static let popoverColor = Color.black.opacity(0.20)
        static let popoverRadius: CGFloat = 12
        static let popoverY: CGFloat = 4
        /// A small control lifted off its bar (the selected tab).
        static let liftColor = Color.black.opacity(0.16)
        static let liftRadius: CGFloat = 2
        static let liftY: CGFloat = 1
    }

    // MARK: Controls

    enum Control {
        /// Buttons, chips and icon buttons in bars and the composer.
        static let height: CGFloat = 28
    }

    /// Menus Toasty draws itself (the composer's / and @ menus).
    enum Menu {
        static let rowHeight: CGFloat = 32
        static let headerHeight: CGFloat = 26
        /// Rows' inset from the menu's edge, and text's inset in a row:
        /// together the 16pt text edge the sidebar and composer use too.
        static let inset = Theme.Space.xs
        static let rowPadding = Theme.Space.m
    }

    // MARK: Space

    /// Text sits this far from the edge of its container (sidebar,
    /// composer, menus), however the inset and row padding split it.
    static let textEdge: CGFloat = 16

    /// Spacing steps; use these for padding and gaps.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Sidebar

    enum Sidebar {
        /// A workspace's row: one line of body text (rows touch; groups
        /// are set apart by space).
        static let rowHeight: CGFloat = 24
        /// The row icons' glyph size: a little larger than the text, as
        /// Things' 18pt icons beside 14pt names.
        static let iconSize: CGFloat = 15
        /// Rows' and headings' inset from the sidebar's edges (the
        /// selection's margin): Things' 13.
        static let inset: CGFloat = 13
        /// A row's content inside its selection: 7 before the name, 8 after
        /// the last mark (Things' icon guide and badge margin).
        static let rowLeading: CGFloat = 7
        static let rowTrailing: CGFloat = 8
        /// The selected row, as Things': a cool blue-gray rather than a
        /// neutral one (on screen ≈ #4C4F53 over the dark sidebar, #DDE0E5
        /// over the light one).
        static let selection = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 180 / 255, green: 195 / 255, blue: 215 / 255, alpha: 0.15)
                : NSColor(srgbRed: 0, green: 10 / 255, blue: 31 / 255, alpha: 0.10)
        })
        /// Names: Things' sidebar title color, a step quieter than labels
        /// (white at 80% in dark mode; blue-black at 78% in light).
        static let titleColor = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.80)
                : NSColor(srgbRed: 0, green: 4 / 255, blue: 9 / 255, alpha: 0.776)
        })
        /// The leading icon's box; names start after it.
        static let iconWidth: CGFloat = 18
        static let iconGap: CGFloat = 8
        /// Space above a heading (groups are set apart by space).
        static let headingSpaceAbove: CGFloat = 16
        /// A hairline under each heading (as Things' project headings).
        /// Off: headings are plain rows, as Things' sidebar areas.
        static let headingRule = true
        /// A row's ⌘-number slot at its end (always kept, so status marks
        /// before it line up).
        static let shortcutWidth: CGFloat = 20
        /// From the window's top to the list's first row (Things: the first
        /// row's middle 47pt below the window buttons', at 72.5).
        static let listTop: CGFloat = 60
        /// The handle at the sidebar's edge (Things': white 18% / navy 12%).
        static let handle = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.18)
                : NSColor(srgbRed: 0, green: 0x1c / 255.0, blue: 0x46 / 255.0, alpha: 0.13)
        })
        /// The footer under the list (New Workspace, New Heading): Things'
        /// 40pt, its button text 13pt at white 66% (navy-black 64% light).
        static let footerHeight: CGFloat = 40
        static let footerTextColor = Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.66)
                : NSColor(srgbRed: 0, green: 5 / 255, blue: 12 / 255, alpha: 0.64)
        })
    }
}

extension View {
    /// The shadow of a surface floating over the page (`Theme.Elevation`).
    func raisedShadow() -> some View {
        shadow(color: Theme.Elevation.raisedColor, radius: Theme.Elevation.raisedRadius, y: Theme.Elevation.raisedY)
    }

    func popoverShadow() -> some View {
        shadow(color: Theme.Elevation.popoverColor, radius: Theme.Elevation.popoverRadius, y: Theme.Elevation.popoverY)
    }

    func liftShadow() -> some View {
        shadow(color: Theme.Elevation.liftColor, radius: Theme.Elevation.liftRadius, y: Theme.Elevation.liftY)
    }
}

extension Font {
    /// System font at a `Theme.Size` step.
    static func toasty(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}
