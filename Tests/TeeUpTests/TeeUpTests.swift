import Foundation
import Testing
@testable import Toasty

@MainActor
struct TeeUpTests {
    private func workspace(_ texts: [String]) -> Workspace {
        let w = Workspace(name: "Test", folder: NSTemporaryDirectory())
        texts.forEach { w.addTeeUp(TeeUp(text: $0)) }
        return w
    }

    @Test func emptyPromptsArentAdded() {
        let w = workspace(["", "  \n "])
        #expect(w.teeUps.isEmpty)
    }

    @Test func aNewPromptOpensAndGoesAwayIfLeftEmpty() {
        let w = workspace(["first"])
        w.newTeeUp()
        #expect(w.teeUps.count == 2)
        #expect(w.teeUpEditingID == w.teeUps[1].id)
        w.endTeeUpEdit()
        #expect(w.teeUps.map(\.text) == ["first"])

        w.newTeeUp()
        var typed = w.teeUps[1]
        typed.text = "second"
        w.updateTeeUp(typed)
        // Starting another closes (and keeps) this one.
        w.newTeeUp()
        w.endTeeUpEdit()
        #expect(w.teeUps.map(\.text) == ["first", "second"])
    }

    @Test func droppedFilesGoOnTheOpenPromptOrStartOne() {
        let w = workspace(["first"])
        let spec = URL(fileURLWithPath: "/tmp/spec.pdf"), notes = URL(fileURLWithPath: "/tmp/notes.txt")
        // Nothing open: a new prompt, open, holding the file.
        w.attachToTeeUp([spec])
        #expect(w.teeUps.count == 2)
        #expect(w.teeUps[1].files == ["/tmp/spec.pdf"])
        #expect(w.teeUpEditingID == w.teeUps[1].id)
        // One open: it gets the file.
        w.attachToTeeUp([notes])
        #expect(w.teeUps.count == 2)
        #expect(w.teeUps[1].files == ["/tmp/spec.pdf", "/tmp/notes.txt"])
        // A prompt that's only files is kept.
        w.endTeeUpEdit()
        #expect(w.teeUps.count == 2)
    }

    @Test func aPromptWithOnlyAFileCounts() {
        let w = workspace([])
        w.addTeeUp(TeeUp(files: ["/tmp/spec.pdf"]))
        #expect(w.teeUps.count == 1)
    }

    @Test func reorderEditAndDelete() {
        let w = workspace(["a", "b", "c"])
        w.moveTeeUp(w.teeUps[2].id, to: 0)
        #expect(w.teeUps.map(\.text) == ["c", "a", "b"])
        w.moveTeeUp(w.teeUps[0].id, to: 99)  // past the end: last
        #expect(w.teeUps.map(\.text) == ["a", "b", "c"])

        var edited = w.teeUps[1]
        edited.text = "B"
        w.updateTeeUp(edited)
        #expect(w.teeUps.map(\.text) == ["a", "B", "c"])

        w.removeTeeUp(w.teeUps[0].id)
        #expect(w.teeUps.map(\.text) == ["B", "c"])
    }

    @Test func editingInPlace() {
        let w = workspace(["a", "b"])
        // Edits are kept as they're typed; closing tidies the text.
        w.editTeeUp(w.teeUps[1].id)
        var edited = w.teeUps[1]
        edited.text = "B \n"
        w.updateTeeUp(edited)
        w.endTeeUpEdit()
        #expect(w.teeUps.map(\.text) == ["a", "B"])
        #expect(w.teeUpEditingID == nil)

        // Opening another closes the first.
        w.editTeeUp(w.teeUps[0].id)
        w.editTeeUp(w.teeUps[1].id)
        #expect(w.teeUpEditingID == w.teeUps[1].id)

        // Edited down to nothing, it's gone when closed.
        edited.text = " "
        w.updateTeeUp(edited)
        w.endTeeUpEdit()
        #expect(w.teeUps.map(\.text) == ["a"])

        // Deleting the prompt being edited ends the edit.
        w.editTeeUp(w.teeUps[0].id)
        w.removeTeeUp(w.teeUps[0].id)
        #expect(w.teeUpEditingID == nil)
    }

    // Three rows, 40, 100 and 20 tall with 6 between: tops at 0, 46, 152.
    private let layout = ReorderLayout(heights: [40, 100, 20], spacing: 6)

    @Test func aDraggedRowTakesAPlaceOnceItsEdgePassesTheMiddle() {
        #expect(layout.top(1) == 46)
        #expect(layout.top(2) == 152)
        // The first row going down: its bottom edge (40 + y) against the
        // second row's middle (96), then the third's (162).
        #expect(layout.target(from: 0, y: 0) == 0)
        #expect(layout.target(from: 0, y: 55) == 0)
        #expect(layout.target(from: 0, y: 57) == 1)
        #expect(layout.target(from: 0, y: 121) == 1)
        #expect(layout.target(from: 0, y: 123) == 2)
        // The last row going up: its top edge (152 + y) against the
        // second row's middle (96), then the first's (20).
        #expect(layout.target(from: 2, y: -55) == 2)
        #expect(layout.target(from: 2, y: -57) == 1)
        #expect(layout.target(from: 2, y: -133) == 0)
    }

    @Test func theOthersStepAsideByTheDraggedRowsHeight() {
        // The first row dragged past both: they move up by 40 + 6.
        #expect(layout.offset(of: 1, from: 0, y: 123) == -46)
        #expect(layout.offset(of: 2, from: 0, y: 123) == -46)
        #expect(layout.offset(of: 2, from: 0, y: 57) == 0)
        // The last row dragged to the top: the others move down by 20 + 6.
        #expect(layout.offset(of: 0, from: 2, y: -133) == 26)
        #expect(layout.offset(of: 1, from: 2, y: -133) == 26)
    }

    @Test func aRowsNewPlaceAndTheEndsOfTheColumn() {
        // To the end, the first row moves down by the two it passes.
        #expect(layout.shift(from: 0, to: 2) == 132)
        #expect(layout.shift(from: 2, to: 0) == -152)
        #expect(layout.shift(from: 1, to: 1) == 0)
        // Never dragged past either end.
        #expect(layout.clamped(500, from: 0) == 132)
        #expect(layout.clamped(-500, from: 0) == 0)
        #expect(layout.clamped(-500, from: 2) == -152)
        #expect(layout.clamped(30, from: 1) == 26)
    }

    @Test func sendingNeedsATab() {
        let w = workspace(["a"])
        #expect(!w.sendTeeUp(w.teeUps[0].id))
        #expect(w.teeUps.count == 1)
    }

    @Test func theListIsSavedWithItsWorkspace() throws {
        let w = workspace(["a", "b"])
        w.newTeeUp()  // still empty: not saved
        let data = try JSONEncoder().encode(w.saved)
        let restored = Workspace(saved: try JSONDecoder().decode(Workspace.Saved.self, from: data))
        #expect(restored.teeUps.map(\.text) == ["a", "b"])
    }

    @Test func olderStateHasNoList() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Old","folder":"/tmp","conversations":[],"terminals":[],"terminalVisible":false}"#
        let restored = Workspace(saved: try JSONDecoder().decode(Workspace.Saved.self, from: Data(json.utf8)))
        #expect(restored.teeUps.isEmpty)
    }
}
