import AppKit
import AVFoundation
import Testing
@testable import Toasty

/// A 220 Hz sine at 16 kHz (hex dictation.rs tests `tone`).
private func tone(_ amplitude: Float, _ count: Int) -> [Float] {
    (0..<count).map { amplitude * sin(2 * .pi * 220 * Float($0) / 16_000) }
}

private func clip(_ samples: [Float], tail: Int = 0) -> FramedClip {
    FramedClip(samples: samples, tailSamples: tail, prePressSamples: 0, maxGap: 0, cold: false)
}

/// hex dictation.rs: silence_gate_discards_only_near_silent_captures,
/// speech_detector_discards_loud_captures_without_speech.
@Suite struct GateTests {
    let speech: @Sendable ([Float]) async -> Bool? = { _ in true }

    @Test func silenceIsDiscarded() async {
        #expect(await CaptureClip.gate(clip([Float](repeating: 0, count: 16_000)), detector: speech) == .digitalSilence)
        #expect(await CaptureClip.gate(clip([]), detector: speech) != .keep)
        // A −66 dBFS noise floor and a constant DC offset carry no speech.
        #expect(await CaptureClip.gate(clip(tone(0.000_7, 16_000)), detector: speech) != .keep)
        #expect(await CaptureClip.gate(clip([Float](repeating: 0.2, count: 16_000)), detector: speech) != .keep)
    }

    @Test func whisperIsKept() async {
        // 100 ms at whisper level (−43 dBFS RMS) inside a second of silence.
        let quiet = [Float](repeating: 0, count: 8_000) + tone(0.01, 1_600) + [Float](repeating: 0, count: 6_400)
        #expect(await CaptureClip.gate(clip(quiet), detector: speech) == .keep)
        #expect(abs(CaptureClip.loudestWindowDBFS(quiet) - -43) < 0.5)
        #expect(await CaptureClip.gate(clip(tone(0.1, 16_000)), detector: speech) == .keep)
    }

    @Test func detectorDecidesLoudClips() async {
        #expect(await CaptureClip.gate(clip(tone(0.1, 16_000)), detector: { _ in false }) == .noSpeech)
        #expect(await CaptureClip.gate(clip(tone(0.1, 16_000)), detector: { _ in nil }) == .keep)
    }

    @Test func levelGateRunsBeforeTheDetector() async {
        let asked = Box(false)
        _ = await CaptureClip.gate(clip(tone(0.000_7, 16_000))) { _ in asked.store(true); return true }
        #expect(!asked.load())
    }

    @Test func tailIsNotCounted() async {
        // Silent through the release; only the tail (a stop tone, a key) is loud.
        let samples = [Float](repeating: 0.000_1, count: 16_000) + tone(0.3, 3_200)
        #expect(await CaptureClip.gate(clip(samples, tail: 3_200), detector: speech) != .keep)
    }
}

nonisolated private final class Box<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func load() -> T { lock.withLock { value } }
    func store(_ new: T) { lock.withLock { value = new } }
}

@Suite struct FramingTests {
    let origin: TimeInterval = 60

    /// Appends `samples` that end at `through` (Hex's `ingest`).
    func ingest(_ t: inout CaptureTimeline, _ samples: [Float], through: TimeInterval) {
        t.append(samples, at: through - Double(samples.count) / t.rate)
    }

    func clipSamples(_ finish: CaptureTimeline.Finish?) -> (samples: [Float], tail: Int, prePress: Int)? {
        guard case .clip(let samples, let tail, let prePress, _, _) = finish else { return nil }
        return (samples, tail, prePress)
    }

