import Foundation
import SwiftUI

// MARK: - Grid

/// The widget column's grid, as Apple's widgets: two 172pt tracks with a
/// 12pt gap (356pt), height in 80pt units with 12pt gaps, so one Apple cell
/// (172) is exactly two units and the presets land on row lines.
enum WidgetGrid {
    static let track: CGFloat = 172
    static let gap: CGFloat = 12
    static let unit: CGFloat = 80
    /// The column's width, and its margin from the window's right edge,
    /// the tab row, the window's bottom and the conversation.
    static let width: CGFloat = track * 2 + gap
    static let margin: CGFloat = 12
    /// The split view column that holds it.
    static let columnWidth: CGFloat = width + margin * 2
    /// A collapsed widget: its header alone.
    static let headerHeight: CGFloat = 40
    /// The grid's length: a space is laid out on this many units whatever
    /// the window's height (the canvas's 900pt window, and two more below
    /// it). The terminal floats over whatever of it a shorter window can't
    /// show.
    static let rows = 11

    /// n units tall: 80n + 12(n − 1).
    static func height(_ units: Int) -> CGFloat {
        CGFloat(max(units, 1)) * unit + CGFloat(max(units, 1) - 1) * gap
    }

    static func width(span: Int) -> CGFloat { span >= 2 ? width : track }

    /// Units that fit in `height` points.
    static func units(fitting height: CGFloat) -> Int {
        max(0, Int(((height + gap) / (unit + gap)).rounded(.down)))
    }

    /// The top of row `row`.
    static func y(_ row: Int) -> CGFloat { CGFloat(row) * (unit + gap) }
    static func x(track t: Int) -> CGFloat { t == 0 ? 0 : track + gap }
}

// MARK: - Kinds and sizes

/// The size presets: Apple's Small, Medium and Large.
enum WidgetPreset: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var span: Int { self == .small ? 1 : 2 }
    var units: Int { self == .large ? 4 : 2 }
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
    var letter: String { String(title.prefix(1)) }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case git, usage, teeUp, activity
    /// The workspace's folder, browsed in place; Large only (`FilesWidget`).
    case files
    /// A shell, Large only (`TerminalWidget`, an experiment). The case
    /// stays even without the widget, so saved spaces still read.
    case terminal

    var id: String { rawValue }

    /// What the gallery offers. Saved widgets of other kinds are dropped on
    /// load (`WidgetSpace.current`).
    static var gallery: [WidgetKind] { [.git, .usage, .teeUp, .activity, .files, .terminal] }

    var title: String {
        switch self {
        case .git: "Git"
        case .usage: "Usage"
        case .teeUp: "Tee-Up"
        case .activity: "Activity"
        case .files: "Files"
        case .terminal: "Terminal"
        }
    }

    /// The gallery's line under the name.
    var subtitle: String {
        switch self {
        case .git: "Branch, changes and commits"
        case .usage: "Context and limits"
        case .teeUp: "Prompts written ahead"
        case .activity: "What Claude is doing"
        case .files: "Browse this workspace's folder"
        case .terminal: "A shell in this workspace"
        }
    }

    var symbol: String {
        switch self {
        case .git: "plus.forwardslash.minus"
        case .usage: "gauge.with.needle"
        case .teeUp: "list.bullet"
        case .activity: "waveform.path.ecg"
        case .files: "folder"
        case .terminal: "terminal"
        }
    }

    var presets: [WidgetPreset] { self == .terminal || self == .files ? [.large] : WidgetPreset.allCases }

    /// Two-track heights, in units. (Small is one track × 2 units; one
    /// track never grows.)
    var minUnits: Int {
        switch self {
        case .usage: 1
        case .terminal, .files: WidgetPreset.large.units
        default: 2
        }
    }

    var maxUnits: Int {
        switch self {
        case .git: 7
        case .usage, .activity: 4
        case .teeUp, .files: 9
        case .terminal: WidgetPreset.large.units
        }
    }
}

