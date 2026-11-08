import AVFoundation

/// Turning captured audio into what the engine takes: 16 kHz mono Float32,
/// framed from the press (minus pre-roll) to the release (plus tail), and
/// gated so silence and noise never reach the engine (plan §8.4–8.6).
nonisolated enum CaptureClip {
    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self { case .unreadable(let reason): "Can't read audio: \(reason)" }
        }
    }

    static let engineFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(DictationConfig.sampleRate),
        channels: 1, interleaved: false)!

    /// Resamples mono Float32 at `rate` to 16 kHz in one pass over the whole
    /// clip (exact; flushed with end of stream). Unchanged when already 16 kHz.
    static func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        if rate == engineFormat.sampleRate || samples.isEmpty { return samples }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw Failure.unreadable("bad format \(rate) Hz") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return try convert(input, from: source)
    }

    /// Any audio file → 16 kHz mono Float32 (channels averaged). For tests
    /// and the debug commands.
    static func read(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable(url.lastPathComponent) }
        let format = file.processingFormat
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw Failure.unreadable("empty \(url.lastPathComponent)")
        }
        // One read may return fewer frames than asked: read to the end.
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: chunk)
            if chunk.frameLength == 0 { break }
            mono += downmix(chunk)
        }
        return try resample(mono, from: format.sampleRate)
    }

    /// Plain average of the channels (Hex audio.rs:1380-1385).
    static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, frames > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            for i in 0..<frames { mono[i] += data[c][i] }
        }
        let scale = 1 / Float(channels)
        for i in 0..<frames { mono[i] *= scale }
        return mono
    }

    private static func convert(_ input: AVAudioPCMBuffer, from source: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(from: source, to: engineFormat) else {
            throw Failure.unreadable("can't convert from \(source.sampleRate) Hz")
        }
        let expected = Double(input.frameLength) * engineFormat.sampleRate / source.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(expected) + 4096) else {
            throw Failure.unreadable("can't allocate")
        }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .endOfStream; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw Failure.unreadable(error?.localizedDescription ?? "conversion failed") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// A native-rate framed recording → 16 kHz `FramedClip` (lengths scaled).
    static func framed(_ samples: [Float], rate: Double, tailSamples: Int, prePressSamples: Int,
                       maxGap: TimeInterval, cold: Bool) throws -> FramedClip {
        let out = try resample(samples, from: rate)
        let scale = engineFormat.sampleRate / rate
        let scaled = { (n: Int) in min(out.count, Int((Double(n) * scale).rounded())) }
        return FramedClip(samples: out, tailSamples: scaled(tailSamples), prePressSamples: scaled(prePressSamples),
                          maxGap: maxGap, cold: cold)
    }

    // MARK: Gates (hex/src/dictation.rs:396-520)

    enum Gate: Equatable, CustomStringConvertible {
        /// Speech (or the detector is unavailable): transcribe.
        case keep
        /// Every sample is exactly zero: a stream delivering digital silence
        /// (Hex #1122), not a quiet room. Discard and reopen the microphone.
        case digitalSilence
        /// Loudest 30 ms window below −50 dBFS: discard silently.
        case silent(dbfs: Float)
        /// Loud enough, but the detector heard no speech: discard silently.
        case noSpeech

        var description: String {
            switch self {
            case .keep: "keep"
            case .digitalSilence: "digital silence"
            case .silent(let dbfs): String(format: "silent (%.1f dBFS)", dbfs)
            case .noSpeech: "no speech"
            }
        }
    }

    /// The gates in Hex's order: level first (a silent clip never reaches the
    /// detector), then the speech detector. Only audio through the release
    /// counts; the tail is left out.
    static func gate(_ clip: FramedClip, detector: @Sendable ([Float]) async -> Bool?) async -> Gate {
        let released = Array(clip.released)
        if !released.isEmpty, released.allSatisfy({ $0 == 0 }) { return .digitalSilence }
        let level = loudestWindowDBFS(released)
        if level < DictationConfig.silenceThresholdDBFS { return .silent(dbfs: level) }
        return await detector(released) == false ? .noSpeech : .keep
    }

    /// The loudest 30 ms window's DC-removed RMS in dBFS (−120 for empty or
    /// constant audio). Windows are consecutive, not sliding (Hex's `chunks`).
    static func loudestWindowDBFS<C: Collection<Float>>(_ samples: C) -> Float where C.Index == Int {
        var loudest = 0.0
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + DictationConfig.silenceWindowSamples, samples.endIndex)
            let count = Double(end - start)
            var sum = 0.0
            for i in start..<end { sum += Double(samples[i]) }
            let mean = sum / count
            var variance = 0.0
            for i in start..<end { let d = Double(samples[i]) - mean; variance += d * d }
            loudest = max(loudest, (variance / count).squareRoot())
            start = end
        }
        return Float(20 * log10(max(loudest, 1e-6)))
    }
}

