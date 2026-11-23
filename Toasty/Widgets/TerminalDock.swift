import AppKit
import SwiftUI

/// The terminal: not a widget, but over every space, fixed to the bottom
/// of the widget column and as wide as its grid. Open, it's as tall as the
/// user drags its top edge (the same in every space), always leaving a
/// widget header's worth of room above it; collapsed, it's its 40pt strip.
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

    var body: some View {
        let height = Self.height(open: open, wanted: store.terminalHeight, room: room)
        VStack(spacing: 0) {
            header
            if open, let session = workspace.selectedTerminal {
                ZStack {
                    TerminalBackdrop()
                    TerminalHost(session: session).padding(.vertical, Theme.Space.xs)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding([.horizontal, .bottom], Theme.Widget.rowInset)
                .transition(.opacity)
            }
        }
        .frame(height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .background(WidgetShellBackground())
        // It floats over the widgets: a shadow cast upward over them too.
        .shadow(color: Theme.Widget.shadow, radius: 14, y: -2)
        .overlay(alignment: .top) {
            if open {
                WidgetEdgeHandle(top: true, showGrabber: false, changed: drag, ended: endDrag)
                    .offset(y: -6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: open)
        .onChange(of: workspace.terminalOpen) { _, on in if on { workspace.ensureTerminal() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal")
    }

    @ViewBuilder private var header: some View {
        if open {
            HStack(spacing: 0) {
                TerminalTabBar(workspace: workspace)
                    .padding(.leading, -TitlebarRow.edge + Theme.Space.s)
                toggle
            }
            .frame(height: WidgetGrid.headerHeight)
        } else {
            // Collapsed: the strip; clicked anywhere, it opens.
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "terminal")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(workspace.selectedTerminal.map(workspace.terminalLabel) ?? "Terminal")
                    .font(.toasty(Theme.Size.control, .medium))
                    .lineLimit(1)
                if workspace.terminals.count > 1 {
                    Text("· \(workspace.terminals.count) sessions")
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.xs)
                toggle
            }
            .padding(.leading, Theme.Widget.edge)
            .frame(height: WidgetGrid.headerHeight)
            .contentShape(Rectangle())
            .onTapGesture { show() }
        }
    }

    private var toggle: some View {
        BarIconButton(symbol: open ? "chevron.down" : "chevron.up",
                      tooltip: Tooltip(title: open ? "Collapse Terminal" : "Open Terminal", shortcut: "⌃⌘T",
                                       detail: open ? "Its tab strip stays at the bottom." : "Over the widgets, at the height you gave it."),
                      size: CGSize(width: 32, height: TabStyle.height)) {
            if open { workspace.hideTerminal() } else { show() }
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
