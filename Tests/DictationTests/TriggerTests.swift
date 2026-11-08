import Testing
@testable import Toasty

/// Plan §9.2 (Hex suppression/tests.rs, hold mode with double-tap on), plus
/// Toasty's Escape-cancels rule.
@Suite struct TriggerStateMachineTests {
    typealias M = TriggerStateMachine
    let t0: Double = 100

    func run(_ events: [M.Event]) -> (M, [M.Action?]) {
        var m = M()
        let actions = events.map { m.handle($0) }
        return (m, actions)
    }

    @Test func holdStartsAndReleaseFinishes() {
        let (m, a) = run([.triggerDown(t0), .triggerUp(t0 + 1)])
        #expect(a == [.start(t0), .finish(t0 + 1)])
        #expect(m.state == .idle(lastRelease: t0 + 1))
    }

    /// A short tap still finishes: the capture discards holds under 300 ms
    /// by event times (CaptureTimeline.finish), so the machine never times.
    @Test func shortTapFinishesForTheCaptureToDiscard() {
        let (_, a) = run([.triggerDown(t0), .triggerUp(t0 + 0.1)])
        #expect(a == [.start(t0), .finish(t0 + 0.1)])
    }

    @Test func doubleTapLocksAndThirdPressFinishes() {
        let (m, a) = run([.triggerDown(t0), .triggerUp(t0 + 0.08),
                          .triggerDown(t0 + 0.2), .triggerUp(t0 + 0.3),
                          .triggerDown(t0 + 5), .triggerUp(t0 + 5.1)])
        #expect(a == [.start(t0), .finish(t0 + 0.08), .start(t0 + 0.2), nil, .finish(t0 + 5), nil])
        #expect(m.state == .idle(lastRelease: nil))
    }

    /// hex: callback_hold_and_double_tap_boundaries_are_milliseconds
    @Test(arguments: [(0.299, true), (0.300, false)])
    func doubleTapWindowBoundary(gap: Double, locks: Bool) {
        // Second release `gap` after the first release.
        let (m, _) = run([.triggerDown(t0), .triggerUp(t0 + 0.05),
                          .triggerDown(t0 + 0.1), .triggerUp(t0 + 0.05 + gap)])
        #expect(m.isLocked == locks)
    }

    @Test func secondPressAfterTheWindowIsANewHold() {
        let (m, a) = run([.triggerDown(t0), .triggerUp(t0 + 0.05),
                          .triggerDown(t0 + 0.5), .triggerUp(t0 + 0.6)])
        #expect(a[2] == .start(t0 + 0.5))
        #expect(a[3] == .finish(t0 + 0.6))
        #expect(!m.isLocked)
    }

    @Test func anyKeyWhileHoldingIsAChordAtAnyTime() {
        for after in [0.05, 2.0] {
            let (m, a) = run([.triggerDown(t0), .keyDown(t0 + after), .triggerUp(t0 + after + 0.1)])
            #expect(a == [.start(t0), .discard, nil])
            #expect(m.state == .idle(lastRelease: nil))
        }
    }

    @Test(arguments: [(0.299, true), (0.300, false)])
    func mouseOrModifierIsAChordOnlyInTheFirst300ms(after: Double, discards: Bool) {
        for event in [M.Event.mouseDown(t0 + after), .extraModifier(t0 + after)] {
            let (_, a) = run([.triggerDown(t0), event])
            #expect((a[1] == .discard) == discards)
        }
    }

    @Test func escapeCancelsHoldingAndLocked() {
        let (m1, a1) = run([.triggerDown(t0), .escape(t0 + 1), .triggerUp(t0 + 1.2)])
        #expect(a1 == [.start(t0), .cancel, nil])
        #expect(m1.state == .idle(lastRelease: nil))
        let (m2, a2) = run([.triggerDown(t0), .triggerUp(t0 + 0.05), .triggerDown(t0 + 0.1), .triggerUp(t0 + 0.2),
                            .escape(t0 + 3)])
        #expect(a2.last == .cancel)
        #expect(m2.state == .idle(lastRelease: nil))
    }

    @Test func escapeWhileIdleIsLeftAlone() {
        let (_, a) = run([.escape(t0)])
        #expect(a == [nil])
    }

    @Test func lockedIgnoresKeysAndClicks() {
        let (m, a) = run([.triggerDown(t0), .triggerUp(t0 + 0.05), .triggerDown(t0 + 0.1), .triggerUp(t0 + 0.2),
                          .keyDown(t0 + 1), .mouseDown(t0 + 1.5), .extraModifier(t0 + 1.6)])
        #expect(a.suffix(3) == [nil, nil, nil])
        #expect(m.isLocked)
    }

    @Test func buttonStartsLockedAndFinishes() {
        let (m, a) = run([.button(t0), .button(t0 + 3)])
        #expect(a == [.start(t0), .finish(t0 + 3)])
        #expect(m.state == .idle(lastRelease: nil))
    }

    @Test func resignActiveFinishesAHoldButKeepsALock() {
        let (_, a) = run([.triggerDown(t0), .resignActive(t0 + 1)])
        #expect(a == [.start(t0), .finish(t0 + 1)])
        let (m, b) = run([.button(t0), .resignActive(t0 + 1)])
        #expect(b == [.start(t0), nil])
        #expect(m.isLocked)
    }

    @Test func keyRepeatOfTheTriggerNeverRetriggers() {
        let (_, a) = run([.triggerDown(t0), .triggerDown(t0 + 0.5), .triggerUp(t0 + 1)])
        #expect(a == [.start(t0), nil, .finish(t0 + 1)])
    }
}

/// Plan Appendix A.5 (hex paste.rs:1035-1068), with the character before the caret.
@Suite struct ComposerJoiningTests {
    @Test func joinsWithSentenceAwareSpacing() {
        #expect(TextPipeline.forComposer("And if you see it.", before: "Because if I don't do that,") == " and if you see it.")
        #expect(TextPipeline.forComposer("well, that works.", before: "And if you see it.") == " Well, that works.")
        #expect(TextPipeline.forComposer("Next sentence.", before: "Already spaced. ") == "Next sentence.")
        #expect(TextPipeline.forComposer(", world.", before: "Hello") == ", world.")
    }

    @Test func keepsProperNounsMidSentence() {
        #expect(TextPipeline.forComposer("GitHub next.", before: "Open") == " GitHub next.")
        #expect(TextPipeline.forComposer("Slack now.", before: "Message") == " Slack now.")
    }

    @Test func spaceOnlyWhereOneBelongs() {
        for previous: Character in ["a", "Z", "7", ".", "?", ")", "”"] {
            #expect(TextPipeline.needsLeadingSpace(previous: previous, text: "in progress"), "\(previous)")
        }
        for previous: Character in ["@", "$", "#", "/", "-", "(", "“", " ", "\n", "\t"] {
            #expect(!TextPipeline.needsLeadingSpace(previous: previous, text: "in progress"), "\(previous)")
        }
        #expect(!TextPipeline.needsLeadingSpace(previous: "a", text: ""))
        #expect(!TextPipeline.needsLeadingSpace(previous: "a", text: " already spaced"))
        #expect(!TextPipeline.needsLeadingSpace(previous: "a", text: ", then more"))
    }

    @Test func emptyComposerStartsASentence() {
        #expect(TextPipeline.forComposer("open the preview.", before: "") == "Open the preview.")
        #expect(TextPipeline.forComposer("next.", before: "Done.\n") == "Next.")
    }

    @Test func neverTrailingWhitespace() {
        #expect(TextPipeline.forComposer(" Hello there. \n", before: "") == "Hello there.")
    }
}