    /// hex: intentional_hold_includes_pre_roll_and_parakeet_padding
    @Test func preRollAndPadding() throws {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin)
        ingest(&t, [Float](repeating: 0.5, count: 8_000), through: origin + 0.5)
        let c = try #require(clipSamples(t.finish(release: origin + 0.5, tail: 0)))
        #expect(c.samples.count == 15_200)  // 950 ms
        #expect(c.prePress == 7_200)
        let padded = SpeechEngine.padded(c.samples)
        #expect(padded.count == 24_000)
        #expect(padded[0] == 0.25)
        #expect(padded.contains(0.5))
    }

    /// hex: release_tail_keeps_audio_through_the_tail_and_no_further
    @Test func releaseTailKeepsAudioThroughTheTailOnly() throws {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin)
        for index in 1...14 {
            ingest(&t, [Float](repeating: Float(index), count: 1_600), through: origin + Double(index) / 10)
        }
        let c = try #require(clipSamples(t.finish(release: origin + 1, tail: DictationConfig.releaseTail)))
        #expect(c.samples.count == 26_400)  // 1,650 ms
        #expect(c.samples.last == 12)
        #expect(!c.samples.contains(13))
        #expect(c.tail == 3_200)
    }

    /// hex: capture_continues_past_sixty_seconds_until_explicitly_finished
    @Test func noMaximumDuration() throws {
        var t = CaptureTimeline(rate: 16_000)
        t.start(press: origin)
        for second in 1...61 {
            ingest(&t, [Float](repeating: 0.5, count: 16_000), through: origin + Double(second))
        }
        let c = try #require(clipSamples(t.finish(release: origin + 61, tail: 0)))
        #expect(c.samples.count == 61 * 16_000)
    }

    /// hex: a press handled 200 ms late still keeps 450 ms before it, plus
    /// the 200 ms after it already captured.
    @Test func latePressKeepsPreRollBeforeThePress() throws {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, tone(0.1, 16_000), through: origin)
        t.start(press: origin - 0.2)
        ingest(&t, [Float](repeating: 0, count: 8_000), through: origin + 0.5)
        let c = try #require(clipSamples(t.finish(release: origin + 0.5, tail: 0)))
        #expect(c.prePress == 7_200)
        #expect(c.samples.count == 7_200 + 3_200 + 8_000)
    }

    /// A press ahead of the newest buffer (large buffers): exactly the
    /// pre-roll is kept before the press once its audio arrives.
    @Test func earlyPressKeepsExactlyThePreRoll() throws {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin + 0.2)
        ingest(&t, [Float](repeating: 0.5, count: 16_000), through: origin + 1)
        let c = try #require(clipSamples(t.finish(release: origin + 1, tail: 0)))
        #expect(c.samples.count == 7_200 + 12_800)
        #expect(c.prePress == 7_200)
        #expect(c.samples.prefix(4_000).allSatisfy { $0 == 0.25 })
    }

    @Test func coldStartBeginsAtTheFirstBuffer() throws {
        var t = CaptureTimeline(rate: 16_000)
        t.start(press: origin)
        ingest(&t, [Float](repeating: 0.5, count: 8_000), through: origin + 0.6)
        guard case .clip(let samples, _, let prePress, _, let cold) = t.finish(release: origin + 0.6, tail: 0) else {
            Issue.record("expected a clip"); return
        }
        #expect(cold)
        #expect(prePress == 0)
        #expect(samples.count == 8_000)
    }

    @Test(arguments: [(0.299, true), (0.300, false), (0.301, false)])
    func minimumHold(held: TimeInterval, discarded: Bool) {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin)
        ingest(&t, [Float](repeating: 0.5, count: 8_000), through: origin + 0.5)
        #expect((t.finish(release: origin + held, tail: 0) == .tooShort) == discarded)
    }

    @Test func shortGapIsFilledWithZeros() throws {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin)
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 0.1)
        // 120 ms of audio never arrived.
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 0.32)
        guard case .clip(let samples, _, _, let maxGap, _) = t.finish(release: origin + 0.32, tail: 0) else {
            Issue.record("expected a clip"); return
        }
        #expect(samples.count == 7_200 + 1_600 + 1_920 + 1_600)
        #expect(samples[(7_200 + 1_600)..<(7_200 + 3_520)].allSatisfy { $0 == 0 })
        #expect(abs(maxGap - 0.12) < 1e-6)
    }

    @Test func jitterUnderToleranceIsNotPadded() throws {
        var t = CaptureTimeline(rate: 16_000)
        t.start(press: origin)
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 0.1)
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 0.24)  // 40 ms step
        let c = try #require(clipSamples(t.finish(release: origin + 0.24, tail: 0, minimumHold: 0)))
        #expect(c.samples.count == 3_200)
    }

    @Test func longGapFailsTheCapture() {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin)
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 0.1)
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 0.5)  // 300 ms gap
        #expect(t.finish(release: origin + 0.5, tail: 0) == .failed(.gap(milliseconds: 300)))
    }

    @Test func longGapWhileIdleRestartsTheRing() throws {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        ingest(&t, [Float](repeating: 0.5, count: 1_600), through: origin + 1.1)  // 1 s gap
        t.start(press: origin + 1.1)
        ingest(&t, [Float](repeating: 0.75, count: 8_000), through: origin + 1.6)
        let c = try #require(clipSamples(t.finish(release: origin + 1.6, tail: 0)))
        #expect(!c.samples.contains(0.25))
        #expect(c.prePress == 1_600)
    }

    @Test func interruptionFailsTheCapture() {
        var t = CaptureTimeline(rate: 16_000)
        ingest(&t, [Float](repeating: 0.25, count: 16_000), through: origin)
        t.start(press: origin)
        t.interrupt()
        #expect(t.finish(release: origin + 1, tail: 0) == .failed(.interrupted))
    }

    @Test func ringKeepsTenSeconds() throws {
        var t = CaptureTimeline(rate: 16_000)
        for second in 1...12 {
            ingest(&t, [Float](repeating: Float(second), count: 16_000), through: origin + Double(second))
        }
        #expect(t.ringCount == 160_000)
        t.start(press: origin + 12, preRoll: 11)
        let c = try #require(clipSamples(t.finish(release: origin + 12, tail: 0, minimumHold: 0)))
        #expect(c.samples.count == 160_000)
        #expect(c.samples.first == 3)
    }

    @Test func nativeRateClipIsResampledWithScaledLengths() throws {
        let rate = 48_000.0
        let samples = (0..<Int(rate * 2)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.1 }
        let framed = try CaptureClip.framed(samples, rate: rate, tailSamples: 9_600, prePressSamples: 21_600,
                                            maxGap: 0, cold: false)
        #expect(abs(framed.samples.count - 32_000) <= 16)
        #expect(framed.tailSamples == 3_200)
        #expect(framed.prePressSamples == 7_200)
    }
}