// MARK: - Widgets and spaces

/// A widget on the grid, its rows counted from the column's top.
struct WidgetItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    /// 1 (Small) or 2 tracks.
    var span: Int
    /// The track a one-track widget sits in (0 left, 1 right).
    var track: Int = 0
    var units: Int
    /// Rows above it.
    var row: Int = 0
    var collapsed = false

    /// Rows it holds on the grid: a collapsed widget holds the unit its
    /// header sits in.
    var heldUnits: Int { collapsed ? 1 : units }

    var preset: WidgetPreset? {
        if span == 1 { return .small }
        if units == 2 { return .medium }
        if units == 4 { return .large }
        return nil
    }

    var tracks: ClosedRange<Int> { span >= 2 ? 0...1 : track...track }
}

/// A named set of widgets. Spaces are app-wide; each workspace remembers
/// which one it was on.
struct WidgetSpace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var widgets: [WidgetItem] = []

    /// Without the widgets the gallery no longer offers.
    var current: WidgetSpace {
        var s = self
        s.widgets.removeAll { !WidgetKind.gallery.contains($0.kind) }
        return s
    }

    /// The three the column starts with (the set settled on in use):
    /// Git, the Tee-Up queue, and Usage and Activity side by side. (Spaces
    /// have no names to show; these are for the saved state.)
    static var defaults: [WidgetSpace] {
        [
            WidgetSpace(name: "Space 1", widgets: [
                WidgetItem(kind: .git, span: 2, units: 5, row: 0),
            ]),
            WidgetSpace(name: "Space 2", widgets: [
                WidgetItem(kind: .teeUp, span: 2, units: 4, row: 0),
            ]),
            WidgetSpace(name: "Space 3", widgets: [
                WidgetItem(kind: .usage, span: 1, track: 0, units: 2, row: 0),
                WidgetItem(kind: .activity, span: 1, track: 1, units: 2, row: 0),
            ]),
        ]
    }
}

// MARK: - Layout on the grid

/// A widget's place on the grid.
struct WidgetSlot: Identifiable, Equatable {
    var item: WidgetItem
    var top: Int
    var units: Int
    var id: UUID { item.id }

    var headerOnly: Bool { item.collapsed }
    var held: Int { headerOnly ? 1 : units }
    var bottom: Int { top + held }

    func overlaps(_ o: WidgetSlot) -> Bool {
        top < o.bottom && o.top < bottom && item.tracks.overlaps(o.item.tracks)
    }
}

/// The grid's arithmetic: the edits (presets, dragging an edge, adding,
/// moving), which follow the canvas's rules: growing pushes the widgets
/// below it down into free units, never over another; with no room on the
/// grid the change isn't made. Each widget is drawn as saved, at any window
/// height.
struct WidgetLayout {
    var rows: Int
    var widgets: [WidgetItem]

    init(rows: Int = WidgetGrid.rows, widgets: [WidgetItem]) {
        self.rows = rows
        self.widgets = widgets
    }

    init(space: WidgetSpace) {
        self.init(widgets: space.widgets)
    }

    var slots: [WidgetSlot] {
        widgets.map { WidgetSlot(item: $0, top: $0.row, units: $0.units) }
    }

