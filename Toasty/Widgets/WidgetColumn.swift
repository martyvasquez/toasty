import AppKit
import SwiftUI

/// The Add Widget gallery's choice, shared with the column (which shows
/// where it will go).
@MainActor final class WidgetGalleryModel: ObservableObject {
    static let shared = WidgetGalleryModel()
    @Published var kind: WidgetKind = .git
    @Published var preset: WidgetPreset = .medium
    /// Where it goes, when dragged somewhere other than the first free place.
    @Published var placed: WidgetItem?

    /// Where the new widget goes on `layout`, nil when there's no room.
    func target(in layout: WidgetLayout) -> WidgetItem? {
        if let placed, placed.kind == kind, placed.preset == effectivePreset,
           layout.moving(placed, toTop: placed.row, track: placed.track) != nil {
            return placed
        }
        return layout.placement(for: kind, preset: effectivePreset)
    }

    var effectivePreset: WidgetPreset {
        if kind.presets.contains(preset) { return preset }
        return kind.presets.contains(.medium) ? .medium : kind.presets[0]
    }

    func open(kind: WidgetKind? = nil) {
        if let kind { self.kind = kind }
        placed = nil
        WorkspaceStore.shared.editingWidgets = true
        WorkspaceStore.shared.galleryOpen = true
    }
}

// MARK: - Column

/// The right side of the window: the active workspace's space of widgets,
/// floating on the page in a fixed 356pt column on the widget grid, and
/// over every space, fixed to the bottom, the terminal.
struct WidgetColumnView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout

    var body: some View {
        GeometryReader { geo in
            // 12pt under the tab row (not the titlebar's safe area, which
            // runs deeper), 12pt over the window's bottom.
            let bar = layout.buttonsMidY > 0 ? layout.buttonsMidY * 2 : 52
            let room = geo.size.height - bar - WidgetGrid.margin * 2
            ZStack(alignment: .topLeading) {
                if let w = store.active {
                    ColumnContent(store: store, workspace: w, room: room)
                }
            }
            .padding(.top, bar)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .background(Color.claudeBackground.ignoresSafeArea())
    }
}