/// A framed clip: 16 kHz mono from pre-roll to release + tail.
nonisolated struct FramedClip: Sendable {
    var samples: [Float]
    /// Samples at the end that came after the release (excluded from gates).
    var tailSamples: Int
    /// Samples before the press (the pre-roll actually kept).
    var prePressSamples: Int
    /// Largest step between microphone buffers inside the clip.
    var maxGap: TimeInterval
    /// Started without pre-roll because the microphone was cold.
    var cold: Bool

    var released: ArraySlice<Float> { samples.dropLast(min(tailSamples, samples.count)) }
    var seconds: Double { Double(samples.count) / Double(DictationConfig.sampleRate) }
}

/// The microphone timeline: a ring of the last 10 s of native-rate mono
/// audio, each sample placed by its capture time, and the recording cut from
/// it. A pure value (no audio APIs) so framing is unit-tested with synthetic
/// buffers; `MicCapture` holds one behind a lock.
///
/// Times are seconds on the host clock (`AVAudioTime.seconds(forHostTime:)`),
/// the same clock as `NSEvent.timestamp` and `ProcessInfo.systemUptime`.
nonisolated struct CaptureTimeline: Sendable {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// Audio stopped for longer than 250 ms mid-capture.
        case gap(milliseconds: Int)
        /// The microphone closed or changed mid-capture.
        case interrupted

        var description: String {
            switch self {
            case .gap(let ms): "The microphone stopped for \(ms) ms."
            case .interrupted: "The microphone was interrupted."
            }
        }
    }

    enum Finish: Equatable {
        /// Released before the minimum hold: discard silently.
        case tooShort
        case failed(Failure)
        /// Native-rate clip, tail and pre-press lengths in native samples.
        case clip(samples: [Float], tailSamples: Int, prePressSamples: Int, maxGap: TimeInterval, cold: Bool)
    }

    let rate: Double
    private var ring: [Float]
    private var ringHead = 0
    private(set) var ringCount = 0
    /// Samples placed on the timeline since it began (zero padding included):
    /// absolute sample indices count from here.
    private(set) var written = 0
    /// The capture time just after the newest sample; nil until audio arrives.
    private(set) var through: TimeInterval?
    private(set) var recording: Recording?

    struct Recording: Sendable {
        /// Absolute index of the clip's first sample.
        var first: Int
        var samples: [Float]
        var press: TimeInterval
        var prePress: Int
        var cold: Bool
        var maxGap: TimeInterval = 0
        var failure: Failure?
        /// Cold: capture time of the first sample.
        var firstAudio: TimeInterval?
    }

    /// The last cold recording's delay from press to its first audio.
    private(set) var lastColdDelay: TimeInterval?

    init(rate: Double, seconds: TimeInterval = DictationConfig.ringSeconds) {
        self.rate = rate
        ring = [Float](repeating: 0, count: max(1, Int(seconds * rate)))
    }

    var isRecording: Bool { recording != nil }

    /// Places a block of mono samples captured from `start`. A step past the
    /// previous block's end of 50–250 ms is filled with zeros; a longer one
    /// is a discontinuity: the ring restarts and a recording fails.
    mutating func append(_ samples: UnsafeBufferPointer<Float>, at start: TimeInterval) {
        if let through {
            let gap = start - through
            if gap > DictationConfig.gapTolerance {
                if gap <= DictationConfig.maxPaddedGap {
                    noteGap(gap)
                    writeZeros(Int((gap * rate).rounded()))
                } else {
                    ringCount = 0
                    if recording != nil, recording?.failure == nil {
                        recording?.failure = .gap(milliseconds: Int((gap * 1000).rounded()))
                    }
                }
            } else if gap > 0 {
                noteGap(gap)
            }
        }
        if recording?.cold == true, recording?.firstAudio == nil, !samples.isEmpty { recording?.firstAudio = start }
        write(samples)
        through = start + Double(samples.count) / rate
    }

    mutating func append(_ samples: [Float], at start: TimeInterval) {
        samples.withUnsafeBufferPointer { append($0, at: start) }
    }

    /// The microphone closed (or switched): the ring is stale, and a
    /// recording can't continue across it.
    mutating func interrupt() {
        ringCount = 0
        through = nil
        if recording != nil, recording?.failure == nil { recording?.failure = .interrupted }
    }

    /// Starts recording at `press`, keeping up to `preRoll` before it from
    /// the ring. Cold (no audio yet): starts at the first delivered sample,
    /// with no pre-roll. A press ahead of the newest audio skips what arrives
    /// before `press − preRoll`.
    mutating func start(press: TimeInterval, preRoll: TimeInterval = DictationConfig.preRoll) {
        guard let through, ringCount > 0 else {
            recording = Recording(first: written, samples: [], press: press, prePress: 0, cold: true)
            return
        }
        let oldest = written - ringCount
        let first = max(index(at: press - preRoll, through: through), oldest)
        var samples: [Float] = []
        samples.reserveCapacity(Int(rate * 30))
        if first < written { samples += ringSlice(from: first) }
        // Audio between the newest buffer and a press ahead of it is still
        // pre-press: it arrives later.
        let prePress = max(0, index(at: press, through: through) - first)
        recording = Recording(first: first, samples: samples, press: press, prePress: prePress, cold: false)
    }

    func hasAudio(through time: TimeInterval) -> Bool { (through ?? -.infinity) >= time }

    mutating func cancel() { recording = nil }

    /// Carries a recording across a reopen (it has failed: `interrupt()`).
    mutating func adopt(_ recording: Recording) { self.recording = recording }

    /// Ends the recording at `release`, keeping `tail` after it (as much of
    /// it as has arrived). The hold is measured on event times.
    mutating func finish(release: TimeInterval, tail: TimeInterval = DictationConfig.releaseTail,
                         minimumHold: TimeInterval = DictationConfig.minimumHold) -> Finish? {
        guard let recording else { return nil }
        self.recording = nil
        if recording.cold, let first = recording.firstAudio { lastColdDelay = first - recording.press }
        // Microsecond slack: 0.3 s held must count as 0.3 s despite float rounding.
        if release - recording.press + 1e-6 < minimumHold { return .tooShort }
        if let failure = recording.failure { return .failed(failure) }
        guard let through else {
            return .clip(samples: [], tailSamples: 0, prePressSamples: 0, maxGap: recording.maxGap, cold: recording.cold)
        }
        let first = recording.first
        let last = first + recording.samples.count
        let end = min(max(index(at: release + tail, through: through), first), last)
        let releaseEnd = min(max(index(at: release, through: through), first), end)
        return .clip(samples: Array(recording.samples[0..<(end - first)]),
                     tailSamples: end - releaseEnd,
                     prePressSamples: min(recording.prePress, end - first),
                     maxGap: recording.maxGap, cold: recording.cold)
    }

    // MARK: Storage

    private mutating func noteGap(_ gap: TimeInterval) {
        guard let current = recording?.maxGap else { return }
        recording?.maxGap = max(current, gap)
    }

    /// The absolute sample index captured at `time`.
    private func index(at time: TimeInterval, through: TimeInterval) -> Int {
        written - Int(((through - time) * rate).rounded())
    }

    private func ringSlice(from first: Int) -> [Float] {
        let count = written - first
        let start = (ringHead - count + ring.count) % ring.count
        if start + count <= ring.count { return Array(ring[start..<(start + count)]) }
        return Array(ring[start...]) + Array(ring[..<(count - (ring.count - start))])
    }

    private mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        if var rec = recording {
            recording = nil  // keep `samples` uniquely referenced while appending
            let skip = max(0, rec.first - written)
            if skip < samples.count, rec.failure == nil { rec.samples.append(contentsOf: samples[skip...]) }
            recording = rec
        }
        var source = samples[...]
        if source.count > ring.count { source = source.suffix(ring.count) }
        for value in source {
            ring[ringHead] = value
            ringHead = (ringHead + 1) % ring.count
        }
        ringCount = min(ring.count, ringCount + source.count)
        written += samples.count
    }

    private mutating func writeZeros(_ count: Int) {
        guard count > 0 else { return }
        let zeros = [Float](repeating: 0, count: count)
        zeros.withUnsafeBufferPointer { write($0) }
    }
}
