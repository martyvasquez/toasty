import Foundation
import Testing
@testable import Toasty

/// The widget grid's rules: one grid from the top, 9 units long; the
/// terminal floats over it and isn't on it.
@Suite struct WidgetLayoutTests {
    /// Git Large (rows 0–3) and Usage Small in the right track (row 4).
    private func build() -> WidgetLayout {
        WidgetLayout(widgets: [WidgetItem(kind: .git, span: 2, units: 4, row: 0),
                               WidgetItem(kind: .usage, span: 1, track: 1, units: 2, row: 4)])
    }

    private func item(_ kind: WidgetKind, _ units: Int, row: Int) -> WidgetItem {
        WidgetItem(kind: kind, span: 2, units: units, row: row)
    }

    @Test func heights() {
        #expect([1, 2, 3, 4, 5].map(WidgetGrid.height) == [80, 172, 264, 356, 448])
        #expect(WidgetGrid.width == 356)
        #expect(WidgetGrid.units(fitting: 824) == 9)
        #expect(WidgetGrid.rows == 9)
    }

    @Test func defaultSpacesFitAndHaveNoTerminal() {
        for space in WidgetSpace.defaults {
            let slots = WidgetLayout(space: space).slots
            for a in slots { for b in slots where a.id != b.id { #expect(!(a.overlaps(b))) } }
            #expect(slots.allSatisfy { $0.top >= 0 && $0.bottom <= WidgetGrid.rows })
            #expect(!space.widgets.contains { $0.kind == .terminal })
        }
    }

    @Test func savedTerminalWidgetsAreDropped() {
        let old = WidgetSpace(name: "Old", widgets: [item(.git, 4, row: 0), item(.terminal, 3, row: 0)])
        #expect(old.current.widgets.map(\.kind) == [.git])
        #expect(!WidgetKind.gallery.contains(.terminal))
    }

    @Test func growingPushesDown() throws {
        let l = build()
        let git = l.widgets[0], usage = l.widgets[1]
        // Git 4 → 6 pushes Usage (rows 4–5) to rows 6–7.
        let list = try #require(l.applyingUnits(6, to: git.id))
        #expect(list.first { $0.id == git.id }?.units == 6)
        #expect(list.first { $0.id == usage.id }?.row == 6)
        // At Git's limit (7) Usage still fits in rows 7–8; past it, no more.
        #expect(l.applyingUnits(9, to: git.id)?.first { $0.id == git.id }?.units == 7)
    }

    @Test func nothingIsPushedOffTheGrid() {
        let l = WidgetLayout(widgets: [item(.git, 5, row: 0), item(.teeUp, 4, row: 5)])
        #expect(l.applying(l.widgets[0].id) { $0.units = 6 } == nil)
        #expect(l.applyingUnits(7, to: l.widgets[0].id) == nil)
    }

    @Test func smallTakesTheFreeTrack() throws {
        let l = WidgetLayout(widgets: [item(.git, 2, row: 0)])
        let list = try #require(l.applyingPreset(.small, to: l.widgets[0].id))
        #expect(list[0].span == 1)
        #expect(list[0].track == 1)  // a lone Small sits in the right track
    }

    @Test func presetWithoutRoomIsUnavailable() {
        let l = WidgetLayout(widgets: [item(.git, 5, row: 0), item(.usage, 2, row: 5), item(.teeUp, 2, row: 7)])
        #expect(l.allows(.medium, for: l.widgets[1].id))
        #expect(!(l.allows(.large, for: l.widgets[1].id)))
    }

    @Test func collapseFreesUnits() throws {
        let l = build()
        let list = try #require(l.togglingCollapse(l.widgets[0].id))
        #expect(WidgetLayout(widgets: list).freeCells().contains(.init(row: 1, track: 0)))
        let back = try #require(WidgetLayout(widgets: list).togglingCollapse(l.widgets[0].id))
        #expect(back[0].units == 4)
        #expect(!(back[0].collapsed))
    }

    @Test func placementAndMoving() throws {
        let l = build()
        #expect(l.placement(for: .teeUp, preset: .small)?.row == 4)  // beside Usage
        #expect(l.placement(for: .teeUp, preset: .large) == nil)  // rows 6–9 run off the grid
        let moved = try #require(l.moving(l.widgets[1], toTop: 6, track: 0))
        #expect(moved.row == 6)
        #expect(moved.track == 0)
        #expect(l.moving(l.widgets[1], toTop: 2, track: 1) == nil)  // onto Git
    }

    @Test func gapsCloseSmoothlyBeforeScrolling() {
        // Git rows 0–1, two empty rows, Usage strip at 4, one empty row,
        // Tee-Up at 6–7: 8 rows, 724pt.
        let l = WidgetLayout(widgets: [item(.git, 2, row: 0), item(.usage, 1, row: 4), item(.teeUp, 2, row: 6)])
        func tops(_ h: CGFloat) -> [CGFloat] {
            let p = l.packedTops(toFit: h)
            return l.widgets.map { p.tops[$0.id] ?? -1 }
        }
        #expect(tops(724) == [0, 368, 552])        // room: as saved
        #expect(tops(700) == [0, 368, 528])        // the lowest gap shrinks first, by points
        #expect(tops(632) == [0, 368, 460])        // …to the grid's 12pt gap
        #expect(tops(600) == [0, 336, 428])        // then the one above it
        #expect(tops(448) == [0, 184, 276])        // no room left to give: 448pt
        #expect(l.packedTops(toFit: 300).height == 448)  // past that, the column scrolls
        #expect(l.widgets.map(\.row) == [0, 4, 6])  // saved rows unchanged
    }

    @Test func resizingByEdges() throws {
        // Build: Git Large (rows 0–3), Usage Small in the right track (row 4).
        let l = build()
        let usage = l.widgets[1]
        // Widened: two tracks, Medium.
        let wide = try #require(l.resizing(usage.id, span: 2, track: 0, units: 2)?.first { $0.id == usage.id })
        #expect(wide.span == 2)
        #expect(wide.units == 2)
        // Git narrowed toward the right: a Small in the right track, and
        // Usage (in the right track) pushed down under it.
        let list = try #require(l.resizing(l.widgets[0].id, span: 1, track: 1, units: 2))
        #expect(list[0].span == 1 && list[0].track == 1 && list[0].units == 2)
        // Too tall for the grid: the tallest that fits.
        let tall = try #require(l.resizing(l.widgets[0].id, span: 2, track: 0, units: 9)?.first { $0.id == l.widgets[0].id })
        #expect(tall.units == 7)
    }

    @Test func droppingPushesOthersDown() throws {
        // Git Large (0–3), Usage Small right track (row 4). Usage dropped at
        // the top: Git is pushed down under it.
        let l = build()
        let list = try #require(l.placing(l.widgets[1].id, atTop: 0, track: 1))
        #expect(list[1].row == 0 && list[1].track == 1)
        #expect(list[0].row == 2)
        // Dropped past the end of the grid, it's kept on the grid.
        let low = try #require(l.placing(l.widgets[1].id, atTop: 20, track: 0))
        #expect(low[1].row == WidgetGrid.rows - 2)
    }

    // MARK: Reading saved spaces

    @Test func unknownWidgetsAreSkipped() throws {
        let json = """
        [{"id":"6A1C7E0C-5F3E-4C8B-9A40-0E1E2B0A1F11","name":"Space 1","widgets":[
          {"id":"6A1C7E0C-5F3E-4C8B-9A40-0E1E2B0A1F12","kind":"git","span":2,"track":0,"units":4,"row":0,"collapsed":false},
          {"id":"6A1C7E0C-5F3E-4C8B-9A40-0E1E2B0A1F13","kind":"somethingFromTheFuture","span":2,"track":0,"units":2,"row":4,"collapsed":false}
        ]}, "not a space"]
        """
        let saved = try JSONDecoder().decode(SavedSpaces.self, from: Data(json.utf8))
        #expect(saved.spaces.count == 1)
        #expect(saved.spaces[0].widgets.map(\.kind) == [.git])
    }

    @Test func badSpacesNeverCostTheRestOfTheState() throws {
        let json = #"{"workspaces":[],"sidebarVisible":true,"spaces":"garbage"}"#
        let saved = try JSONDecoder().decode(WorkspaceStore.Saved.self, from: Data(json.utf8))
        #expect(saved.sidebarVisible)
        #expect(saved.spaces?.spaces.isEmpty == true)
    }

    @Test func savedSpacesRoundTrip() throws {
        let spaces = WidgetSpace.defaults
        let data = try JSONEncoder().encode(SavedSpaces(spaces))
        let back = try JSONDecoder().decode(SavedSpaces.self, from: data)
        #expect(back.spaces == spaces)
    }
}
