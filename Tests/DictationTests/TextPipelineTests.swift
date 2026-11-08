import Testing
@testable import Toasty

/// Plan Appendix A.1 (hex spoken_formatting.rs tests, English).
@Suite struct SpokenFormattingTests {
    @Test(arguments: [
        ("Hello. New line. Next", "Hello.\nNext"),
        ("One. New paragraph. Two.", "One.\n\nTwo."),
        ("one, line break, two", "one\ntwo"),
        ("a NEW LINE new line b", "a\n\nb"),
        ("He said open quote hi close quote.", "He said \"hi\"."),
        ("He said, Open quote, hello, close quote, and left.", "He said, \"hello\", and left."),
        ("open quote yes close quote then", "\"yes\" then"),
        ("He said quote hello unquote.", "He said \"hello\"."),
        ("Quote, something, unquote, and more", "\"something\", and more"),
        ("open quote a close quote and quote b unquote", "\"a\" and \"b\""),
    ])
    func formats(input: String, expected: String) {
        #expect(TextPipeline.applyFormatting(input) == expected)
    }

    @Test(arguments: ["Can I get a quote for this", "quote unquote experts", "an unquote alone", "The newline character",
                      "a new liner", "renew line items", "line breaker", "open quotes", ""])
    func leavesOtherTextAlone(text: String) {
        #expect(TextPipeline.applyFormatting(text) == text)
    }
}

/// Plan Appendix A.2 (hex spoken_symbols.rs tests) and B (Toasty additions).
@Suite struct SpokenSymbolTests {
    @Test(arguments: [
        ("hashtag release", "#release"),
        ("my underscore variable", "my_variable"),
        ("done comma thanks", "done, thanks"),
        ("tag it hash sign release", "tag it #release"),
        ("mail me at sign home", "mail me @home"),
        ("well hyphen known", "well-known"),
        ("and slash or", "and/or"),
        ("one semicolon two", "one; two"),
        ("the list colon apples", "the list: apples"),
        ("Done, Comma, thanks.", "Done, thanks."),
        ("the list COLON.", "the list:"),
        ("a comma comma b", "a,, b"),
    ])
    func hexSymbols(input: String, expected: String) {
        #expect(TextPipeline.applySymbols(input) == expected)
    }

    @Test(arguments: ["commas", "slashed prices", "hashtags everywhere", "a hash browns sign", "the colonel",
                      "Plain text, nothing to do.", "", "the dots are connected", "dotted line", "a piped command"])
    func leavesOtherWordsAlone(text: String) {
        #expect(TextPipeline.applySymbols(text) == text)
    }

    @Test(arguments: [
        ("Rename user underscore id to account underscore id in src slash models slash user dot rs.",
         // Composer keeps the sentence's own period (plan Appendix B: pinned).
         "Rename user_id to account_id in src/models/user.rs."),
        ("open main dot swift", "open main.swift"),
        ("call foo open paren close paren", "call foo()"),
        ("see docs slash.", "see docs/"),
        ("path tilde slash Development", "path ~/Development"),
        ("C colon backslash temp", "C:\\temp"),
        ("run it with dash dash verbose", "run it with --verbose"),
        ("set x equals sign five", "set x = five"),
        ("cat log pipe symbol grep error", "cat log | grep error"),
        ("a note open paren see docs close paren here", "a note (see docs) here"),
        ("index open bracket zero close bracket", "index [zero]"),
        // Parakeet wrote the slash and the word.
        ("in source/slash model slash user dot rs", "in source/model/user.rs"),
        ("underscore underscore init underscore underscore", "__init__"),
    ])
    func toastySymbols(input: String, expected: String) {
        #expect(TextPipeline.applySymbols(input) == expected)
    }
}

/// Plan Appendix A.3 (hex filler_words.rs tests).
@Suite struct FillerWordTests {
    @Test(arguments: [
        ("So, um, we should go.", "So, we should go."),
        ("I think uh we should go.", "I think we should go."),
        ("I think, um.", "I think."),
        ("Well umm... maybe", "Well maybe"),
        ("It was, er, erm, fine", "It was, fine"),
        ("Done, uh", "Done"),
        ("(um, aside)", "(aside)"),
        ("Um, so I think", "So I think"),
        ("Hello. Uh, we left. Ah. Then", "Hello. We left. Then"),
        ("Uh, um, okay", "Okay"),
        ("First line.\nUm, second", "First line.\nSecond"),
        ("one um\ntwo", "one\ntwo"),
    ])
    func removes(input: String, expected: String) {
        #expect(TextPipeline.removeFillers(input) == expected)
    }

    @Test(arguments: ["The umbrella is ahead of the error.", "Uhura said uh-huh.", "Take him to the ER.",
                      "UM is a university.", "drum, Ahab, ermine"])
    func keeps(text: String) {
        #expect(TextPipeline.removeFillers(text) == text)
    }
}

@Suite struct PipelineOrderTests {
    @Test func symbolsThenVocabulary() {
        var v = Vocabulary.Effective()
        v.casing = [.init(text: "MicCapture")]
        v.replacements = [.init(from: "my capture", to: "MicCapture")]
        #expect(TextPipeline.process("Um, open my capture dot swift.", vocabulary: v) == "Open MicCapture.swift.")
    }
}
