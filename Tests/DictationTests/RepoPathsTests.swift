import Testing
@testable import Toasty

@Suite struct RepoPathsTests {
    let index = RepoPaths.Index(files: [
        "src/tmp/cache.json",
        "src/models/user.rs",
        "src/models/account.rs",
        "src/lib.rs",
        "docs/setup.md",
        "Toasty/Dictation/MicCapture.swift",
        "Toasty/Terminal/TerminalView.swift",
        "web/src/components/Button.tsx",
        "README.md",
    ])

    @Test(arguments: [
        ("look in source/temp", "look in src/tmp"),
        ("Rename user_id in source/model/user.rs.", "Rename user_id in src/models/user.rs."),
        ("open source/models/account.rs", "open src/models/account.rs"),
        ("see documentation/setup.md", "see docs/setup.md"),
        ("open dictation/MicCapture.swift", "open Dictation/MicCapture.swift"),
        ("the source/ folder", "the src/ folder"),
        ("edit components/button.tsx", "edit components/Button.tsx"),
    ])
    func resolves(input: String, expected: String) {
        #expect(RepoPaths.resolve(input, in: index) == expected)
    }

    @Test(arguments: [
        "and/or",                          // not a path in this repo
        "client/server split",             // no such folders
        "src/models/user.ts",              // wrong extension: never swapped
        "~/Development/notes",             // outside the repo
        "src/tmp",                         // already right
        "plain text",
    ])
    func leavesAlone(text: String) {
        #expect(RepoPaths.resolve(text, in: index) == text)
    }

    @Test func ambiguousStaysAsSaid() {
        let two = RepoPaths.Index(files: ["lib/x.rs", "libs/x.rs"])
        #expect(RepoPaths.resolve("libraries/x.rs", in: two) == "libraries/x.rs")
        // Same written result from two places is not ambiguous.
        let same = RepoPaths.Index(files: ["a/src/x.rs", "b/src/x.rs"])
        #expect(RepoPaths.resolve("source/x.rs", in: same) == "src/x.rs")
    }

    @Test func similarity() {
        #expect(RepoPaths.similarity("source", "src") == 1)
        #expect(RepoPaths.similarity("model", "models") == 1)
        #expect(RepoPaths.similarity("Dictation", "dictation") == 0)
        #expect(RepoPaths.similarity("user.rs", "user.ts") == nil)
        #expect(RepoPaths.similarity("terminal", "termnal") == 2)
        #expect(RepoPaths.similarity("cat", "car") == nil)
    }
}
