#if DEBUG
import AppKit
import AVFoundation

/// Debug commands for dictation: test the pipeline with WAV files instead of
/// a microphone (TOASTY_DICTATION_PLAN.md §11.3).
enum DictationDebug {
    typealias E = DebugControl.DebugError

    static func install() {
        // Transcribe a WAV: {"cmd":"dictationTranscribeFile","path":"/x.wav","vocabulary":"/terms.txt"}
        // Reports the gates (the whole file counts as "released"), then
        // transcribes anyway unless "force":false.
        // `vocabulary` (optional) is a file of terms, one per line, `#` comments,
        // `term = sounds like, …` for spellings.
        DebugControl.registerAsync("dictationTranscribeFile") { cmd in
            guard let path = cmd["path"] as? String else { throw E("path required") }
            let samples = try CaptureClip.read(URL(fileURLWithPath: path))
            let clip = FramedClip(samples: samples, tailSamples: 0, prePressSamples: 0, maxGap: 0, cold: false)
            return try await process(clip, vocabulary: vocabulary(cmd), force: cmd["force"] as? Bool ?? true)
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

            let m = MicCapture.shared.currentStatus
            let now = ProcessInfo.processInfo.systemUptime
            var mic: [String: Any] = [
                "permission": permissionName(MicCapture.permission),
                "open": m.open, "warm": m.warm, "simulating": m.simulating,
                "sampleRate": m.sampleRate, "opens": m.opens, "reopens": m.reopens, "stalls": m.stalls,
                "level": Double(MicCapture.shared.level),
            ]
            if let d = m.device { mic["device"] = ["name": d.name, "uid": d.uid, "transport": d.transport.rawValue] }
            mic["lastError"] = m.lastError
            if let at = m.lastBufferAt { mic["lastBufferAgoMs"] = Int((now - at) * 1000) }
            if let l = m.latency { mic["latencyMs"] = (l * 10_000).rounded() / 10 }
            if let c = m.lastColdDelay { mic["lastColdStartLostMs"] = Int(c * 1000) }
            let devices = MicCapture.inputDevices()
            let defaultID = MicCapture.defaultInputID()
            mic["inputs"] = devices.map { d -> [String: Any] in
                ["name": d.name, "transport": d.transport.rawValue, "default": d.id == defaultID]
            }
            mic["choice"] = MicCapture.candidates(devices, defaultID: defaultID).map(\.name)
            let c = DictationController.shared
            var control: [String: Any] = ["trigger": c.triggerState, "phase": "\(c.phase)", "locked": c.locked]
            if let d = c.lastEventDelay { control["lastPressHandledAfterMs"] = (d * 10_000).rounded() / 10 }
            if let last = c.lastDictation { control["last"] = ["raw": last.raw, "final": last.final] }
            return ["engine": engine, "mic": mic, "control": control]
        }

        // Live microphone: {"cmd":"dictationPress"} … speak … {"cmd":"dictationRelease"}.
        // Asks for microphone access the first time.
        DebugControl.registerAsync("dictationPress") { _ in
            guard await MicCapture.requestPermission() else { throw E("microphone access denied") }
            let warm = MicCapture.shared.begin(press: ProcessInfo.processInfo.systemUptime)
            return ["warm": warm]
        }

        DebugControl.registerAsync("dictationRelease") { cmd in
            let outcome = await MicCapture.shared.finish(release: ProcessInfo.processInfo.systemUptime)
            return try await process(outcome, vocabulary: vocabulary(cmd))
        }

        // Feed a file through the capture timeline in real time instead of the
        // microphone, pressing and releasing at offsets into it (seconds), with
        // an optional dropout: {"cmd":"dictationSimulate","path":"/x.wav",
        // "press":0.5,"release":3.2,"gapAt":1.0,"gapMs":120}
        DebugControl.registerAsync("dictationSimulate") { cmd in
            guard let path = cmd["path"] as? String else { throw E("path required") }
            let audio = try CaptureClip.read(URL(fileURLWithPath: path))
            let seconds = Double(audio.count) / 16_000
            let press = cmd["press"] as? Double ?? 0.5
            let release = cmd["release"] as? Double ?? seconds
            let gapAt = cmd["gapAt"] as? Double, gapMs = cmd["gapMs"] as? Double ?? 0
            let mic = MicCapture.shared
            await mic.beginSimulation(rate: 16_000)
            defer { mic.endSimulation() }
            let block = 1_600
            let base = ProcessInfo.processInfo.systemUptime
            var offset = 0.0, index = 0, pressed = false
            var outcome: MicCapture.Outcome = .none
            while true {
                let now = ProcessInfo.processInfo.systemUptime - base
                if !pressed, now >= press { mic.begin(press: base + press); pressed = true }
                if pressed, now >= release + DictationConfig.releaseTail + 0.05 {
                    outcome = await mic.finish(release: base + release)
                    break
                }
                if let gapAt, offset >= gapAt, offset < gapAt + 0.1 { offset += gapMs / 1000 }
                if now >= offset + 0.1 {
                    var chunk = [Float](repeating: 0, count: block)
                    for i in 0..<block where index + i < audio.count { chunk[i] = audio[index + i] }
                    mic.feed(chunk, at: base + offset)
                    index += block; offset += 0.1
                } else {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            return try await process(outcome, vocabulary: vocabulary(cmd))
        }

        // Indicator states for screenshots: {"cmd":"dictationIndicator","phase":"listening","level":0.6}
        DebugControl.register("dictationIndicator") { cmd in
            let level = Float(cmd["level"] as? Double ?? 0)
            let phase: DictationController.Phase = switch cmd["phase"] as? String ?? "idle" {
            case "listening": .listening
            case "transcribing": .transcribing
            case "failed": .failed("The microphone stopped for 400 ms.")
            default: .idle
            }
            DictationController.shared.debugShow(phase, level: level, locked: cmd["locked"] as? Bool ?? false)
            var composers: [[String: Any]] = []
            func walk(_ v: NSView) {
                if let c = v as? ComposerTextView {
                    composers.append(["id": c.dictationID?.uuidString ?? "nil", "hidden": c.isHiddenOrHasHiddenAncestor,
                                      "visible": NSStringFromRect(c.visibleRect), "focused": c.window?.firstResponder === c])
                }
                v.subviews.forEach(walk)
            }
            for w in NSApp.windows { if let v = w.contentView { walk(v) } }
            return ["target": DictationController.shared.target?.uuidString ?? "none", "composers": composers]
        }

        // {"cmd":"dictationDumpLastClip","path":"/tmp/clip.wav"}: the last framed 16 kHz clip.
        DebugControl.register("dictationDumpLastClip") { cmd in
            guard let path = cmd["path"] as? String else { throw E("path required") }
            guard let clip = MicCapture.shared.lastClip else { throw E("no clip yet") }
            try writeWAV(clip.samples, to: URL(fileURLWithPath: path))
            return ["path": path, "seconds": clip.seconds, "tailSamples": clip.tailSamples,
                    "prePressSamples": clip.prePressSamples]
        }
    }

    private static func vocabulary(_ cmd: [String: Any]) throws -> VocabularySnapshot {
        guard let file = cmd["vocabulary"] as? String else { return .empty }
        return parseTerms(try String(contentsOfFile: file, encoding: .utf8))
    }

    private static func process(_ outcome: MicCapture.Outcome, vocabulary: VocabularySnapshot) async throws -> Any? {
        switch outcome {
        case .none: return ["outcome": "no capture"]
        case .tooShort: return ["outcome": "too short"]
        case .failed(let failure): return ["outcome": "failed", "error": failure.description]
        case .clip(let clip): return try await process(clip, vocabulary: vocabulary, force: false)
        }
    }

    /// Gates, then (if kept, or `force`) the engine.
    private static func process(_ clip: FramedClip, vocabulary: VocabularySnapshot, force: Bool) async throws -> Any? {
        let gate = await CaptureClip.gate(clip) { await SpeechEngine.shared.containsSpeech($0) }
        if gate == .digitalSilence, !force { MicCapture.shared.reopenSilentStream() }
        var result: [String: Any] = [
            "gate": gate.description,
            "seconds": (clip.seconds * 1000).rounded() / 1000,
            "prePressMs": clip.prePressSamples / 16, "tailMs": clip.tailSamples / 16,
            "maxGapMs": Int(clip.maxGap * 1000), "cold": clip.cold,
            "levelDBFS": (CaptureClip.loudestWindowDBFS(Array(clip.released)) * 10).rounded() / 10,
        ]
        guard gate == .keep || force else { result["outcome"] = "discarded"; return result }
        let t = try await SpeechEngine.shared.transcribe(clip.samples, vocabulary: vocabulary)
        result["outcome"] = "transcribed"
        result["text"] = t.text
        result["runSeconds"] = t.runSeconds
        result["audioSeconds"] = t.audioSeconds
        result["vocabularyTerms"] = t.vocabularyTerms
        return result
    }

    private static func permissionName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked"
        @unknown default: "unknown"
        }
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = CaptureClip.engineFormat
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw E("can't allocate")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
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
