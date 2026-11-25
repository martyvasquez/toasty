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

/// A bar button with others tucked behind it, as the tab row's + hides
/// New Terminal: hovering slides them out to its left, so a click where it
/// sits always does the usual thing and the others are one step over. They
/// fold back shortly after the pointer leaves. With `reserve`, their room
/// is kept while they're hidden (nothing beside them moves); without it,
/// what's to their left makes way as they open.
struct HoverRevealButtons<Hidden: View, Main: View>: View {
    /// How many buttons `hidden` holds, each `size` wide.
    let count: Int
    let size: CGSize
    var reserve = false
    @ViewBuilder let hidden: () -> Hidden
    @ViewBuilder let main: () -> Main
    @State private var open = false
    @State private var collapse: DispatchWorkItem?

    var body: some View {
        let room = size.width * CGFloat(count)
        HStack(spacing: 0) {
            if count > 0 {
                HStack(spacing: 0) { hidden() }
                    .fixedSize()
                    .onHover(perform: hover)
                    .opacity(open ? 1 : 0)
                    .offset(x: open ? 0 : 10)
                    .allowsHitTesting(open)
                    .frame(width: open ? room : 0, alignment: .trailing)
                    .clipped()
            }
            main().onHover(perform: hover)
        }
        .frame(width: reserve ? room + size.width : nil, alignment: .trailing)
    }

    private func hover(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            withAnimation(.easeOut(duration: 0.16)) { open = true }
        } else {
            let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.16)) { open = false } }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}
