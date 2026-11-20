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
    }

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
        /// A bar button under the pointer: a hairline capsule.
        static let hover = Color.primary.opacity(0.15)
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
        /// The composer, message bubbles, request cards and sheets.
        static let large: CGFloat = 18
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
        static let rowHeight: CGFloat = 26
        /// The row icons' glyph size: a little larger than the text, as
        /// Things' 18pt icons beside 14pt names.
        static let iconSize: CGFloat = 15
        /// Rows' and headings' inset from the sidebar's edges.
        static let inset: CGFloat = 8
        /// A row's content inset inside its selection.
        static let rowPadding: CGFloat = 8
        /// The leading icon's box; names start after it.
        static let iconWidth: CGFloat = 18
        static let iconGap: CGFloat = 8
        /// Space above a heading (groups are set apart by space).
        static let headingSpaceAbove: CGFloat = 16
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