    /// Drawn in `height` points (the room above the terminal), continuous:
    /// each widget's top, and the height the widgets take. The empty space
    /// above each widget (between it and the one above, or the top) shrinks
    /// point by point, the space nearest the bottom first, down to the
    /// grid's 12pt gap; past that the column scrolls.
    func packedTops(toFit height: CGFloat) -> (tops: [UUID: CGFloat], height: CGFloat) {
        let order = widgets.sorted { ($0.row, $0.track) < ($1.row, $1.track) }
        let unit = WidgetGrid.unit + WidgetGrid.gap
        func h(_ w: WidgetItem) -> CGFloat { w.collapsed ? WidgetGrid.headerHeight : WidgetGrid.height(w.units) }
        // Each widget's room above it, as saved: whole empty rows.
        var extra: [CGFloat] = order.enumerated().map { i, w in
            let above = order[..<i].filter { $0.tracks.overlaps(w.tracks) }.map { $0.row + $0.heldUnits }.max() ?? 0
            return CGFloat(max(0, w.row - above)) * unit
        }
        func place() -> [CGFloat] {
            var tops: [CGFloat] = []
            for (i, w) in order.enumerated() {
                let above = order[..<i].indices.filter { order[$0].tracks.overlaps(w.tracks) }
                    .map { tops[$0] + h(order[$0]) + WidgetGrid.gap }.max() ?? 0
                tops.append(above + extra[i])
            }
            return tops
        }
        var tops = place()
        func content() -> CGFloat { zip(order, tops).map { $1 + h($0) }.max() ?? 0 }
        var need = content() - height
        while need > 0.01 {
            // The room nearest the bottom still to give.
            guard let i = order.indices.filter({ extra[$0] > 0 }).max(by: { tops[$0] < tops[$1] }) else { break }
            extra[i] = max(0, extra[i] - need)
            tops = place()
            let now = content() - height
            if now >= need - 0.01, extra[i] > 0 { extra[i] = 0; tops = place() }
            need = content() - height
        }
        return (Dictionary(uniqueKeysWithValues: zip(order.map(\.id), tops)), content())
    }

    /// Grid cells nobody holds, as (row, track).
    func freeCells(excluding: UUID? = nil) -> Set<Cell> {
        var cells = Set<Cell>()
        for r in 0..<rows { for t in 0...1 { cells.insert(Cell(row: r, track: t)) } }
        for s in slots where s.id != excluding {
            for r in max(0, s.top)..<max(max(0, s.top), s.bottom) { for t in s.item.tracks { cells.remove(Cell(row: r, track: t)) } }
        }
        return cells
    }

    struct Cell: Hashable { var row: Int; var track: Int }

    /// The widgets after `change` is applied to the one with `id`, pushing
    /// the ones below it down to make room; nil when there's no room.
    func applying(_ id: UUID, _ change: (inout WidgetItem) -> Void) -> [WidgetItem]? {
        var list = widgets
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let before = list
        change(&list[i])
        return Self.settle(list, fixed: id, rows: rows, before: before)
    }

    /// Push overlapping widgets down, past whatever they hit, until nothing
    /// overlaps; nil if that runs a moved widget off the grid.
    static func settle(_ list: [WidgetItem], fixed: UUID, rows: Int, before: [WidgetItem]) -> [WidgetItem]? {
        var list = list
        for _ in 0..<64 {
            let slots = WidgetLayout(rows: rows, widgets: list).slots
            for s in slots where s.top < 0 || s.bottom > rows {
                // (One already off the grid, unchanged, stays as it was.)
                if before.first(where: { $0.id == s.id }) != s.item { return nil }
            }
            var hit: (WidgetSlot, WidgetSlot)?
            outer: for a in slots.sorted(by: { $0.top < $1.top }) {
                for b in slots where b.id != a.id && a.overlaps(b) {
                    hit = (a, b)
                    break outer
                }
            }
            guard let (a, b) = hit else { return list }
            // Who moves: never the changed widget; else the lower one.
            let mover: WidgetSlot, stay: WidgetSlot
            if a.id == fixed { (mover, stay) = (b, a) }
            else if b.id == fixed { (mover, stay) = (a, b) }
            else { (mover, stay) = a.top <= b.top ? (b, a) : (a, b) }
            guard let m = list.firstIndex(where: { $0.id == mover.id }) else { return nil }
            list[m].row = stay.bottom
        }
        return nil
    }