/// The active workspace's widgets and, over them, its terminal. (Its own
/// view, so the terminal opening or closing, which is the workspace's,
/// resizes the widgets' room.)
private struct ColumnContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    let room: CGFloat
    @ObservedObject private var terminals = TerminalLayoutSettings.shared

    var body: some View {
        // The widgets' room: down to the terminal's top edge, following it
        // live as it's dragged (the whole column with it turned off).
        let open = workspace.terminalOpen && !store.editingWidgets
        let shown = terminals.sidebarTerminal
        let dock = shown ? TerminalDock.height(open: open, wanted: store.terminalHeight, room: room) : 0
        ZStack(alignment: .topLeading) {
            WorkspaceWidgets(store: store, workspace: workspace,
                             // Down to the terminal's top edge: the content's own
                             // 12pt margin is the gap above it, the grid's gap.
                             visible: max(0, room - dock) + WidgetGrid.margin)
            if shown {
                TerminalDock(store: store, workspace: workspace, room: room)
                    .frame(width: WidgetGrid.width)
                    .padding(WidgetGrid.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        // Opening or collapsing it: the widgets move along with it.
        .animation(.easeOut(duration: 0.2), value: open)
    }
}

/// A swipe between spaces as the system tracks it.
@MainActor final class SpaceSwipe: ObservableObject {
    static let shared = SpaceSwipe()
    /// −1…1: how far the column has followed the fingers; positive
    /// toward the previous space (fingers moving right), negative toward
    /// the next.
    @Published var amount: CGFloat = 0
    /// The last switch was a swipe landing: the column is already there,
    /// so it doesn't slide again.
    var landed = false
}

private struct WorkspaceWidgets: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    /// Height the widgets have, from the column's top to just above the
    /// terminal (with the top margin).
    let visible: CGFloat
    @ObservedObject private var swipe = SpaceSwipe.shared
    /// A switch by dots, menu or keys: the space it left, sliding out the
    /// way the switch went (+1: toward the next), and how far along.
    @State private var leaving: UUID?
    @State private var direction: CGFloat = 1
    @State private var slide: CGFloat = 0

    /// One column's width: the distance a space slides.
    private var page: CGFloat { WidgetGrid.width + WidgetGrid.margin * 2 }

    var body: some View {
        let index = store.spaceIndex(for: workspace)
        let current = store.space(for: workspace)
        ZStack(alignment: .topLeading) {
            if let current {
                grid(current, live: true)
                    .offset(x: (swipe.amount + slide * direction) * page)
            }
            // The space being swiped toward.
            if swipe.amount != 0 {
                let n = index + (swipe.amount > 0 ? -1 : 1)
                if store.spaces.indices.contains(n) {
                    grid(store.spaces[n], live: false)
                        .offset(x: (swipe.amount + (swipe.amount > 0 ? -1 : 1)) * page)
                }
            }
            // The space a switch left, sliding out.
            if let leaving, let old = store.spaces.first(where: { $0.id == leaving }) {
                grid(old, live: false)
                    .offset(x: (slide - 1) * direction * page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: current?.id) { old, new in
            guard let old, let new, old != new else { return }
            if swipe.landed { swipe.landed = false; return }
            let from = store.spaces.firstIndex { $0.id == old } ?? 0
            let to = store.spaces.firstIndex { $0.id == new } ?? 0
            direction = to >= from ? 1 : -1
            leaving = old
            slide = 1
            withAnimation(.easeInOut(duration: 0.28)) { slide = 0 } completion: { leaving = nil }
        }
        // Only this workspace's: another workspace's switch isn't animated.
        .id(workspace.id)
    }

    /// A space's grid, scrolling when it's taller than the room above the
    /// terminal; only the shown one takes clicks.
    private func grid(_ space: WidgetSpace, live: Bool) -> some View {
        let fit = visible - WidgetGrid.margin * 2
        let content = SpaceGrid.drawn(space, fit: fit, store: store).height + WidgetGrid.margin * 2
        return ScrollView(.vertical) {
            SpaceGrid(store: store, workspace: workspace, space: space, fit: fit)
                .padding(WidgetGrid.margin)
        }
        .scrollDisabled(content <= visible + 0.5)
        .scrollIndicators(.automatic)
        .allowsHitTesting(live)
        .id(space.id)
        .frame(width: page, height: max(0, visible), alignment: .top)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - A space on the grid

struct SpaceGrid: View {
    /// Where the widgets are drawn in `fit` points: each widget's top
    /// (packed, `WidgetLayout.packedTops`; as saved while editing), and the
    /// height they take (the whole grid while editing).
    @MainActor static func drawn(_ space: WidgetSpace, fit: CGFloat, store: WorkspaceStore) -> (tops: [UUID: CGFloat], height: CGFloat) {
        let layout = WidgetLayout(space: space)
        if store.editingWidgets {
            return (Dictionary(uniqueKeysWithValues: layout.slots.map { ($0.id, WidgetGrid.y($0.top)) }), WidgetGrid.height(WidgetGrid.rows))
        }
        if space.widgets.isEmpty { return ([:], WidgetGrid.height(3)) }
        return layout.packedTops(toFit: fit)
    }

    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    let space: WidgetSpace
    /// Points the room above the terminal holds.
    let fit: CGFloat
    @ObservedObject private var gallery = WidgetGalleryModel.shared
    /// A drag under way (`WidgetDragPreview`): the space as it would leave
    /// it, drawn live, and the widget being moved (its own place shows as
    /// free, as any other place it could go).
    @State private var drag: WidgetDragPreview?

    var body: some View {
        // Edits start from what's saved; what's drawn is the preview while
        // a widget is being resized.
        let saved = WidgetLayout(space: space)
        let shown = drag.map { d in
            var s = space
            s.widgets = d.widgets
            return s
        } ?? space
        let layout = WidgetLayout(space: shown)
        let drawn = Self.drawn(shown, fit: fit, store: store)
        let editing = store.editingWidgets
        ZStack(alignment: .topLeading) {
            // The canvas: Control-click for the column's menu.
            Color.clear
                .contentShape(Rectangle())
                .contextMenu { ColumnMenu(store: store) }
            if editing {
                FreeCells(layout: layout, excluding: drag?.moving)
                    .allowsHitTesting(false)
                if !store.galleryOpen, drag == nil, let block = layout.largestFreeBlock() {
                    AddWidgetButton()
                        .frame(width: WidgetGrid.width(span: block.tracks.count), height: WidgetGrid.height(block.units))
                        .offset(x: WidgetGrid.x(track: block.tracks.lowerBound), y: WidgetGrid.y(block.top))
                }
            }
            // An empty space outside edit mode (the only one): the same
            // Add Widget, which opens edit mode and the gallery.
            if space.widgets.isEmpty, !editing, !store.galleryOpen {
                AddWidgetButton()
                    .frame(width: WidgetGrid.width, height: WidgetGrid.height(3))
            }
            ForEach(layout.slots) { slot in
                WidgetSlotView(store: store, workspace: workspace, spaceID: space.id, slot: slot, layout: saved,
                               y: drawn.tops[slot.id] ?? WidgetGrid.y(slot.top))
            }
            if store.galleryOpen, let target = gallery.target(in: saved) {
                GalleryGhost(item: target, layout: saved)
            }
        }
        // At least the room above the terminal, so the empty column under
        // the last widget takes a right-click too.
        .frame(width: WidgetGrid.width, height: max(drawn.height, fit), alignment: .topLeading)
        .animation(Theme.Widget.settle, value: space.widgets)
        // The resized widget snaps from size to size, and the others make
        // room, with a spring.
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: drag)
        .onPreferenceChange(WidgetDragPreviewKey.self) { drag = $0 }
        .animation(.easeOut(duration: 0.15), value: editing)
    }
}

/// Free units while editing: one dashed cell per unit and track.
private struct FreeCells: View {
    let layout: WidgetLayout
    var excluding: UUID?

    var body: some View {
        let free = layout.freeCells(excluding: excluding)
        ZStack(alignment: .topLeading) {
            ForEach(Array(free).sorted { ($0.row, $0.track) < ($1.row, $1.track) }, id: \.self) { cell in
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Widget.cellFill)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.Widget.cellStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: WidgetGrid.track, height: WidgetGrid.unit)
                    .offset(x: WidgetGrid.x(track: cell.track), y: WidgetGrid.y(cell.row))
            }
        }
        .transition(.opacity)
    }
}

private struct AddWidgetButton: View {
    @State private var hovering = false

    var body: some View {
        Button { WidgetGalleryModel.shared.open() } label: {
            HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                Image(systemName: "plus").font(.toasty(Theme.Size.meta, .medium))
                Text("Add Widget").font(.toasty(Theme.Size.control, .medium))
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Add Widget")
    }
}

/// Where the gallery's widget will go: a blue ghost the size of its
/// preset, dragged to place it elsewhere.
private struct GalleryGhost: View {
    let item: WidgetItem
    let layout: WidgetLayout
    @State private var drag: CGSize = .zero

    var body: some View {
        let top = item.row
        let w = WidgetGrid.width(span: item.span), h = WidgetGrid.height(item.units)
        let x = WidgetGrid.x(track: item.span == 2 ? 0 : item.track), y = WidgetGrid.y(top)
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Widget.ghost)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Widget.ghostStroke, lineWidth: 1))
            .overlay {
                Text(item.preset?.title ?? "")
                    .font(.toasty(Theme.Size.control, .medium))
                    .foregroundStyle(Theme.headingBlue)
            }
            .frame(width: w, height: h)
            .offset(x: x + drag.width, y: y + drag.height)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { drag = $0.translation }
                .onEnded { g in
                    let newTop = Int(((y + g.translation.height) / (WidgetGrid.unit + WidgetGrid.gap)).rounded())
                    let newTrack = (x + g.translation.width) > WidgetGrid.track / 2 ? 1 : 0
                    if let moved = layout.moving(item, toTop: newTop, track: newTrack) {
                        WidgetGalleryModel.shared.placed = moved
                    }
                    withAnimation(Theme.Widget.settle) { drag = .zero }
                })
            .transition(.opacity)
    }
}

