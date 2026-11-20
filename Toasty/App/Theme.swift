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

    // MARK: Fills

    /// Backgrounds laid over a surface: hover, selection, pressed, chips.
    /// One ladder of `primary` opacities, so every gray agrees.
    enum Fill {
        /// Pointer over a row or button.
        static let hover = Color.primary.opacity(0.05)
        /// Quiet surfaces: chips, code, cards inside the page.
        static let subtle = Color.primary.opacity(0.06)
        /// The selected row.
        static let selected = Color.primary.opacity(0.10)
        /// Mouse down.
        static let pressed = Color.primary.opacity(0.14)
    }

    // MARK: Shape

    enum Radius {
        /// Small buttons, chips, badges.
        static let small: CGFloat = 6
        /// Rows and their selection, menus' items, small cards.
        static let row: CGFloat = 8
        /// Cards, bubbles, popovers.
        static let card: CGFloat = 12
        /// The composer and sheets.
        static let large: CGFloat = 18
    }

    // MARK: Space

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
        /// A workspace's row: one line of body text.
        static let rowHeight: CGFloat = 28
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

extension Font {
    /// System font at a `Theme.Size` step.
    static func toasty(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
