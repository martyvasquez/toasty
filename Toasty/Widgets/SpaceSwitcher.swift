import AppKit
import SwiftUI

/// Over the widget column, centered: a dot per space (as the Home Screen's
/// pages, no names), the current one bright. A dot goes to its space; so
/// does a swipe over the widgets.
struct SpaceDots: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace

    var body: some View {
        let current = store.space(for: workspace)?.id
        Group {
            // One space: no dots, as one page has none.
            if store.spaces.count > 1 {
                HStack(spacing: 0) {
                    ForEach(Array(store.spaces.enumerated()), id: \.element.id) { i, space in
                        Button { workspace.selectSpace(space.id) } label: {
                            Circle()
                                .fill(Color.primary.opacity(space.id == current ? 0.85 : 0.25))
                                .frame(width: 7, height: 7)
                                .frame(width: 14, height: TabStyle.height)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tooltip(Tooltip(title: "Space \(i + 1)", shortcut: i < 9 ? "⌃⌘\(i + 1)" : nil,
                                         detail: "Swipe sideways over the widgets to move between spaces."))
                        .accessibilityLabel("Space \(i + 1)")
                        .accessibilityAddTraits(space.id == current ? [.isSelected] : [])
                    }
                }
            }
        }
    }
}

/// The widget column's top-right corner: into edit mode.
struct EditWidgetsButton: View {
    var body: some View {
        BarIconButton(symbol: "square.grid.2x2",
                      tooltip: Tooltip(title: "Edit Widgets", shortcut: "⌥⌘E",
                                       detail: "Add, move and resize widgets, and add or reorder spaces."),
                      glyphSize: Theme.Size.body,
                      size: CGSize(width: 32, height: TabStyle.height)) {
            AppDelegate.shared.windowController?.editWidgets(nil)
        }
    }
}

/// A space in miniature: its widgets as gray blocks on the column.
struct SpaceThumbnail: View {
    let space: WidgetSpace
    var width: CGFloat = 44

    var body: some View {
        let height = width * WidgetGrid.height(WidgetGrid.rows) / WidgetGrid.width
        let layout = WidgetLayout(space: space)
        let sx = width / WidgetGrid.width, sy = height / WidgetGrid.height(WidgetGrid.rows)
        ZStack(alignment: .topLeading) {
            ForEach(layout.slots) { slot in
                let item = slot.item
                RoundedRectangle(cornerRadius: max(1, width / 18), style: .continuous)
                    .fill(Color.primary.opacity(0.32))
                    .frame(width: max(1.5, WidgetGrid.width(span: item.span) * sx - 0.75),
                           height: max(1.5, (slot.headerOnly ? WidgetGrid.headerHeight : WidgetGrid.height(slot.units)) * sy - 0.75))
                    .offset(x: WidgetGrid.x(track: item.span == 2 ? 0 : item.track) * sx,
                            y: WidgetGrid.y(slot.top) * sy)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

// MARK: - Edit mode's titlebar

/// While editing: every space as a small thumbnail, the current one
/// outlined; click one to go to it, drag one sideways to reorder; + adds
/// an empty space; Done ends editing (spaces left empty go then).
struct SpaceEditBar: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace

    /// A thumbnail's slot in the strip.
    static let thumbWidth: CGFloat = 26

    var body: some View {
        let current = store.space(for: workspace)?.id
        HStack(spacing: TabStyle.gap) {
            FittingTabStrip(items: store.spaces, selectedID: current,
                            minWidth: Self.thumbWidth, maxWidth: Self.thumbWidth,
                            pick: { if $0.id != current { workspace.selectSpace($0.id) } },
                            move: { store.moveSpace($0, to: $1) }) { space in
                SpaceThumbTab(space: space, index: store.spaces.firstIndex { $0.id == space.id } ?? 0,
                              selected: space.id == current) { workspace.selectSpace(space.id) }
            } trailing: {
                NewTabButton(tooltip: Tooltip(title: "New Space", detail: "An empty space, to add widgets to.")) { store.newSpace() }
            }
            Button("Done") { store.endEditingWidgets() }
                .buttonStyle(WidgetButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .layoutPriority(1)
        }
    }
}

private struct SpaceThumbTab: View {
    let space: WidgetSpace
    let index: Int
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        SpaceThumbnail(space: space, width: 12)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(shape.fill(selected ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Theme.Fill.faint))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Theme.Stroke.border, lineWidth: selected ? 1.5 : 0.5))
            .frame(width: SpaceEditBar.thumbWidth, height: TabStyle.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: select)
            .tooltip(Tooltip(title: "Space \(index + 1)",
                             detail: space.widgets.isEmpty ? "Empty: it goes when you press Done." : "Drag sideways to reorder."))
            .accessibilityLabel("Space \(index + 1)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
