import Foundation
import Testing
@testable import Toasty

@Suite struct ClaudeQuoteTests {
    typealias F = ClaudeQuoteFormat

    @Test func oneQuoteIsNotNumbered() {
        let p = F.prompt([ClaudeQuote(text: "being damaged in real time")], typed: "Cut this.")
        #expect(p == "> being damaged in real time\n\nCut this.")
    }

    @Test func severalQuotesAreNumberedWithNotes() {
        let quotes = [
            ClaudeQuote(text: "first line\nsecond line", note: "Too dramatic"),
            ClaudeQuote(text: "- a bullet"),
        ]
        let p = F.prompt(quotes, typed: "Thanks")
        #expect(p == "> [1] first line\n> second line\nToo dramatic\n\n> [2] - a bullet\n\nThanks")
    }

    @Test func blankLinesInAQuoteStayQuoted() {
        let p = F.prompt([ClaudeQuote(text: "one\n\ntwo")], typed: "")
        #expect(p == "> one\n>\n> two")
    }

    @Test func roundTrips() {
        let quotes = [
            ClaudeQuote(text: "first line\nsecond line", note: "Too dramatic"),
            ClaudeQuote(text: "one\n\ntwo"),
            ClaudeQuote(text: "[3] looks like a number", note: "keep"),
        ]
        let split = F.split(F.prompt(quotes, typed: "And the rest\nof my message"))
        #expect(split.quotes.map(\.text) == quotes.map(\.text))
        #expect(split.quotes.map(\.note) == ["Too dramatic", "", "keep"])
        #expect(split.text == "And the rest\nof my message")
    }

    @Test func plainMessagesAreLeftAlone() {
        let raw = "Fix the bug\n> not a leading quote"
        #expect(F.split(raw).quotes.isEmpty)
        #expect(F.split(raw).text == raw)
    }

    @Test func notesAreOneLine() {
        let p = F.prompt([ClaudeQuote(text: "x", note: "a\nb")], typed: "")
        #expect(p == "> x\na b")
    }

    @Test func cleansSelectedText() {
        #expect(F.clean("  line\u{2028}break\n\n\n\nnext\t1 ") == "line\nbreak\n\nnext 1")
    }

    @Test func searchKeyIgnoresMarkdown() {
        #expect(F.searchKey("**Fiduciary** duty — and the _standard_") == F.searchKey("Fiduciary duty and the standard"))
    }
}
