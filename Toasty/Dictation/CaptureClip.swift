import AVFoundation

/// Turning captured audio into what the engine takes: 16 kHz mono Float32.
/// (Framing — pre-roll, tail, gap padding, gates — joins this in phase D2.)
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
}
