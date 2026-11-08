import AppKit

/// Dictation's sounds (plan §9.3): a soft rising pair when listening
/// starts, the falling pair when it stops, a low pair on failure, and a
/// light tick when text lands long after the stop. Synthesized here (short
/// sines with smooth fades, quiet), so nothing is bundled.
@MainActor
enum DictationTones {
    enum Tone: CaseIterable { case start, stop, error, done }

    private static var sounds: [Tone: NSSound] = [:]
    private static var pendingStart: DispatchWorkItem?
    private static var playingStart: NSSound?

    /// The start tone, `DictationConfig.startToneDelay` after the press;
    /// `retractStart()` before then cancels it (a chord, a cancel).
    static func scheduleStart() {
        retractStart()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                pendingStart = nil
                playingStart = play(.start)
            }
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationConfig.startToneDelay, execute: work)
    }

    static func retractStart() {
        pendingStart?.cancel()
        pendingStart = nil
        if let sound = playingStart, sound.isPlaying { sound.stop() }
        playingStart = nil
    }

    @discardableResult
    static func play(_ tone: Tone) -> NSSound? {
        guard DictationConfig.playTones else { return nil }
        if tone != .start { pendingStart?.cancel(); pendingStart = nil }
        let sound = sounds[tone] ?? NSSound(data: wav(samples(tone, rate: 44_100), rate: 44_100))
        sounds[tone] = sound
        sound?.stop()
        sound?.play()
        return sound
    }

    // MARK: Synthesis

    /// Notes (Hz) and length of each, overlapping slightly.
    nonisolated private static func notes(_ tone: Tone) -> (frequencies: [Double], seconds: Double, level: Double) {
        switch tone {
        case .start: ([659.3, 987.8], 0.065, 0.06)   // E5 → B5, rising fifth (quietest: the mic hears it)
        case .stop: ([987.8, 659.3], 0.065, 0.10)    // falling
        case .error: ([311.1, 233.1], 0.09, 0.13)    // E♭4 → B♭3
        case .done: ([1318.5], 0.05, 0.06)           // a light tick
        }
    }

    /// Mono Float samples of `tone` at `rate`.
    nonisolated static func samples(_ tone: Tone, rate: Double) -> [Float] {
        let (frequencies, seconds, level) = notes(tone)
        let step = Int(seconds * rate * 0.85)
        let length = Int(seconds * rate)
        var out = [Float](repeating: 0, count: step * (frequencies.count - 1) + length)
        for (n, f) in frequencies.enumerated() {
            for i in 0..<length {
                let t = Double(i) / rate
                // Fast attack, smooth exponential decay, no clicks at either end.
                let attack = min(1, t / 0.004)
                let release = min(1, Double(length - i) / (0.012 * rate))
                let envelope = attack * release * exp(-t * 18)
                out[n * step + i] += Float(level * envelope * sin(2 * .pi * f * t))
            }
        }
        return out
    }

    /// 16-bit PCM WAV.
    nonisolated private static func wav(_ samples: [Float], rate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_767))) }
        return data
    }
}
