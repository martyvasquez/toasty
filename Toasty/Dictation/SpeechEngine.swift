import CTranscribe
import Foundation
import os
import Synchronization

/// Terms the engine biases toward, in priority order (first 64 count).
nonisolated struct VocabularySnapshot: Sendable, Equatable {
    struct Term: Sendable, Equatable {
        var text: String
        var soundsLike: [String] = []
    }
    var terms: [Term] = []
    static let empty = VocabularySnapshot()
}

/// One finished run.
nonisolated struct Transcription: Sendable {
    var text: String
    /// Seconds of audio sent to the model (after padding).
    var audioSeconds: Double
    /// Wall time of the run on the engine thread, including session setup.
    var runSeconds: Double
    var encodeMs: Double
    var decodeMs: Double
    var vocabularyTerms: Int
}

/// Set from any thread to skip a job that hasn't started yet. A started
/// Parakeet run checks it only before the decode (≈0.2 s runs; fine).
nonisolated final class SpeechCancelToken: Sendable {
    let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// The speech engine: transcribe.cpp (Hex's fork) running Parakeet TDT 0.6B v2
/// on Metal. This is the ONLY file that touches the C API (like VT.swift for
/// libghostty-vt), so API churn stays here.
///
/// Threading: the library's sessions aren't thread-safe and at most one run
/// may be in flight per model, so every C call happens on one dedicated
/// thread (`toasty.speech`, user-interactive QoS) that runs jobs in FIFO order.
/// Callers use the async API. Never call into the library from the main thread.
///
/// Behavior follows Hex (hex/src/parakeet.rs, transcription/gguf_session.rs):
/// Metal only, one CPU thread, a fresh session per run, a prewarm at load,
/// vocabulary rescoring at boost 2.5, repetition partials kept.
nonisolated final class SpeechEngine: @unchecked Sendable {
    static let shared = SpeechEngine(modelsFolder: SpeechModels.bundledFolder)
    static let log = Logger(subsystem: "com.martyvasquez.toasty", category: "speech")

    enum EngineError: Error, CustomStringConvertible {
        case notMetal(String)
        case wrongModel(String)
        case load(String)
        case run(String)
        case busy
        case cancelled

        var description: String {
            switch self {
            case .notMetal(let device): "Dictation needs a Mac with Apple silicon (the speech model found \(device), not Metal)."
            case .wrongModel(let detail): "The bundled speech model isn't the expected one (\(detail))."
            case .load(let detail): "The speech model couldn't load: \(detail)"
            case .run(let detail): "Transcription failed: \(detail)"
            case .busy: "Too many dictations are waiting to be transcribed."
            case .cancelled: "Cancelled."
            }
        }
    }

    /// What the engine is doing, for the indicator and debug `dictationState`.
    struct Status: Sendable {
        var loaded = false
        var loadError: String?
        var device: String?
        var vocabularySupported = false
        var maxAudioMs: Int64 = 0
        var loadSeconds: Double?
        var prewarmSeconds: Double?
        var pendingJobs = 0
        var runs = 0
        var lastRun: Transcription?
        var detectorLoaded = false
        var detectorError: String?
    }

    private let status = OSAllocatedUnfairLock(initialState: Status())
    var currentStatus: Status { status.withLock { $0 } }

    // Job queue (any thread).
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []

    // Engine-thread state only.
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var lastRunEnded: Date?
    private var detector: Detector = .unloaded
    private enum Detector { case unloaded, loaded(model: OpaquePointer, session: OpaquePointer), failed }

    private let modelsFolder: URL
    /// Cancelled once the process is exiting.
    private let quitting = SpeechCancelToken()

    private final class AbortCheck {
        let tokens: [SpeechCancelToken]
        init(tokens: [SpeechCancelToken]) { self.tokens = tokens }
    }

    /// One engine per models folder; the app uses `shared`. (Tests make
    /// their own with the repo's folder.)
    init(modelsFolder: URL) {
        self.modelsFolder = modelsFolder
        Self.installLogging()
        Self.freeAtExit(self)
        let thread = Thread { [self] in loop() }
        thread.name = "toasty.speech"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Public API (any thread)

    /// Loads and prewarms the model in the background (call once the window
    /// is up). A later dictation retries if this fails.
    func preload() {
        _ = enqueue { [self] in
            do { try loadIfNeeded() } catch { Self.log.error("speech model load failed: \(String(describing: error), privacy: .public)") }
            _ = detectorSession()
        }
    }

    /// Whether 16 kHz mono `samples` contain speech (Silero VAD, threshold
    /// 0.4, min speech 160 ms), or nil when the detector isn't available and
    /// the caller should keep the clip (speech_detector.rs).
    func containsSpeech(_ samples: [Float]) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let queued = enqueue { [self] in continuation.resume(returning: detectSpeech(samples)) }
            if !queued { continuation.resume(returning: nil) }
        }
    }

    /// Zeros appended up to Parakeet's 1.5 s minimum; longer clips unchanged
    /// (no trailing silence for v2: hex transcription.rs:272).
    static func padded(_ samples: [Float]) -> [Float] {
        guard samples.count < DictationConfig.minimumSamples else { return samples }
        return samples + [Float](repeating: 0, count: DictationConfig.minimumSamples - samples.count)
    }

    /// Transcribes 16 kHz mono Float32 samples. Shorter than 1.5 s is padded.
    func transcribe(_ samples: [Float], vocabulary: VocabularySnapshot = .empty,
                    cancel: SpeechCancelToken? = nil) async throws -> Transcription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Transcription, Error>) in
            let queued = enqueue { [self] in
                if cancel?.isCancelled == true { return continuation.resume(throwing: EngineError.cancelled) }
                do { continuation.resume(returning: try transcribeJob(samples, vocabulary: vocabulary, cancel: cancel)) }
                catch { continuation.resume(throwing: error) }
            }
            if !queued { continuation.resume(throwing: EngineError.busy) }
        }
    }

    // MARK: Process exit

    /// `exit` (what `NSApplication.terminate` and XCTest end with) runs
    /// ggml's static destructors, and its Metal device list aborts unless
    /// every Metal buffer is already freed (ggml_metal_rsets_free). So at exit
    /// the engine thread frees everything first. An `atexit` handler added
    /// after the library loaded runs before its destructors. Like Hex
    /// (desktop/process_exit.rs), a run that won't stop in time ends the
    /// process with `_exit`, which skips the destructors.
    ///
    /// ggml creates its Metal device list (a function-local static) during
    /// the first load, registering its destructor then; handlers run in
    /// reverse order, so the hook is added again after every load to stay
    /// ahead of it. Freeing twice is harmless.
    private static let engines = OSAllocatedUnfairLock<[SpeechEngine]>(initialState: [])

    private static func freeAtExit(_ engine: SpeechEngine) {
        engines.withLock { $0.append(engine) }
    }

    private static func addExitHook() {
        atexit { SpeechEngine.freeAllForExit() }
    }

    private static func freeAllForExit() {
        for engine in engines.withLock({ $0 }) where !engine.freeForExit(timeout: 3) {
            log.error("speech engine busy at exit; ending without library teardown")
            _exit(0)
        }
    }

    /// Stops new work, aborts a running decode, frees all native resources on
    /// the engine thread; false if that didn't happen within `timeout`.
    private func freeForExit(timeout: TimeInterval) -> Bool {
        quitting.cancel()
        let done = DispatchSemaphore(value: 0)
        condition.lock()
        jobs.insert({ [self] in
            freeModel()
            if case .loaded(let model, let session) = detector {
                transcribe_vad_session_free(session)
                transcribe_model_free(model)
            }
            detector = .failed
            done.signal()
        }, at: 0)
        condition.signal()
        condition.unlock()
        return done.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Engine thread

    private func enqueue(_ job: @escaping @Sendable () -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard jobs.count < DictationConfig.maxPendingJobs else { return false }
        jobs.append(job)
        status.withLock { $0.pendingJobs = jobs.count }
        condition.signal()
        return true
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            status.withLock { $0.pendingJobs = jobs.count }
            condition.unlock()
            job()
        }
    }

    private func loadIfNeeded() throws {
        if model != nil { return }
        if quitting.isCancelled { throw EngineError.cancelled }
        do {
            try load()
            status.withLock { $0.loaded = true; $0.loadError = nil }
        } catch {
            status.withLock { $0.loaded = false; $0.loadError = String(describing: error) }
            throw error
        }
    }

    private func load() throws {
        let url = try SpeechModels.url(for: DictationConfig.speechModel, in: modelsFolder)
        let started = Date()

        var params = transcribe_model_load_params()
        transcribe_model_load_params_init(&params)
        params.backend = TRANSCRIBE_BACKEND_METAL
        params.no_mmap = false   // weights stay clean, file-backed pages
        var loaded: OpaquePointer?
        let result = transcribe_model_load_file(url.path, &params, &loaded)
        Self.addExitHook()  // after ggml's statics exist (see Process exit)
        guard result == TRANSCRIBE_OK, let loaded else { throw EngineError.load(Self.describe(result)) }

        do {
            try check(loaded)
        } catch {
            transcribe_model_free(loaded)
            throw error
        }
        model = loaded
        let loadSeconds = Date().timeIntervalSince(started)
        status.withLock { $0.loadSeconds = loadSeconds }
        Self.log.info("speech model loaded in \(loadSeconds, format: .fixed(precision: 2)) s")

        // Compile the Metal kernels before the first real dictation. A failed
        // prewarm is a failed load (parakeet.rs:1259-1273).
        do {
            try prewarm()
        } catch {
            freeModel()
            throw error
        }
    }

    /// Metal device, expected model identity, English, vocabulary support.
    private func check(_ model: OpaquePointer) throws {
        var device = transcribe_device_info()
        transcribe_device_info_init(&device)
        guard let handle = transcribe_model_device(model),
              transcribe_device_get_info(handle, &device) == TRANSCRIBE_OK else {
            throw EngineError.notMetal("no device")
        }
        let kind = device.kind.map { String(cString: $0) } ?? "unknown"
        let name = device.description.map { String(cString: $0) } ?? kind
        guard kind == "metal" else { throw EngineError.notMetal("\(kind) (\(name))") }

        let arch = transcribe_model_arch_string(model).map { String(cString: $0) } ?? ""
        let variant = transcribe_model_variant_string(model).map { String(cString: $0) } ?? ""
        let expected = DictationConfig.speechModel
        guard arch == expected.architecture, variant == expected.variant else {
            throw EngineError.wrongModel("\(arch)/\(variant)")
        }

        var caps = transcribe_capabilities()
        transcribe_capabilities_init(&caps)
        guard transcribe_model_get_capabilities(model, &caps) == TRANSCRIBE_OK else {
            throw EngineError.wrongModel("no capabilities")
        }
        let languages = (0..<Int(caps.n_languages)).compactMap { caps.languages?[$0].map { String(cString: $0) } }
        guard languages.isEmpty || languages.contains(DictationConfig.language) else {
            throw EngineError.wrongModel("no English (\(languages.joined(separator: ",")))")
        }

        let vocabulary = transcribe_model_accepts_ext_kind(model, TRANSCRIBE_EXT_SLOT_RUN, TRANSCRIBE_EXT_KIND_PARAKEET_VOCABULARY)
        if !vocabulary { Self.log.error("speech model doesn't accept the vocabulary extension; dictating without vocabulary") }
        let maxAudioMs = caps.max_audio_ms
        status.withLock {
            $0.device = name
            $0.vocabularySupported = vocabulary
            $0.maxAudioMs = maxAudioMs
        }
    }

    private func prewarm() throws {
        if let lastRunEnded, Date().timeIntervalSince(lastRunEnded) < DictationConfig.prewarmSkipWindow { return }
        let started = Date()
        _ = try run([Float](repeating: 0, count: DictationConfig.minimumSamples), vocabulary: .empty, cancel: nil)
        let seconds = Date().timeIntervalSince(started)
        status.withLock { $0.prewarmSeconds = seconds; $0.runs -= 1 }
        Self.log.info("speech model prewarmed in \(seconds, format: .fixed(precision: 2)) s")
    }

    private func freeModel() {
        if let session { transcribe_session_free(session) }
        session = nil
        if let model { transcribe_model_free(model) }
        model = nil
    }

    private func makeSession() throws -> OpaquePointer {
        var params = transcribe_session_params()
        transcribe_session_params_init(&params)
        params.n_threads = DictationConfig.engineThreads
        var made: OpaquePointer?
        let result = transcribe_session_init(model, &params, &made)
        guard result == TRANSCRIBE_OK, let made else { throw EngineError.run("session: \(Self.describe(result))") }
        return made
    }

    /// One run on a fresh session; the used session is freed and its
    /// successor made right away (sessions keep input-sized buffers,
    /// gguf_session.rs:302-341).
    private func run(_ samples: [Float], vocabulary: VocabularySnapshot, cancel: SpeechCancelToken?) throws -> Transcription {
        try loadIfNeeded()
        let started = Date()
        let pcm = Self.padded(samples)

        let current = try session ?? makeSession()
        session = nil
        defer {
            transcribe_session_free(current)
            session = try? makeSession()
        }

        // Aborts on the job's token or when the process is exiting.
        let abort = AbortCheck(tokens: [cancel, quitting].compactMap { $0 })
        transcribe_set_abort_callback(current, { userData in
            guard let userData else { return false }
            return Unmanaged<AbortCheck>.fromOpaque(userData).takeUnretainedValue().tokens.contains { $0.isCancelled }
        }, Unmanaged.passUnretained(abort).toOpaque())
        defer { withExtendedLifetime(abort) {} }

        let useVocabulary = !vocabulary.terms.isEmpty && status.withLock { $0.vocabularySupported }
        let terms = useVocabulary ? Array(vocabulary.terms.prefix(DictationConfig.maxVocabularyTerms)) : []
        let termStrings = CStrings(terms.map(\.text))
        var spellings: [String] = [], spellingTerms: [Int32] = []
        for (index, term) in terms.enumerated() {
            for spelling in term.soundsLike.prefix(DictationConfig.maxSoundsLikePerTerm) {
                spellings.append(spelling)
                spellingTerms.append(Int32(index))
            }
        }
        let spellingStrings = CStrings(spellings)
        let spellingIndex = UnsafeMutablePointer<Int32>.allocate(capacity: max(spellingTerms.count, 1))
        spellingIndex.initialize(from: spellingTerms, count: spellingTerms.count)
        let ext = UnsafeMutablePointer<transcribe_parakeet_vocabulary_ext>.allocate(capacity: 1)
        transcribe_parakeet_vocabulary_ext_init(ext)
        ext.pointee.boost = DictationConfig.vocabularyBoost
        ext.pointee.sounds_like = UnsafePointer(spellingStrings.pointer)
        ext.pointee.sounds_like_term = UnsafePointer(spellingIndex)
        ext.pointee.n_sounds_like = Int32(spellings.count)
        defer {
            spellingIndex.deallocate()
            ext.deallocate()
        }

        let result: transcribe_status = withExtendedLifetime((termStrings, spellingStrings)) {
            DictationConfig.language.withCString { language in
                var params = transcribe_run_params()
                transcribe_run_params_init(&params)
                params.timestamps = TRANSCRIBE_TIMESTAMPS_WORD
                params.language = language
                if !terms.isEmpty {
                    params.vocabulary = UnsafePointer(termStrings.pointer)
                    params.n_vocabulary = Int32(terms.count)
                    params.family = UnsafeRawPointer(ext).assumingMemoryBound(to: transcribe_ext.self)
                }
                return pcm.withUnsafeBufferPointer {
                    transcribe_run(current, $0.baseAddress, Int32($0.count), &params)
                }
            }
        }

        let text = (transcribe_full_text(current).map { String(cString: $0) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A decoder that started looping returns the text before the loop:
        // keep it, as Hex does (gguf_session.rs:392-402).
        guard result == TRANSCRIBE_OK || (result == TRANSCRIBE_ERR_OUTPUT_REPETITION && !text.isEmpty) else {
            if result == TRANSCRIBE_ERR_ABORTED { throw EngineError.cancelled }
            throw EngineError.run(Self.describe(result))
        }

        var timings = transcribe_timings()
        transcribe_timings_init(&timings)
        _ = transcribe_get_timings(current, &timings)
        lastRunEnded = Date()
        let transcription = Transcription(
            text: text,
            audioSeconds: Double(pcm.count) / Double(DictationConfig.sampleRate),
            runSeconds: lastRunEnded!.timeIntervalSince(started),
            encodeMs: Double(timings.encode_ms), decodeMs: Double(timings.decode_ms),
            vocabularyTerms: terms.count)
        status.withLock { $0.runs += 1; $0.lastRun = transcription }
        Self.log.info("""
            transcribed \(transcription.audioSeconds, format: .fixed(precision: 2)) s of audio in \
            \(transcription.runSeconds, format: .fixed(precision: 3)) s (encode \(transcription.encodeMs, format: .fixed(precision: 0)) ms, \
            decode \(transcription.decodeMs, format: .fixed(precision: 0)) ms, \(terms.count) terms)
            """)
        return transcription
    }

    /// A clip longer than the model's limit runs in chunks, skipping chunks
    /// the detector hears no speech in (Hex transcribe_chunked). Parakeet v2
    /// reports no limit (max_audio_ms 0), so this is one run in practice.
    private func transcribeJob(_ samples: [Float], vocabulary: VocabularySnapshot,
                               cancel: SpeechCancelToken?) throws -> Transcription {
        try loadIfNeeded()
        let limitMs = status.withLock { $0.maxAudioMs }
        let limit = Int(limitMs) * DictationConfig.sampleRate / 1000
        guard limit > 0, samples.count > limit else { return try run(samples, vocabulary: vocabulary, cancel: cancel) }

        var combined: Transcription?
        var texts: [String] = []
        for start in stride(from: 0, to: samples.count, by: limit) {
            if cancel?.isCancelled == true { throw EngineError.cancelled }
            let chunk = Array(samples[start..<min(start + limit, samples.count)])
            if detectSpeech(chunk) == false { continue }
            let part = try run(chunk, vocabulary: vocabulary, cancel: cancel)
            if !part.text.isEmpty { texts.append(part.text) }
            if var total = combined {
                total.audioSeconds += part.audioSeconds; total.runSeconds += part.runSeconds
                total.encodeMs += part.encodeMs; total.decodeMs += part.decodeMs
                combined = total
            } else {
                combined = part
            }
        }
        var result = combined ?? Transcription(text: "", audioSeconds: 0, runSeconds: 0, encodeMs: 0, decodeMs: 0,
                                               vocabularyTerms: 0)
        result.text = texts.joined(separator: " ")
        return result
    }

    // MARK: Speech detector (Silero VAD on the CPU: loads in tens of ms)

    private func detectorSession() -> OpaquePointer? {
        switch detector {
        case .loaded(_, let session): return session
        case .failed: return nil
        case .unloaded: break
        }
        do {
            let url = try SpeechModels.url(for: DictationConfig.speechDetector, in: modelsFolder)
            var params = transcribe_model_load_params()
            transcribe_model_load_params_init(&params)
            params.backend = TRANSCRIBE_BACKEND_CPU
            var loaded: OpaquePointer?
            var result = transcribe_model_load_file(url.path, &params, &loaded)
            Self.addExitHook()  // after ggml's statics exist (see Process exit)
            guard result == TRANSCRIBE_OK, let loaded else { throw EngineError.load("detector: \(Self.describe(result))") }
            var info = transcribe_vad_info()
            transcribe_vad_info_init(&info)
            var session: OpaquePointer?
            result = transcribe_vad_get_info(loaded, &info)
            if result == TRANSCRIBE_OK { result = transcribe_vad_session_init(loaded, nil, &session) }
            guard result == TRANSCRIBE_OK, let session, info.sample_rate == Int32(DictationConfig.sampleRate) else {
                transcribe_model_free(loaded)
                throw EngineError.load("detector: \(Self.describe(result)), \(info.sample_rate) Hz")
            }
            detector = .loaded(model: loaded, session: session)
            status.withLock { $0.detectorLoaded = true; $0.detectorError = nil }
            return session
        } catch {
            // Dictation keeps working without it (clips are then kept).
            detector = .failed
            status.withLock { $0.detectorLoaded = false; $0.detectorError = String(describing: error) }
            Self.log.error("speech detector unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func detectSpeech(_ samples: [Float]) -> Bool? {
        guard !samples.isEmpty, let session = detectorSession() else { return samples.isEmpty ? false : nil }
        var params = transcribe_vad_params()
        transcribe_vad_params_init(&params)
        params.threshold = DictationConfig.vadThreshold
        params.min_speech_ms = DictationConfig.vadMinSpeechMs
        let result = samples.withUnsafeBufferPointer {
            transcribe_vad_run(session, $0.baseAddress, Int32($0.count), &params)
        }
        var summary = transcribe_vad_result()
        transcribe_vad_result_init(&summary)
        guard result == TRANSCRIBE_OK, transcribe_vad_get_result(session, &summary) == TRANSCRIBE_OK else {
            Self.log.error("speech detection failed: \(Self.describe(result), privacy: .public)")
            return nil
        }
        return summary.n_segments > 0
    }

    // MARK: Helpers

    private static func describe(_ status: transcribe_status) -> String {
        transcribe_status_string(Int32(status.rawValue)).map { String(cString: $0) } ?? "status \(status.rawValue)"
    }

    /// Routes the library's warnings and errors to os_log (subsystem
    /// com.martyvasquez.toasty, category speech). Called from any thread.
    private static func installLogging() {
        transcribe_log_set({ level, message, _ in
            guard let message else { return }
            let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            switch level {
            case TRANSCRIBE_LOG_LEVEL_ERROR: SpeechEngine.log.error("\(text, privacy: .public)")
            case TRANSCRIBE_LOG_LEVEL_WARN: SpeechEngine.log.warning("\(text, privacy: .public)")
            default: SpeechEngine.log.debug("\(text, privacy: .public)")
            }
        }, nil)
    }
}

/// A C array of C strings that lives as long as this object.
private nonisolated final class CStrings {
    let pointer: UnsafeMutablePointer<UnsafePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: max(count, 1))
        for (index, string) in strings.enumerated() { pointer[index] = UnsafePointer(strdup(string)) }
    }

    deinit {
        for index in 0..<count { free(UnsafeMutableRawPointer(mutating: pointer[index])) }
        pointer.deallocate()
    }
}