// MARK: - One widget

/// A drag under way in edit mode, as a widget reports it to its grid: the
/// space as the drag would leave it (drawn live), and the widget being
/// moved, if one is. (A preference, so it's gone the moment the drag ends
/// or is cancelled: nothing can be left behind.)
struct WidgetDragPreview: Equatable {
    var widgets: [WidgetItem]
    var moving: UUID?
}

struct WidgetDragPreviewKey: PreferenceKey {
    static let defaultValue: WidgetDragPreview? = nil
    static func reduce(value: inout WidgetDragPreview?, nextValue: () -> WidgetDragPreview?) {
        value = value ?? nextValue()
    }
}

private struct WidgetSlotView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    let spaceID: UUID
    /// Where it's drawn (during a drag, where the drag would leave it).
    let slot: WidgetSlot
    /// The space as saved: edits start from it.
    let layout: WidgetLayout
    /// Its top as drawn (packed above the terminal).
    let y: CGFloat

    /// The drags under way: they reset themselves when the drag ends or is
    /// cancelled.
    @GestureState private var resizeBy: CGSize?
    @GestureState private var moveBy: CGSize?
    /// The last place a move could go (kept while the pointer passes over
    /// a spot it can't).
    @State private var moveList: [WidgetItem]?
    /// The size a resize has snapped to so far: it stays until the pointer
    /// is clearly past the next threshold (so it can't flicker on one).
    @State private var snapped: Snap?
    /// The resize is pressing past a limit (for the trackpad's bump).
    @State private var atLimit = false
    /// The space as the resize shows it now: what's kept when it's let go.
    @State private var resizeList: [WidgetItem]?

    private struct Snap: Equatable {
        var wide: Bool
        var units: Int
    }

    private var item: WidgetItem { slot.item }
    /// As saved: what a drag measures from.
    private var saved: WidgetItem { layout.widgets.first { $0.id == slot.id } ?? slot.item }
    private var editing: Bool { store.editingWidgets }

    var body: some View {
        let height = slot.headerOnly ? WidgetGrid.headerHeight : WidgetGrid.height(slot.units)
        let x = WidgetGrid.x(track: item.span == 2 ? 0 : item.track)
        // Moving: it's drawn from where it was, under the pointer; the
        // outline is where it lands.
        let movingFrom = moveBy.map { by in
            CGPoint(x: WidgetGrid.x(track: saved.span == 2 ? 0 : saved.track) + by.width, y: WidgetGrid.y(saved.row) + by.height)
        }

        return ZStack(alignment: .topLeading) {
            if movingFrom != nil {
                outline(width: WidgetGrid.width(span: item.span), height: height)
                    .offset(x: x, y: y)
            }
            // At a limit, it gives a little past it with the pointer (and
            // springs back when let go).
            let give = resizeBy.map(stretch) ?? .zero
            shell(width: WidgetGrid.width(span: item.span) + give.width, height: height + give.height)
                .animation(.spring(response: 0.32, dampingFraction: 0.72), value: resizeBy == nil)
                .overlay(alignment: .bottomTrailing) {
                    if resizeBy != nil {
                        WidgetUnitsLabel(span: item.span, units: item.units).padding(Theme.Space.s)
                    }
                }
                .offset(x: movingFrom?.x ?? x, y: movingFrom?.y ?? y)
                // Dragged, it stays exactly under the pointer (the others'
                // springs don't carry it).
                // Resized, it snaps from size to size crisply (a spring
                // would blend two layouts); the others spring to make room.
                .transaction { if movingFrom != nil || resizeBy != nil { $0.animation = nil } }
                .zIndex(movingFrom != nil || resizeBy != nil ? 1 : 0)
        }
        .preference(key: WidgetDragPreviewKey.self, value: dragPreview)
        .onChange(of: moveBy == nil) { _, ended in if ended { moveList = nil } }
        .onChange(of: resizeBy == nil) { _, ended in if ended { snapped = nil; atLimit = false } }
    }

    /// What this widget's drag shows the grid, if one is under way.
    private var dragPreview: WidgetDragPreview? {
        if let resizeBy, let list = resizeList ?? resized(resizeBy) { return WidgetDragPreview(widgets: list) }
        if moveBy != nil { return WidgetDragPreview(widgets: moveList ?? layout.widgets, moving: slot.id) }
        return nil
    }

    private func shell(width: CGFloat, height: CGFloat) -> some View {
        WidgetContent(workspace: workspace, item: item, units: item.units, headerOnly: slot.headerOnly)
            .environment(\.widget, WidgetContext(item: item, units: item.units, editing: editing))
            // A new size's layout comes in at once: only the shell springs
            // (a fade would show both layouts at once).
            .transaction { $0.animation = nil }
            .frame(width: width, height: height, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .background(WidgetShellBackground())
            .overlay {
                if editing {
                    // Editing: the widget is moved, not used.
                    Color.clear.contentShape(Rectangle())
                        .widgetCursor(moveBy != nil ? .closedHand : .openHand, held: moveBy != nil)
                        .gesture(moveGesture)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Apple's corner handle: width and height in one drag.
                if editing, !slot.headerOnly {
                    WidgetResizeHandle(dragging: resizeBy != nil)
                        .gesture(resizeGesture)
                        .offset(x: WidgetResizeHandle.gap, y: WidgetResizeHandle.gap)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    WidgetRemoveBadge { remove() }
                        .offset(x: -6, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // Using: only the way into edit mode. Editing: everything.
            .contextMenu {
                if editing {
                    widgetMenu
                } else {
                    Button("Edit Widgets…") { store.editingWidgets = true }
                }
            }
    }

    @ViewBuilder private var widgetMenu: some View {
        ForEach(item.kind.presets) { p in
            Button(p.title) { apply(layout.applyingPreset(p, to: item.id), animation: Theme.Widget.crossfade) }
                .disabled(!layout.allows(p, for: item.id) || (item.preset == p && !item.collapsed))
        }
        Button(item.collapsed ? "Expand" : "Collapse") { apply(layout.togglingCollapse(item.id), animation: Theme.Widget.settle) }
        Divider()
        Button("Remove Widget") { remove() }
        Divider()
        ColumnMenu(store: store)
    }

    private func apply(_ widgets: [WidgetItem]?, animation: Animation) {
        guard let widgets else { NSSound.beep(); return }
        withAnimation(animation) { store.setWidgets(widgets, in: spaceID) }
    }

    private func remove() {
        withAnimation(Theme.Widget.settle) {
            store.setWidgets(layout.widgets.filter { $0.id != item.id }, in: spaceID)
        }
    }

    // MARK: Resizing

    /// The corner handle dragged: the widget snaps from size to size and
    /// the ones below make room, live; let go, it stays as shown.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($resizeBy) { v, state, _ in state = v.translation }
            .onChanged { v in
                let before = snapped
                if before == nil { resizeList = nil }  // (a new drag)
                defer { if let list = resized(v.translation) { resizeList = list } }
                snapped = snap(v.translation)
                // A tick on each new size; a firmer one on reaching a limit.
                let limited = stretch(v.translation) != .zero
                if limited, !atLimit {
                    Haptics.limit()
                } else if let before, let now = snapped, before != now, !limited {
                    Haptics.snap()
                }
                atLimit = limited
            }
            .onEnded { v in
                // Exactly what was on screen (worked out again now, the
                // size it had snapped to may already be forgotten).
                guard let list = resizeList ?? resized(v.translation) else { return }
                resizeList = nil
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { store.setWidgets(list, in: spaceID) }
            }
    }

    /// The space with the widget at the size the drag reaches: width first
    /// (one track, a Small, or two: past halfway into the other track;
    /// a Small in the right track widens leftward), then, two tracks wide,
    /// height to the nearest unit. A Small doesn't grow taller. Nil when
    /// no size fits (it stays as it was).
    private func resized(_ by: CGSize) -> [WidgetItem]? {
        let w0 = saved
        let s = snapped ?? snap(by)
        if !s.wide {
            // A wide one narrowed lands in the left track.
            return layout.resizing(w0.id, span: 1, track: w0.span == 1 ? w0.track : 0, units: 2)
        }
        return layout.resizing(w0.id, span: 2, track: 0, units: s.units)
    }

    /// The size the pointer has reached, keeping the size it's at until
    /// it's `slack` past the threshold to the next.
    private func snap(_ by: CGSize) -> Snap {
        let w0 = saved
        let slack: CGFloat = 20
        let before = snapped ?? Snap(wide: w0.span == 2, units: w0.span == 2 ? w0.units : 2)
        // Width: past halfway into the other track (a Small in the right
        // track widens leftward).
        let sideways = (w0.span == 1 && w0.track == 1) ? -by.width : by.width
        let edge = WidgetGrid.width(span: w0.span) + sideways
        let halfway = WidgetGrid.track + (WidgetGrid.width - WidgetGrid.track) / 2
        let wide = before.wide ? edge > halfway - slack : edge > halfway + slack
        guard wide else { return Snap(wide: false, units: 2) }
        // Height, once two tracks wide (a Small widened goes on to grow
        // down): the nearest unit, held until clearly past.
        let start = w0.span == 1 ? 2 : w0.units
        let h = WidgetGrid.height(start) + by.height
        let step = WidgetGrid.unit + WidgetGrid.gap
        var units = before.wide ? before.units : 2
        let current = WidgetGrid.height(units)
        if h > current + step / 2 + slack || h < current - step / 2 - slack {
            units = max(1, Int(((h + WidgetGrid.gap) / step).rounded()))
        }
        return Snap(wide: true, units: units)
    }

    /// How far past a limit the pointer has the widget, with resistance (as
    /// a list rubber-bands past its end). Only where it can't follow: wider
    /// than two tracks, narrower than one, wider when there's no room to
    /// widen, taller than there's room (or its kind allows), shorter than
    /// its smallest. Measured from its edge, so it starts from nothing.
    private func stretch(_ by: CGSize) -> CGSize {
        let w0 = saved
        guard let now = resized(by)?.first(where: { $0.id == w0.id }) else { return .zero }
        func give(_ d: CGFloat) -> CGFloat {
            // Apple's rubber band: it gives less the further it's pulled.
            let reach: CGFloat = 120
            return (1 - 1 / (abs(d) * 0.55 / reach + 1)) * reach * (d < 0 ? -1 : 1)
        }
        var out = CGSize.zero
        // Width (not for a Small in the right track, which grows leftward).
        if !(w0.span == 1 && w0.track == 1) {
            let edge = WidgetGrid.width(span: w0.span) + by.width
            let width = WidgetGrid.width(span: now.span)
            if now.span == 2, edge > width { out.width = give(edge - width) }
            if now.span == 1, edge < width { out.width = give(edge - width) }
            if now.span == 1, edge > width, layout.resizing(w0.id, span: 2, track: 0, units: 2) == nil {
                out.width = give(edge - width)
            }
        }
        // Height, two tracks wide.
        if now.span == 2 {
            let h = WidgetGrid.height(w0.span == 1 ? 2 : w0.units) + by.height
            let height = WidgetGrid.height(now.units)
            let grown = layout.resizing(w0.id, span: 2, track: 0, units: now.units + 1)?.first { $0.id == w0.id }?.units ?? now.units
            if h > height, grown <= now.units { out.height = give(h - height) }
            if h < height, now.units <= now.kind.minUnits { out.height = give(h - height) }
        }
        return out
    }

    // MARK: Moving

    /// The widget follows the pointer; where it's dropped it goes, and the
    /// widgets it lands on make room (live, as it's dragged). Back over its
    /// own place, nothing changes.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($moveBy) { v, state, _ in state = v.translation }
            .onChanged { v in
                if let list = moved(v.translation), list != moveList { moveList = list }
            }
            .onEnded { v in
                let list = moved(v.translation) ?? moveList
                withAnimation(Theme.Widget.settle) {
                    if let list { store.setWidgets(list, in: spaceID) }
                }
            }
    }

    /// The space with the widget dropped where the pointer has it.
    private func moved(_ by: CGSize) -> [WidgetItem]? {
        let w0 = saved
        let top = Int(((WidgetGrid.y(w0.row) + by.height) / (WidgetGrid.unit + WidgetGrid.gap)).rounded())
        let x = WidgetGrid.x(track: w0.span == 2 ? 0 : w0.track) + by.width
        let track = x > (WidgetGrid.track + WidgetGrid.gap) / 2 ? 1 : 0
        return layout.placing(w0.id, atTop: top, track: track)
    }

    /// Where a moved widget will land.
    private func outline(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Widget.ghost)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Widget.ghostStroke, lineWidth: 1))
            .frame(width: width, height: height)
    }
}

/// The column's menu (Control-click): edit, add, spaces, hide.
struct ColumnMenu: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Button(store.editingWidgets ? "Done Editing" : "Edit Widgets…") {
            if store.editingWidgets { store.endEditingWidgets() } else { store.editingWidgets = true }
        }
        Button("Add Widget…") { WidgetGalleryModel.shared.open() }
        Button("New Space") { store.newSpace() }
        Divider()
        Button("Hide Widgets") { store.active?.setWidgets(visible: false) }
    }
}

// MARK: - Buttons inside widgets

/// A widget's secondary button: a quiet filled rounded rectangle.
struct WidgetButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        WidgetButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct WidgetButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            configuration.label
                .font(.toasty(Theme.Size.control, .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .frame(height: Theme.Control.height)
                .background(shape.fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.Fill.subtle)))
                .overlay { if !prominent { shape.strokeBorder(Theme.Stroke.border, lineWidth: 0.5) } }
                .brightness(configuration.isPressed ? -0.08 : hovering && enabled ? 0.04 : 0)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// The trackpad's taps (Force Touch trackpads; nothing elsewhere): a light
/// one as a resize snaps to a size, a firmer one at a limit.
@MainActor enum Haptics {
    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func limit() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