/// hex audio.rs: system_default_passes_over_a_bluetooth_default,
/// a_bluetooth_default_is_kept_when_nothing_else_is_usable,
/// a_virtual_input_never_stands_in.
@Suite struct DeviceChoiceTests {
    func device(_ id: UInt32, _ name: String, _ transport: MicCapture.Transport) -> MicCapture.InputDevice {
        .init(id: id, uid: name, name: name, transport: transport)
    }

    @Test func bluetoothDefaultIsPassedOverForTheBuiltInMicrophone() {
        let devices = [device(1, "AirPods Pro", .bluetooth), device(2, "MacBook Pro Microphone", .builtIn),
                       device(3, "USB Mic", .other)]
        #expect(MicCapture.candidates(devices, defaultID: 1).map(\.name) ==
                ["MacBook Pro Microphone", "USB Mic", "AirPods Pro"])
        // Other defaults are followed.
        #expect(MicCapture.candidates(devices, defaultID: 3).first?.name == "USB Mic")
        // Without a built-in microphone, a wired input beats Bluetooth.
        #expect(MicCapture.candidates([devices[0], devices[2]], defaultID: 1).first?.name == "USB Mic")
    }

    @Test func bluetoothDefaultIsKeptWhenNothingElseIsUsable() {
        let devices = [device(1, "AirPods Pro", .bluetooth), device(2, "Beats", .bluetooth)]
        #expect(MicCapture.candidates(devices, defaultID: 1).map(\.name) == ["AirPods Pro", "Beats"])
    }

    @Test func virtualAndContinuityInputsNeverStandIn() {
        let devices = [device(1, "AirPods Pro", .bluetooth), device(2, "Microsoft Teams Audio", .virtual),
                       device(3, "iPhone Microphone", .continuity)]
        #expect(MicCapture.candidates(devices, defaultID: 1).map(\.name) == ["AirPods Pro"])
        // …but one that is the default is used.
        #expect(MicCapture.candidates(devices, defaultID: 2).first?.name == "Microsoft Teams Audio")
        #expect(MicCapture.candidates(devices, defaultID: 3).first?.name == "iPhone Microphone")
    }

    @Test func noDefaultPicksTheBuiltInMicrophone() {
        let devices = [device(1, "USB Mic", .other), device(2, "MacBook Pro Microphone", .builtIn)]
        #expect(MicCapture.candidates(devices, defaultID: nil).first?.name == "MacBook Pro Microphone")
    }

    @Test func transportTypesMapLikeHex() {
        #expect(MicCapture.transport(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(MicCapture.transport(kAudioDeviceTransportTypeAggregate) == .virtual)
        #expect(MicCapture.transport(kAudioDeviceTransportTypeContinuityCaptureWireless) == .continuity)
        #expect(MicCapture.transport(kAudioDeviceTransportTypeUSB) == .other)
    }
}

/// Key events and microphone buffers must share one clock (plan §8.4).
/// `NSEvent.timestamp` is seconds since startup (systemUptime); buffers are
/// placed by `AVAudioTime.seconds(forHostTime:)`. Synthetic events carry no
/// timestamp, so real key events are checked live (D3, `dictationState`).
@Suite struct ClockTests {
    @Test func audioHostTimeIsSystemUptime() {
        let audio = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let uptime = ProcessInfo.processInfo.systemUptime
        #expect(abs(audio - uptime) < 0.001, "audio \(audio) uptime \(uptime)")
    }
}
