import Foundation
import Testing
@testable import Toasty

/// Fixture WAVs in Tests/Fixtures are synthetic (macOS `say`, voice
/// Samantha), never a person's recording.
enum Fixture {
    private final class Anchor {}
    static func url(_ name: String) throws -> URL {
        try #require(Bundle(for: Anchor.self).url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
    }
    static func samples(_ name: String) throws -> [Float] { try CaptureClip.read(url(name)) }

    /// Deterministic white noise at ~-46 dBFS RMS: room hiss, no speech.
    static func noise(seconds: Double) -> [Float] {
        var state: UInt32 = 12345
        return (0..<Int(seconds * 16_000)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.017
        }
    }
}

@Suite struct PaddingTests {
    @Test func shortClipIsPaddedToMinimum() {
        let padded = SpeechEngine.padded([Float](repeating: 0.5, count: 1_600))
        #expect(padded.count == 24_000)
        #expect(padded.prefix(1_600).allSatisfy { $0 == 0.5 })
        #expect(padded.dropFirst(1_600).allSatisfy { $0 == 0 })
    }

    @Test func exactlyMinimumIsUnchanged() {
        #expect(SpeechEngine.padded([Float](repeating: 0.5, count: 24_000)).count == 24_000)
    }

    /// hex transcription.rs: other_gguf_models_do_not_get_trailing_silence
    @Test func longerClipGetsNoTrailingSilence() {
        #expect(SpeechEngine.padded([Float](repeating: 0.5, count: 32_000)).count == 32_000)
    }

    @Test func emptyClipBecomesMinimumSilence() {
        #expect(SpeechEngine.padded([]).count == 24_000)
    }
}

/// Runs the real engine (Metal, bundled models). Serialized: one engine.
@Suite(.serialized) struct SpeechEngineTests {
    let engine = SpeechEngine.shared
    let vocabulary = VocabularySnapshot(terms: [
        .init(text: "Claude Code"), .init(text: "SwiftUI"), .init(text: "Context7"), .init(text: "MCP"),
    ])

    @Test func loadsParakeetOnMetalWithVocabulary() async throws {
        _ = try await engine.transcribe(Fixture.samples("short"))
        let status = engine.currentStatus
        #expect(status.loaded)
        #expect(status.vocabularySupported)
        #expect(status.device != nil)
        #expect(status.maxAudioMs == 0)
    }

    @Test func vocabularyFixesTerms() async throws {
        let samples = try Fixture.samples("dev-terms")
        let result = try await engine.transcribe(samples, vocabulary: vocabulary)
        #expect(result.text.contains("SwiftUI"), "\(result.text)")
        #expect(result.text.contains("Context7"), "\(result.text)")
        #expect(result.vocabularyTerms == 4)
    }

    @Test func vocabularyLeavesPlainSpeechAlone() async throws {
        let samples = try Fixture.samples("plain")
        let plain = try await engine.transcribe(samples)
        let biased = try await engine.transcribe(samples, vocabulary: vocabulary)
        #expect(plain.text == biased.text)
        #expect(plain.text.localizedCaseInsensitiveContains("coffee"), "\(plain.text)")
        #expect(plain.text.localizedCaseInsensitiveContains("budget"), "\(plain.text)")
    }

    @Test func shortClipIsTranscribed() async throws {
        let result = try await engine.transcribe(Fixture.samples("short"))
        #expect(result.audioSeconds == 1.5)
        #expect(result.text.localizedCaseInsensitiveContains("ship it"), "\(result.text)")
    }

    @Test func resampledAudioReadsTheSame() async throws {
        let native = try await engine.transcribe(Fixture.samples("plain"))
        let resampled = try await engine.transcribe(Fixture.samples("plain-22k"))
        #expect(native.text == resampled.text)
    }

    @Test func steadyStateIsFast() async throws {
        let samples = try Fixture.samples("dev-terms")
        _ = try await engine.transcribe(samples, vocabulary: vocabulary)
        let result = try await engine.transcribe(samples, vocabulary: vocabulary)
        #expect(result.runSeconds < 0.5)
    }

    @Test func cancelledJobNeverRuns() async throws {
        let token = SpeechCancelToken()
        token.cancel()
        await #expect(throws: SpeechEngine.EngineError.self) {
            _ = try await engine.transcribe(Fixture.samples("plain"), cancel: token)
        }
    }

    // MARK: Speech detector

    @Test func detectorHearsSpeech() async throws {
        let plain = try Fixture.samples("plain"), short = try Fixture.samples("short")
        #expect(await engine.containsSpeech(plain) == true)
        #expect(await engine.containsSpeech(short) == true)
        #expect(engine.currentStatus.detectorLoaded)
    }

    @Test func detectorRejectsSilenceAndNoise() async {
        #expect(await engine.containsSpeech([Float](repeating: 0, count: 32_000)) == false)
        #expect(await engine.containsSpeech(Fixture.noise(seconds: 2)) == false)
        #expect(await engine.containsSpeech([]) == false)
    }
}

@Suite struct CaptureClipTests {
    @Test func sixteenKilohertzIsUnchanged() throws {
        let samples: [Float] = (0..<1000).map { Float($0) / 1000 }
        #expect(try CaptureClip.resample(samples, from: 16_000) == samples)
    }

    @Test(arguments: [44_100.0, 48_000.0, 22_050.0, 8_000.0])
    func resampleLengthMatchesRate(rate: Double) throws {
        let seconds = 2.0
        let samples = (0..<Int(rate * seconds)).map { Float(sin(Double($0) * 440 * 2 * .pi / rate)) * 0.5 }
        let out = try CaptureClip.resample(samples, from: rate)
        #expect(abs(out.count - 32_000) <= 16, "\(out.count)")
    }

    @Test func fileIsReadAsSixteenKilohertzMono() throws {
        let resampled = try Fixture.samples("plain-22k"), native = try Fixture.samples("plain")
        #expect(abs(resampled.count - native.count) <= 16, "\(resampled.count) vs \(native.count)")
    }
}