    /// Change the widget to a preset (its track kept when it can be, a
    /// lone Small in the right track).
    func applyingPreset(_ preset: WidgetPreset, to id: UUID) -> [WidgetItem]? {
        guard let item = widgets.first(where: { $0.id == id }) else { return nil }
        return applying(id) { w in
            w.collapsed = false
            w.units = preset.units
            if preset.span == 1, w.span != 1 {
                // A Small takes the free track at its rows; alone, the right one.
                let others = WidgetLayout(rows: rows, widgets: widgets.filter { $0.id != id }).slots
                let fits = { (t: Int) in
                    let probe = WidgetSlot(item: WidgetItem(kind: item.kind, span: 1, track: t, units: 2), top: item.row, units: 2)
                    return !others.contains { $0.overlaps(probe) }
                }
                w.track = fits(1) ? 1 : fits(0) ? 0 : 1
            }
            w.span = preset.span
        }
    }

    /// Whether the preset can be had (room for it).
    func allows(_ preset: WidgetPreset, for id: UUID) -> Bool {
        guard let item = widgets.first(where: { $0.id == id }) else { return false }
        if item.preset == preset, !item.collapsed { return true }
        return applyingPreset(preset, to: id) != nil
    }

    /// Height in units, one unit at a time (the edge drag): as far toward
    /// `units` as there's room. A Small keeps its two units.
    func applyingUnits(_ units: Int, to id: UUID) -> [WidgetItem]? {
        guard let item = widgets.first(where: { $0.id == id }), item.span == 2 else { return nil }
        let target = min(max(units, item.kind.minUnits), maxUnits(for: item))
        var best: [WidgetItem]?
        let step = target >= item.units ? 1 : -1
        var u = item.units
        while u != target {
            u += step
            guard let next = applying(id, { $0.units = u; $0.collapsed = false }) else { break }
            best = next
        }
        return best ?? (target == item.units ? widgets : nil)
    }

    /// Resized by dragging its edges: one track (always two units, Apple's
    /// Small) in `track`, or two tracks at `units`. With no room at that
    /// height, the tallest that fits; nil if none does.
    func resizing(_ id: UUID, span: Int, track: Int, units: Int) -> [WidgetItem]? {
        guard let item = widgets.first(where: { $0.id == id }) else { return nil }
        // A kind without a Small stays two tracks wide.
        let span = item.kind.presets.contains(.small) ? span : 2
        let least = span == 1 ? 2 : item.kind.minUnits
        let want = span == 1 ? 2 : min(max(units, least), maxUnits(for: item))
        for u in stride(from: want, through: least, by: -1) {
            let list = applying(id) {
                $0.span = span
                $0.track = span == 1 ? track : 0
                $0.units = u
                $0.collapsed = false
            }
            if let list { return list }
        }
        return nil
    }

    /// The most units this widget could have: its kind's limit, and the
    /// grid's.
    func maxUnits(for item: WidgetItem) -> Int {
        min(item.kind.maxUnits, rows)
    }

    /// Collapse to the header, or open again at its height (or as much of
    /// it as there's room for).
    func togglingCollapse(_ id: UUID) -> [WidgetItem]? {
        guard let item = widgets.first(where: { $0.id == id }) else { return nil }
        if !item.collapsed {
            return applying(id) { $0.collapsed = true }
        }
        let least = item.span == 1 ? 2 : item.kind.minUnits
        for u in stride(from: item.units, through: least, by: -1) {
            if let list = applying(id, { $0.collapsed = false; $0.units = u }) { return list }
        }
        return nil
    }

    /// The first free place for a new widget of this kind and preset (a
    /// Small: either track). Nil when it doesn't fit.
    func placement(for kind: WidgetKind, preset: WidgetPreset) -> WidgetItem? {
        let taken = slots
        let span = preset.span
        let units = preset.units
        for top in 0..<rows where top + units <= rows {
            for track in (span == 1 ? [0, 1] : [0]) {
                let probe = WidgetSlot(item: WidgetItem(kind: kind, span: span, track: track, units: units), top: top, units: units)
                if !taken.contains(where: { $0.overlaps(probe) }) {
                    return WidgetItem(kind: kind, span: span, track: track, units: units, row: top)
                }
            }
        }
        return nil
    }

