#if DEBUG
import AVFoundation

/// Debug commands for dictation: test the pipeline with WAV files instead of
/// a microphone (TOASTY_DICTATION_PLAN.md §11.3).
enum DictationDebug {
    typealias E = DebugControl.DebugError

    static func install() {
        // Transcribe a WAV: {"cmd":"dictationTranscribeFile","path":"/x.wav","vocabulary":"/terms.txt"}
        // `vocabulary` (optional) is a file of terms, one per line, `#` comments,
        // `term = sounds like, …` for spellings.
        DebugControl.registerAsync("dictationTranscribeFile") { cmd in
            guard let path = cmd["path"] as? String else { throw E("path required") }
            let samples = try readWAV16kMono(URL(fileURLWithPath: path))
            var vocabulary = VocabularySnapshot.empty
            if let file = cmd["vocabulary"] as? String {
                vocabulary = try parseTerms(String(contentsOfFile: file, encoding: .utf8))
            }
            let t = try await SpeechEngine.shared.transcribe(samples, vocabulary: vocabulary)
            return [
                "text": t.text,
                "audioSeconds": t.audioSeconds, "runSeconds": t.runSeconds,
                "encodeMs": t.encodeMs, "decodeMs": t.decodeMs,
                "vocabularyTerms": t.vocabularyTerms,
            ] as [String: Any]
        }

        DebugControl.register("dictationState") { _ in
            let s = SpeechEngine.shared.currentStatus
            var engine: [String: Any] = [
                "loaded": s.loaded, "vocabularySupported": s.vocabularySupported,
                "maxAudioMs": s.maxAudioMs, "pendingJobs": s.pendingJobs, "runs": s.runs,
            ]
            engine["device"] = s.device
            engine["loadError"] = s.loadError
            engine["loadSeconds"] = s.loadSeconds
            engine["prewarmSeconds"] = s.prewarmSeconds
            if let r = s.lastRun { engine["lastRun"] = ["text": r.text, "runSeconds": r.runSeconds] }
            return ["engine": engine]
        }
    }

    /// Any audio file → 16 kHz mono Float32.
    static func readWAV16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw E("can't allocate buffer")
        }
        try file.read(into: input)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        if source.sampleRate == 16_000, source.channelCount == 1, let data = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw E("can't convert \(source)") }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw E("can't allocate") }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func parseTerms(_ text: String) -> VocabularySnapshot {
        var snapshot = VocabularySnapshot()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let spellings = parts.count > 1 ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
            snapshot.terms.append(.init(text: parts[0], soundsLike: spellings.filter { !$0.isEmpty }))
        }
        return snapshot
    }
}
#endif
