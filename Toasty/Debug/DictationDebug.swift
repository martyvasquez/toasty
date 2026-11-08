#if DEBUG
import Foundation

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
            let samples = try CaptureClip.read(URL(fileURLWithPath: path))
            let speech = await SpeechEngine.shared.containsSpeech(samples)
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
                "speech": speech.map { $0 ? "yes" : "no" } ?? "unknown",
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
            engine["detectorLoaded"] = s.detectorLoaded
            engine["detectorError"] = s.detectorError
            if let r = s.lastRun { engine["lastRun"] = ["text": r.text, "runSeconds": r.runSeconds] }
            return ["engine": engine]
        }
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
