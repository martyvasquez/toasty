import SwiftUI

/// An icon button in a bar or header, as Things' toolbar buttons: nothing
/// at rest, a hairline capsule under the pointer, filled while pressed (or
/// while `active`, e.g. its menu is open), and a tooltip that says what
/// it does.
struct BarIconButton: View {
    let symbol: String
    let tooltip: Tooltip
    var active = false
    /// Something is on right now (dictation's look while listening): the
    /// glyph and a light fill in the accent color.
    var accent = false
    var glyphSize = Theme.Size.control
    /// The capsule around the glyph.
    var size = CGSize(width: 32, height: 24)
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(glyphSize, .medium))
                .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary)
                                 : accent ? AnyShapeStyle(Color.accentColor)
                                 : hovering || active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: size.width, height: size.height)
                .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering && enabled, active: active, accent: accent && enabled))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip(tooltip)
        .accessibilityLabel(tooltip.title)
    }
}

/// The states of a bar button, drawn behind its label.
struct BarButtonStyle: ButtonStyle {
    var hovering: Bool
    var active = false
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        let filled = configuration.isPressed || active || accent
        configuration.label
            .background(Capsule().fill(accent ? Color.accentColor.opacity(configuration.isPressed || hovering ? 0.22 : 0.14)
                                       : filled ? Theme.Fill.pressed : Color.clear))
            .overlay(Capsule().strokeBorder(hovering && !filled ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
    }
}

/// A footer's labeled button (Things' "+ New List"): a glyph and a word at
/// 13pt in the footer's gray, brighter with a hairline capsule on hover,
/// filled while pressed, with a tooltip. Shared by the sidebar's and the
/// inspector's footers.
struct BarLabelButton: View {
    let symbol: String
    let title: String
    let tooltip: Tooltip
    let action: () -> Void
    @State private var hovering = false

    /// The capsule's padding: callers shift the button by this so the glyph,
    /// not the capsule, sits on their text edge.
    static var padding: CGFloat { Theme.Space.s + Theme.Space.xxs }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                Image(systemName: symbol).font(.toasty(Theme.Size.control))
                Text(title).font(.toasty(Theme.Size.control))
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.Sidebar.footerTextColor))
            .padding(.horizontal, Self.padding)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip(tooltip)
        .accessibilityLabel(title)
    }
}
