import Testing
@testable import Toasty

@Suite struct VocabularyParsingTests {
    @Test func lineFormats() {
        let file = Vocabulary.parse("""
        # comment

        Claude Code
        libghostty = lib ghostty
        cloud code -> Claude Code
        PTY!
        """)
        #expect(file.terms == [
            .init(text: "Claude Code"),
            .init(text: "libghostty", soundsLike: ["lib ghostty"]),
            .init(text: "PTY", forced: true),
        ])
        #expect(file.replacements == [.init(from: "cloud code", to: "Claude Code")])
    }

    @Test func rejectsLongAndPathTerms() {
        let file = Vocabulary.parse("src/models\n" + String(repeating: "x", count: 65))
        #expect(file.terms.isEmpty)
        #expect(file.warnings.count == 2)
    }

    @Test func warnsAboutRiskySingleWords() {
        #expect(!Vocabulary.parse("Claude").warnings.isEmpty)
        #expect(!Vocabulary.parse("Node").warnings.isEmpty)
        #expect(Vocabulary.parse("Claude Code").warnings.isEmpty)
        #expect(Vocabulary.parse("libghostty").warnings.isEmpty)
    }

    @Test func projectTermsComeFirstAndTheListIsCapped() {
        let project = Vocabulary.parse("Toasty Terminal\nShared Term")
        let global = Vocabulary.parse((["shared term"] + (1...70).map { "Global Term \($0)" }).joined(separator: "\n"))
        let effective = Vocabulary.combine(project: project, global: global)
        #expect(effective.engine.terms.count == 64)
        #expect(effective.engine.terms.first?.text == "Toasty Terminal")
        #expect(effective.engine.terms.filter { $0.text.lowercased() == "shared term" }.count == 1)
        #expect(effective.casing.count == 72)  // 2 + 71 − 1 duplicate
    }
}

/// hex text_replacements.rs tests + plan Appendix B.
@Suite struct ReplacementTests {
    func r(_ pairs: [(String, String)]) -> [Vocabulary.Replacement] { pairs.map { .init(from: $0.0, to: $0.1) } }

    @Test func matchesSpacingAndHyphenVariantsOnly() {
        let rules = r([("cloud code", "Claude Code")])
        for input in ["cloud code", "CloudCode", "cloud-code", "Cloud Code"] {
            #expect(TextPipeline.applyReplacements("use \(input) now", rules) == "use Claude Code now", "\(input)")
        }
        #expect(TextPipeline.applyReplacements("Cloudflare", rules) == "Cloudflare")
        #expect(TextPipeline.applyReplacements("the cloud is up", rules) == "the cloud is up")
    }

    @Test func wholeWordsOnUnicodeBoundaries() {
        let rules = r([("cafe au lait", "café au lait"), ("open code", "OpenCode"), ("über", "Über")])
        #expect(TextPipeline.applyReplacements("OPEN CODE, open code. café au lait; cafe au lait! ÜBER.", rules)
                == "OpenCode, OpenCode. café au lait; café au lait! Über.")
        #expect(TextPipeline.applyReplacements("reopen code, open codes, übercool", rules)
                == "reopen code, open codes, übercool")
    }

    @Test func underscoreAndDigitsArePartOfAWord() {
        let rules = r([("issue", "Issue")])
        #expect(TextPipeline.applyReplacements("issue_id", rules) == "issue_id")
        #expect(TextPipeline.applyReplacements("issue2", rules) == "issue2")
        #expect(TextPipeline.applyReplacements("reissues", rules) == "reissues")
    }

    @Test func longestMatchWinsAndOutputsAreNotReplacedAgain() {
        let rules = r([("open", "closed"), ("open code", "OpenCode"), ("code then open", "combined"), ("closed", "shut")])
        #expect(TextPipeline.applyReplacements("open code then open", rules) == "OpenCode then closed")
        let chain = r([("open code", "OpenCode"), ("alpha", "beta release"), ("beta", "gamma")])
        #expect(TextPipeline.applyReplacements("OPEN CODE alpha", chain) == "OpenCode beta release")
    }

    @Test func emptyReplacementDeletes() {
        let rules = r([("um", "")])
        #expect(TextPipeline.applyReplacements("I um think so.", rules) == "I think so.")
        #expect(TextPipeline.applyReplacements("I think so um.", rules) == "I think so.")
    }

    @Test func userExample() {
        let rules = r([("nimblest", "Nimbalyst")])
        #expect(TextPipeline.applyReplacements("overall, nimblest, parallel", rules) == "overall, Nimbalyst, parallel")
    }
}

/// Plan §10.5 / Appendix B casing cases.
@Suite struct CasingTests {
    let terms: [Vocabulary.Term] = [.init(text: "PTY"), .init(text: "Sendable"), .init(text: "Node"), .init(text: "Claude Code")]
    let dictionary: (String) -> Bool = { ["sendable", "node", "codex"].contains($0.lowercased()) }

    @Test func fixesTermsThatAreNotOrdinaryWords() {
        #expect(TextPipeline.fixCasing("the pty resizes", terms, isDictionaryWord: dictionary) == "the PTY resizes")
        #expect(TextPipeline.fixCasing("the PTY", terms, isDictionaryWord: dictionary) == "the PTY")
        #expect(TextPipeline.fixCasing("pty-host", terms, isDictionaryWord: dictionary) == "PTY-host")
        #expect(TextPipeline.fixCasing("open claude code", terms, isDictionaryWord: dictionary) == "open Claude Code")
    }

    @Test func leavesOrdinaryWordsUnlessForced() {
        #expect(TextPipeline.fixCasing("make it sendable", terms, isDictionaryWord: dictionary) == "make it sendable")
        #expect(TextPipeline.fixCasing("the node bridge", terms, isDictionaryWord: dictionary) == "the node bridge")
        let forced = [Vocabulary.Term(text: "Sendable", forced: true), .init(text: "Codex", forced: true)]
        #expect(TextPipeline.fixCasing("make it sendable", forced, isDictionaryWord: dictionary) == "make it Sendable")
        #expect(TextPipeline.fixCasing("codex sessions", forced, isDictionaryWord: dictionary) == "Codex sessions")
    }

    @Test func notInsideOtherWords() {
        #expect(TextPipeline.fixCasing("empty", terms, isDictionaryWord: dictionary) == "empty")
        #expect(TextPipeline.fixCasing("pty_size", terms, isDictionaryWord: dictionary) == "pty_size")
    }

    @Test func systemWordListIsLoaded() {
        #expect(Vocabulary.isDictionaryWord("conductor"))
        #expect(!Vocabulary.isDictionaryWord("worktree"))
    }
}
