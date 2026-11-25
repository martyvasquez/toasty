import AppKit
import SwiftUI

/// The terminal: not a widget, but over every space, fixed to the bottom
/// of the widget column and as wide as its grid. Open, it's as tall as the
/// user drags its top edge (the same in every space), always leaving a
/// widget header's worth of room above it; collapsed, it's a 40pt round
/// button in the column's bottom-right corner.
/// Its top edge is the bottom of the widgets' room: they pack up, then
/// scroll above it, when they don't fit, following its edge live as it's
/// dragged. Spaces slide under it and it stays put. While editing widgets
/// it's collapsed.
struct TerminalDock: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    /// Height the column has for it.
    let room: CGFloat
    /// The height when a drag of its edge began.
    @State private var dragFrom: CGFloat?

    private var open: Bool { workspace.terminalOpen && !store.editingWidgets }

    /// Its height in a column with `room`: the user's, within its minimum
    /// and what leaves a widget header showing above it.
    static func height(open: Bool, wanted: CGFloat, room: CGFloat) -> CGFloat {
        guard open else { return WidgetGrid.headerHeight }
        let most = max(WidgetGrid.headerHeight, room - WidgetGrid.headerHeight - WidgetGrid.gap)
        return min(max(wanted, WorkspaceStore.terminalMinHeight), most)
    }

    /// Opening and closing: the round button grows into the panel from
    /// the corner (and back), on the curve the app's rows open with
    /// (Things': snappy, then soft), a little longer for the distance.
    static let morph = Animation.timingCurve(0.25, 1, 0.5, 1, duration: 0.34)

    var body: some View {
        let height = Self.height(open: open, wanted: store.terminalHeight, room: room)
        // The panel's own size, open: what's inside is laid out at it the
        // whole way, so the shell never reflows while the shape grows.
        let full = Self.height(open: true, wanted: store.terminalHeight, room: room)
        let circle = WidgetGrid.headerHeight
        let shape = RoundedRectangle(cornerRadius: open ? Theme.Radius.large : circle / 2, style: .continuous)
        ZStack(alignment: .topTrailing) {
            if open {
                panel
                    .frame(width: WidgetGrid.width, height: full)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            } else {
                TerminalDockButton(count: workspace.terminals.count, show: show)
                    .frame(width: circle, height: circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .frame(width: open ? WidgetGrid.width : circle, height: height, alignment: .topTrailing)
        .clipShape(shape)
        .background {
            shape.fill(Theme.Surface.chrome)
                .overlay(shape.strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
                .overlay(shape.stroke(Theme.Widget.outerEdge, lineWidth: 0.5))
                .shadow(color: Theme.Widget.shadow, radius: Theme.Widget.shadowRadius, y: Theme.Widget.shadowY)
                // Open, it floats over the widgets: a shadow cast upward too.
                .shadow(color: Theme.Widget.shadow.opacity(open ? 1 : 0), radius: 14, y: -2)
        }
        .overlay(alignment: .top) {
            if open {
                WidgetEdgeHandle(top: true, showGrabber: false, changed: drag, ended: endDrag)
                    .offset(y: -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: height, alignment: .bottom)
        .animation(Self.morph, value: open)
        .onChange(of: workspace.terminalOpen) { _, on in if on { workspace.ensureTerminal() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TerminalTabBar(workspace: workspace)
                    .padding(.leading, -TitlebarRow.edge + Theme.Space.s)
                toggle
            }
            .frame(height: WidgetGrid.headerHeight)
            if let session = workspace.selectedTerminal {
                ZStack {
                    TerminalBackdrop()
                    TerminalHost(session: session).padding(.vertical, Theme.Space.xs)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding([.horizontal, .bottom], Theme.Widget.rowInset)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var toggle: some View {
        BarIconButton(symbol: "chevron.down",
                      tooltip: Tooltip(title: "Collapse Terminal", shortcut: "⌃⌘T",
                                       detail: "Back to its button in the corner. Its shells keep running."),
                      size: CGSize(width: 32, height: TabStyle.height)) {
            workspace.hideTerminal()
        }
        .padding(.trailing, Theme.Space.xs)
    }

    private func show() {
        if store.editingWidgets { store.endEditingWidgets() }
        workspace.showTerminal()
        AppDelegate.shared.windowController?.focusTerminal()
    }

    // Its top edge, dragged: the widgets above follow it live.
    private func drag(_ dy: CGFloat) {
        let from = dragFrom ?? Self.height(open: true, wanted: store.terminalHeight, room: room)
        if dragFrom == nil { dragFrom = from }
        let most = room - WidgetGrid.headerHeight - WidgetGrid.gap
        store.terminalHeight = min(max(from - dy, WorkspaceStore.terminalMinHeight), most)
    }

    private func endDrag() {
        dragFrom = nil
        store.setNeedsSave()
    }
}

/// The collapsed terminal's glyph: the dock draws the round shape it's in.
private struct TerminalDockButton: View {
    let count: Int
    let show: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: show) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: WidgetGrid.headerHeight, height: WidgetGrid.headerHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .tooltip(Tooltip(title: "Open Terminal", shortcut: "⌃⌘T",
                         detail: count > 1 ? "\(count) shells, over the widgets at the height you gave it."
                                           : "Over the widgets, at the height you gave it."))
        .accessibilityLabel("Open Terminal")
    }
}
