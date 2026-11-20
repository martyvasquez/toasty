import SwiftUI

/// An icon button in a bar or header, as Things' toolbar buttons: nothing
/// at rest, a hairline capsule under the pointer, filled while pressed (or
/// while `active`, e.g. its menu is open), and a tooltip that says what
/// it does.
struct BarIconButton: View {
    let symbol: String
    let tooltip: Tooltip
    var active = false
    /// The capsule around the glyph.
    var size = CGSize(width: 32, height: 24)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.control, .medium))
                .foregroundStyle(hovering || active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: size.width, height: size.height)
                .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering, active: active))
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

    func makeBody(configuration: Configuration) -> some View {
        let filled = configuration.isPressed || active
        configuration.label
            .background(Capsule().fill(filled ? Theme.Fill.pressed : Color.clear))
            .overlay(Capsule().strokeBorder(hovering && !filled ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
    }
}
