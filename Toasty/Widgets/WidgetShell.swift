import AppKit
import SwiftUI

// MARK: - What a widget's content knows about its place

/// A widget's place, for the pieces inside it (a Small's header is quieter).
struct WidgetContext {
    var item: WidgetItem
    /// Units drawn (a dragged edge's target while dragging).
    var units: Int
    var editing = false

    var compact: Bool { item.span == 1 }
}

private struct WidgetContextKey: EnvironmentKey {
    static let defaultValue: WidgetContext? = nil
}

extension EnvironmentValues {
    var widget: WidgetContext? {
        get { self[WidgetContextKey.self] }
        set { self[WidgetContextKey.self] = newValue }
    }
}

// MARK: - Fit

/// Fit: how tall each widget's content wants to be, as the widgets report
/// it (`reportsFit`), per workspace (spaces are app-wide, contents aren't).
/// The column draws a Fit widget at this height, its units the limit.
@MainActor final class WidgetFit: ObservableObject {
    static let shared = WidgetFit()

    struct Key: Hashable {
        var workspace: UUID
        var widget: UUID
    }

    @Published private(set) var heights: [Key: CGFloat] = [:]

    func height(of widget: UUID, in workspace: UUID) -> CGFloat? {
        heights[Key(workspace: workspace, widget: widget)]
    }

    fileprivate func report(_ height: CGFloat, widget: UUID, workspace: UUID) {
        let key = Key(workspace: workspace, widget: widget)
        let h = height.rounded(.up)
        if heights[key] != h { heights[key] = h }
    }
}

extension View {
    /// Tell the column how tall this widget's content wants to be (nil:
    /// can't say yet, say while loading; the last height stands).
    func reportsFit(_ height: CGFloat?, workspace: UUID) -> some View {
        modifier(FitReport(height: height, workspace: workspace))
    }
}

private struct FitReport: ViewModifier {
    let height: CGFloat?
    let workspace: UUID
    @Environment(\.widget) private var widget

    func body(content: Content) -> some View {
        content.onChange(of: height, initial: true) { _, h in
            guard let h, let id = widget?.item.id else { return }
            WidgetFit.shared.report(h, widget: id, workspace: workspace)
        }
    }
}

// MARK: - Shell

/// A widget's surface: the inspector's chrome, at the composer's radius,
/// with a light inner edge, a dark outer hairline and a soft shadow.
struct WidgetShellBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        shape.fill(Theme.Surface.chrome)
            .overlay(shape.strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
            .overlay(shape.stroke(Theme.Widget.outerEdge, lineWidth: 0.5))
            .shadow(color: Theme.Widget.shadow, radius: Theme.Widget.shadowRadius, y: Theme.Widget.shadowY)
    }
}

// MARK: - Header

/// A widget's 40pt header: its glyph and name, and a status at the right.
struct WidgetHeader<Status: View>: View {
    let kind: WidgetKind
    var title: String?
    @ViewBuilder var status: () -> Status
    @Environment(\.widget) private var widget

    var body: some View {
        // The same at every size: Small included.
        HStack(spacing: Theme.Space.s) {
            Image(systemName: kind.symbol)
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(title ?? kind.title)
                .font(.toasty(Theme.Size.control, .medium))
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            if let widget, widget.editing, widget.item.hasOptions {
                // Editing: a click on it opens its options.
                Image(systemName: "slider.horizontal.3")
                    .font(.toasty(Theme.Size.meta, .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has options")
            } else {
                status()
            }
        }
        .padding(.leading, Theme.Widget.edge)
        .padding(.trailing, Theme.Widget.edge)
        .frame(height: WidgetGrid.headerHeight)
    }
}

extension WidgetHeader where Status == EmptyView {
    init(kind: WidgetKind, title: String? = nil) {
        self.init(kind: kind, title: title, status: { EmptyView() })
    }
}

// MARK: - Edge handle

/// The free edge of a two-track widget in edit mode: a grabber, lit while
/// the pointer is on it, dragged to change the height a unit at a time.
struct WidgetEdgeHandle: View {
    /// Top for a bottom-anchored widget (it grows upward).
    let top: Bool
    var showGrabber = true
    let changed: (CGFloat) -> Void
    let ended: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.clear
            if hovering || dragging {
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(height: 1.5)
                    .padding(.horizontal, Theme.Space.l)
            }
            if showGrabber {
                Capsule()
                    .fill(Color.primary.opacity(hovering || dragging ? 0.6 : 0.35))
                    .frame(width: 36, height: 5)
            }
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .widgetCursor(.resizeUpDown, held: dragging)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                dragging = true
                changed(g.translation.height)
            }
            .onEnded { _ in
                dragging = false
                ended()
            })
        .accessibilityLabel("Resize")
    }
}

/// Edit mode's handle for a widget's size, as Apple's: a short rounded
/// stroke just outside its bottom-right corner, on the same continuous curve as
/// the widget's own corner (so the two run together). One drag sets width
/// and height (the widget snaps from size to size).
struct WidgetResizeHandle: View {
    /// Its drag is under way (the widget owns the gesture).
    var dragging = false
    @State private var hovering = false

    /// How far outside the widget's edge the stroke's middle runs, its
    /// width, and the handle's hit area.
    static let gap: CGFloat = 4.5
    static let lineWidth: CGFloat = 4
    static let size: CGFloat = 40

