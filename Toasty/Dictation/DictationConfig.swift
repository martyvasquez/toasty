import Foundation

/// Every tunable dictation constant, in one place. Values are Hex's measured
/// choices (TOASTY_DICTATION_PLAN.md §6–§9); the Hex source each comes from is
/// noted next to it. Change them here, nowhere else.
nonisolated enum DictationConfig {
    // MARK: Models (bundled in Contents/Resources/SpeechModels)

    static let modelsFolder = "SpeechModels"
    /// Parakeet TDT 0.6B v2, Q8_0 (CC BY 4.0, NVIDIA; GGUF by handy-computer).
    static let speechModel = BundledModel(
        file: "parakeet-tdt-0.6b-v2-Q8_0.gguf", bytes: 729_574_912,
        architecture: "parakeet", variant: "tdt-0.6b-v2")
    /// Silero VAD v6.2 (MIT). Checked by role (transcribe_vad_get_info), not name.
    static let speechDetector = BundledModel(
        file: "silero-vad-v6.2-F32.gguf", bytes: 1_241_056,
        architecture: nil, variant: nil)

    // MARK: Engine (hex/src/parakeet.rs, transcription/gguf_session.rs)

    static let language = "en"
    /// Only the per-token decoder runs on the CPU; extra spin-waiting ggml
    /// workers stall it (gguf_session.rs:82-94).
    static let engineThreads: Int32 = 1
    /// Parakeet's minimum input: pad shorter clips with zeros to 1.5 s
    /// (dictation.rs:88). No trailing silence for v2 (transcription.rs:272).
    static let minimumSamples = 24_000
    static let sampleRate = 16_000
    /// Skip the launch prewarm when a run finished this recently (RECENT_RUN).
    static let prewarmSkipWindow: TimeInterval = 60
    /// Most jobs waiting for the engine; beyond that a new job fails
    /// (parakeet.rs:42).
    static let maxPendingJobs = 16

    // MARK: Vocabulary (hex/src/dictation/vocabulary.rs; T/src/arch/parakeet/vocabulary.h)

    /// Nats per term piece. Hex's "Normal"; "Strong" (4.0) turned ordinary
    /// words into terms (docs/research/vocabulary-boost-results.md).
    static let vocabularyBoost: Float = 2.5
    static let maxVocabularyTerms = 64
    static let maxSoundsLikePerTerm = 16
    static let maxTermCharacters = 64

    // MARK: Speech detector (hex/src/transcription/speech_detector.rs:17-26)

    static let vadThreshold = 0.4
    static let vadMinSpeechMs: Int32 = 160

    // MARK: Capture (hex/src/dictation.rs:39-96, dictation/audio.rs:25, audio.rs:235-346)

    /// Native-rate audio kept while the microphone is warm (TIMELINE_BUFFER_DURATION).
    static let ringSeconds: TimeInterval = 10
    /// Audio kept from before the press, so the first word is never clipped.
    static let preRoll: TimeInterval = 0.45
    /// Shorter presses (press→release, event times) are discarded silently.
    static let minimumHold: TimeInterval = 0.3
    /// Audio kept after the release: it often lands while the last word sounds.
    static let releaseTail: TimeInterval = 0.2
    /// How long past the tail to wait for its audio to arrive.
    static let tailDeliveryGrace: TimeInterval = 0.1
    /// A step in the microphone timeline larger than this is a gap…
    static let gapTolerance: TimeInterval = 0.05
    /// …filled with zeros up to this long (a Bluetooth start hiccup is ~140 ms);
    /// a longer one fails the capture.
    static let maxPaddedGap: TimeInterval = 0.25
    /// No audio for this long from an open microphone: reopen it.
    static let stallTimeout: TimeInterval = 4
    /// Opening a device: attempts, and the wait between them, before the next device.
    static let openAttempts = 3
    static let openRetryDelay: TimeInterval = 0.1
    /// Reopening after every device failed: backoff from…to.
    static let reopenBackoffInitial: TimeInterval = 0.25
    static let reopenBackoffMax: TimeInterval = 5
    /// Keep the microphone open whenever Toasty is the active app (macOS then
    /// shows its orange mic indicator the whole time). Off: it opens on the
    /// press — the first ~0.1–0.3 s may be lost to the open, no pre-roll —
    /// and stays open `micLinger` after a dictation, so the next one is warm.
    static let keepMicWarmWhileActive = false
    static let micLinger: TimeInterval = 15
    /// Warm mode: the microphone closes this long after Toasty stops being active.
    static let coldCloseDelay: TimeInterval = 30

    // MARK: Gates (hex/src/dictation.rs:91-96)

    /// A clip whose loudest 30 ms window (DC removed) stays below this is
    /// silence: discarded before the engine, which hallucinates "Thank you."
    static let silenceThresholdDBFS: Float = -50
    static let silenceWindowSamples = 480

    struct BundledModel: Sendable {
        let file: String
        let bytes: Int
        let architecture: String?
        let variant: String?
    }
}