    /// The widget dropped at `top` (and `track`, for a Small): it goes
    /// there, and the widgets it lands on are pushed down out of its way
    /// (as Home Screen icons make room). Nil only if that runs one off the
    /// grid.
    func placing(_ id: UUID, atTop top: Int, track: Int) -> [WidgetItem]? {
        guard let item = widgets.first(where: { $0.id == id }) else { return nil }
        let row = min(max(top, 0), max(0, rows - item.heldUnits))
        return applying(id) {
            $0.row = row
            $0.track = item.span == 1 ? min(max(track, 0), 1) : 0
        }
    }

    /// The item moved to `top` (and `track`, for a Small), if it fits there
    /// as it is (a move never pushes).
    func moving(_ item: WidgetItem, toTop top: Int, track: Int) -> WidgetItem? {
        var moved = item
        moved.track = item.span == 1 ? min(max(track, 0), 1) : 0
        guard top >= 0, top + item.heldUnits <= rows else { return nil }
        moved.row = top
        let others = WidgetLayout(rows: rows, widgets: widgets.filter { $0.id != item.id }).slots
        let slot = WidgetSlot(item: moved, top: top, units: moved.units)
        return others.contains(where: { $0.overlaps(slot) }) ? nil : moved
    }

    /// The largest empty rectangle, for the edit mode's Add Widget and an
    /// empty space's card.
    func largestFreeBlock() -> (top: Int, units: Int, tracks: ClosedRange<Int>)? {
        let free = freeCells()
        var best: (top: Int, units: Int, tracks: ClosedRange<Int>)?
        func consider(_ tracks: ClosedRange<Int>) {
            var r = 0
            while r < rows {
                guard tracks.allSatisfy({ free.contains(Cell(row: r, track: $0)) }) else { r += 1; continue }
                var end = r
                while end < rows, tracks.allSatisfy({ free.contains(Cell(row: end, track: $0)) }) { end += 1 }
                let area = (end - r) * tracks.count
                if area > (best.map { $0.units * $0.tracks.count } ?? 0) { best = (r, end - r, tracks) }
                r = end
            }
        }
        consider(0...1)
        consider(0...0)
        consider(1...1)
        return best
    }
}

// MARK: - Reading saved spaces, tolerantly

/// Spaces as saved, read so that nothing in them can cost the rest of the
/// state: a widget this build doesn't know (one from a newer Toasty, or a
/// kind since retired) is skipped, so is a space it can't read, and if the
/// list itself can't be read the spaces fall back to the defaults. Written
/// as a plain list.
struct SavedSpaces: Codable {
    var spaces: [WidgetSpace]

    init(_ spaces: [WidgetSpace]) { self.spaces = spaces }

    init(from decoder: Decoder) {
        spaces = (try? LossyList<WidgetSpace>(from: decoder))?.items ?? []
    }

    func encode(to encoder: Encoder) throws {
        try spaces.encode(to: encoder)
    }
}

/// A list whose unreadable elements are skipped.
struct LossyList<T: Decodable>: Decodable {
    var items: [T] = []

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let item = try? c.decode(T.self) {
                items.append(item)
            } else if (try? c.decode(Skip.self)) == nil {
                break  // (can't step past it: stop rather than loop)
            }
        }
    }

    /// Decodes anything, to step past an element.
    private struct Skip: Decodable {
        init(from decoder: Decoder) {}
    }
}

extension WidgetSpace {
    private enum Keys: String, CodingKey { case id, name, widgets }

    /// Tolerant: a widget it can't read is skipped; a missing name or id
    /// gets one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Space"
        widgets = (try? c.decode(LossyList<WidgetItem>.self, forKey: .widgets))?.items ?? []
    }
}