    var body: some View {
        CornerStroke(radius: Theme.Radius.large, gap: Self.gap)
            .stroke(Color.primary.opacity(hovering || dragging ? 0.7 : 0.4),
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
            .frame(width: Self.size, height: Self.size)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .widgetCursor(.frameResize(position: .bottomRight, directions: .all), held: dragging)
            .animation(.easeOut(duration: 0.12), value: hovering || dragging)
            .accessibilityLabel("Resize")
    }

    /// The middle of a bottom-right corner of a continuous rounded
    /// rectangle `gap` outside the widget's (whose corner is this frame's
    /// bottom-right, less `gap`): the widget's own curve, grown by `gap`.
    nonisolated private struct CornerStroke: Shape {
        let radius: CGFloat
        let gap: CGFloat

        func path(in rect: CGRect) -> Path {
            // A rectangle large enough that only its bottom-right corner
            // falls in this frame, its corner `gap` outside the widget's.
            let big: CGFloat = 400
            let outer = CGRect(x: rect.maxX - big, y: rect.maxY - big, width: big, height: big)
            let full = RoundedRectangle(cornerRadius: radius + gap, style: .continuous).path(in: outer)
            // Where along the outline the corner's curve runs: points past
            // the straight edges (a continuous corner reaches about 1.53×
            // its radius along each edge).
            let reach = (radius + gap) * 1.53
            let steps = 1200
            var inCorner: [Double] = []
            for k in 0...steps {
                let f = Double(k) / Double(steps)
                guard let p = full.trimmedPath(from: 0, to: max(f, 0.0001)).currentPoint else { continue }
                if p.x > outer.maxX - reach, p.y > outer.maxY - reach { inCorner.append(f) }
            }
            guard let lo = inCorner.first, let hi = inCorner.last, hi > lo else { return Path() }
            // Its middle: a short stroke centered on the corner.
            let mid = (lo + hi) / 2, half = (hi - lo) * 0.28
            return full.trimmedPath(from: mid - half, to: mid + half)
        }
    }
}

// MARK: - Edit mode marks

/// The remove badge at a widget's top-left corner while editing.
struct WidgetRemoveBadge: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.toasty(Theme.Glyph.small, .bold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.Surface.floating))
                .overlay(Circle().strokeBorder(Theme.Tooltip.innerBorder, lineWidth: 0.5))
                .overlay(Circle().stroke(Theme.Tooltip.outerBorder, lineWidth: 0.5))
                .brightness(hovering ? 0.1 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip("Remove Widget")
        .accessibilityLabel("Remove Widget")
    }
}

/// A dragged edge's target, on the grid: "Medium", or "3 units · 264";
/// for a Fit widget, its limit: "Up to Large".
struct WidgetUnitsLabel: View {
    let span: Int
    let units: Int
    var upTo = false

    private var text: String {
        let size: String
        if span == 1 { size = "Small" }
        else if units == 1 { size = "Slim" }
        else if units == 2 { size = "Medium" }
        else if units == 4 { size = "Large" }
        else { size = "\(units) \(units == 1 ? "unit" : "units") · \(Int(WidgetGrid.height(units)))" }
        return upTo && span == 2 ? "Up to \(size)" : size
    }

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.caption, .medium))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.Surface.floating))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.Tooltip.innerBorder, lineWidth: 0.5))
            .popoverShadow()
    }
}

/// Edit mode's choice for a list widget, on its bottom edge: Fixed (always
/// its size) or Fit (as tall as its content, up to its size).
struct WidgetHeightSwitch: View {
    let fits: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("Fixed", on: !fits, tip: Tooltip(title: "Fixed", detail: "Always this size.")) { set(false) }
            segment("Fit", on: fits, tip: Tooltip(title: "Fit", detail: "Grows with its content, up to this size.")) { set(true) }
        }
        .padding(2)
        .background(Capsule().fill(Theme.Surface.floating))
        .overlay(Capsule().strokeBorder(Theme.Tooltip.innerBorder, lineWidth: 0.5))
        .overlay(Capsule().stroke(Theme.Tooltip.outerBorder, lineWidth: 0.5))
        .popoverShadow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Height")
    }

    private func segment(_ title: String, on: Bool, tip: Tooltip, action: @escaping () -> Void) -> some View {
        Segment(title: title, on: on, action: action).tooltip(tip)
    }

    private struct Segment: View {
        let title: String
        let on: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.toasty(Theme.Size.caption, .medium))
                    .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 9)
                    .frame(height: 18)
                    .background(Capsule().fill(on ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Color.clear))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

/// The room a Fit widget may grow into, below what it shows now: its
/// limit, dashed (edit mode).
struct WidgetLimitOutline: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        shape.fill(Theme.Surface.chrome.opacity(0.35))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

extension View {
    /// This cursor while the pointer is over the view, or while `held`
    /// (its drag under way); the arrow again when it leaves. Set, never
    /// pushed: a missed exit can't leave it stuck.
    func widgetCursor(_ cursor: NSCursor, held: Bool = false) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: cursor.set()
            case .ended: if !held { NSCursor.arrow.set() }
            }
        }
        .onChange(of: held) { _, on in if on { cursor.set() } }
    }
}
