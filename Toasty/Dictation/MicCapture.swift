import AVFoundation
import AudioToolbox
import CoreAudio
import os
import Synchronization

/// The microphone (plan §8). Kept open ("warm") while Toasty is the active
/// app, so every capture gets 450 ms of pre-roll; closed 30 s after Toasty
/// stops being active. Opens only once microphone access is granted: it
/// never prompts by itself (the first dictation asks).
///
/// Taps the input at its native format, with no voice processing (it would
/// force Bluetooth headsets into call audio and add its own gain and noise
/// suppression), averages channels to mono and places each buffer on a
/// `CaptureTimeline` by its capture host time.
///
/// Device rule (Hex audio.rs:983-1068): a Bluetooth default input is passed
/// over for the built-in microphone or another wired input, and kept only
/// when nothing else is usable. Devices switch only while not recording.
///
/// All engine work runs on one serial queue; the tap only takes the
/// timeline lock briefly.
nonisolated final class MicCapture: @unchecked Sendable {
    static let shared = MicCapture()
    private static let log = Logger(subsystem: "com.martyvasquez.toasty", category: "mic")

    enum Transport: String, Sendable {
        case builtIn = "built-in", bluetooth, virtual, continuity, other
    }

    struct InputDevice: Equatable, Sendable {
        var id: AudioDeviceID
        var uid: String
        var name: String
        var transport: Transport
    }

    struct Status: Sendable {
        var open = false
        var warm = false
        var simulating = false
        var device: InputDevice?
        var sampleRate: Double = 0
        var opens = 0
        var reopens = 0
        var stalls = 0
        var lastError: String?
        /// Host time when the newest buffer arrived minus its capture end:
        /// the input latency (positive, a few ms to ~100 ms).
        var latency: TimeInterval?
        var lastBufferAt: TimeInterval?
        /// Last cold capture: press → its first audio (speech lost to the open).
        var lastColdDelay: TimeInterval?
    }

    enum Outcome: Sendable {
        case tooShort
        case failed(CaptureTimeline.Failure)
        case clip(FramedClip)
        /// No capture was running.
        case none
    }

    private let queue = DispatchQueue(label: "toasty.mic", qos: .userInitiated)
    private let timeline = OSAllocatedUnfairLock<CaptureTimeline?>(initialState: nil)
    private let state = OSAllocatedUnfairLock(initialState: Status())
    private let levelBits = Atomic<UInt32>(0)
    /// Bumped on every open/close, so a stale tap callback is ignored.
    private let generation = Atomic<Int>(0)
    private let last = OSAllocatedUnfairLock<FramedClip?>(initialState: nil)

    // Queue-confined.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var wantWarm = false
    private var active = false
    /// A capture started while the microphone was closed: start at the
    /// first delivered buffer (no pre-roll).
    private var coldPress: TimeInterval?
    private var closeWork: DispatchWorkItem?
    private var closeDue = false
    private var retryWork: DispatchWorkItem?
    private var backoff = DictationConfig.reopenBackoffInitial
    private var reselectDue = false
    private var stallTimer: DispatchSourceTimer?
    private var listening = false
    private var simulating = false

    private init() {}

    // MARK: Public API (any thread)

    var currentStatus: Status { state.withLock { $0 } }

    /// The newest buffer's loudness, 0 (≤ −50 dB) to 1 (0 dB), for the meter.
    var level: Float { Float(bitPattern: levelBits.load(ordering: .relaxed)) }

    /// The last framed clip (16 kHz), for "dump last clip".
    var lastClip: FramedClip? { last.withLock { $0 } }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks for microphone access if it was never asked; true when granted.
    static func requestPermission() async -> Bool {
        switch permission {
        case .authorized: return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            UserDefaults.standard.set(granted, forKey: grantedKey)
            // The prompt took focus; open now that access exists.
            if granted { shared.queue.async { shared.openIfNeeded() } }
            return granted
        default: return false
        }
    }

    /// Set once the user granted access. A new process can read
    /// `.notDetermined` despite an existing grant until it calls
    /// `requestAccess` (which then answers at once, without a prompt), so a
    /// warm open re-asks only for someone who already said yes: Toasty never
    /// prompts before the first dictation.
    private static let grantedKey = "ToastyDictationMicrophoneGranted"

    /// Access was granted before (it may read as not determined at launch).
    static var previouslyGranted: Bool { UserDefaults.standard.bool(forKey: grantedKey) }

    /// Toasty became the active app: open (or keep) the microphone when it
    /// stays warm while active (`keepMicWarmWhileActive`).
    func appBecameActive() {
        queue.async { [self] in
            active = true
            installListeners()
            guard DictationConfig.keepMicWarmWhileActive else { return }
            closeWork?.cancel(); closeWork = nil; closeDue = false
            wantWarm = true
            state.withLock { $0.warm = true }
            openIfNeeded()
        }
    }

    /// Toasty stopped being active: close the microphone (warm mode: in 30 s,
    /// unless it becomes active again first). Never closes mid-capture.
    func appResignedActive() {
        queue.async { [self] in
            active = false
            scheduleClose(after: DictationConfig.keepMicWarmWhileActive ? DictationConfig.coldCloseDelay : 0)
        }
    }

    private func scheduleClose(after delay: TimeInterval) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeWhenIdle() }
        closeWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Starts a capture at `press` (host-clock seconds, e.g. `NSEvent.timestamp`).
    /// Returns false when the microphone is cold: the capture then starts at
    /// its first buffer, without pre-roll.
    @discardableResult
    func begin(press: TimeInterval) -> Bool {
        let warm = timeline.withLock { timeline -> Bool in
            guard timeline != nil, timeline?.through != nil else { return false }
            timeline?.start(press: press)
            return true
        }
        queue.async { [self] in closeWork?.cancel(); closeWork = nil }
        if !warm {
            queue.async { [self] in
                // Open already but no buffer yet: start at the first one.
                let started = timeline.withLock { timeline -> Bool in
                    guard timeline != nil else { return false }
                    if timeline?.isRecording == false { timeline?.start(press: press) }
                    return true
                }
                if started { return }
                coldPress = press
                openIfNeeded()
            }
        }
        return warm
    }

    /// Ends the capture at `release` and frames it: waits up to tail + grace
    /// for the tail's audio, then cuts pre-roll…release + tail and resamples
    /// to 16 kHz.
    func finish(release: TimeInterval) async -> Outcome {
        let end = release + DictationConfig.releaseTail
        let deadline = end + DictationConfig.tailDeliveryGrace
        await waitForPendingStart()
        while !timeline.withLock({ $0?.hasAudio(through: end) ?? true }),
              ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let (finish, rate) = timeline.withLock { ($0?.finish(release: release), $0?.rate ?? 0) }
        queue.async { [self] in afterCapture() }
        switch finish {
        case nil: return .none
        case .tooShort: return .tooShort
        case .failed(let failure): return .failed(failure)
        case .clip(let samples, let tail, let prePress, let maxGap, let cold):
            do {
                let clip = try CaptureClip.framed(samples, rate: rate, tailSamples: tail,
                                                  prePressSamples: prePress, maxGap: maxGap, cold: cold)
                last.withLock { $0 = clip }
                return .clip(clip)
            } catch {
                Self.log.error("can't resample capture: \(String(describing: error), privacy: .public)")
                return .failed(.interrupted)
            }
        }
    }

    func cancel() {
        queue.async { [self] in coldPress = nil }
        timeline.withLock { $0?.cancel() }
        queue.async { [self] in afterCapture() }
    }

    /// A clip came back as digital silence: the stream is alive but
    /// delivering zeros (Hex #1122). Reopen it.
    func reopenSilentStream() {
        queue.async { [self] in
            Self.log.warning("microphone delivered digital silence; reopening")
            reopen()
        }
    }

    // MARK: Simulation (DEBUG: feed a file through the same timeline)

    /// Closes the microphone and lets `feed` place audio on a fresh timeline.
    func beginSimulation(rate: Double) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                simulating = true
                close()
                timeline.withLock { $0 = CaptureTimeline(rate: rate) }
                state.withLock { $0.simulating = true; $0.sampleRate = rate }
                done.resume()
            }
        }
    }

    func feed(_ samples: [Float], at start: TimeInterval) {
        timeline.withLock { $0?.append(samples, at: start) }
    }

    func endSimulation() {
        queue.async { [self] in
            simulating = false
            timeline.withLock { $0 = nil }
            state.withLock { $0.simulating = false }
            openIfNeeded()
        }
    }

    // MARK: Queue: open / close

    private var shouldBeOpen: Bool { !simulating && (wantWarm || coldPress != nil || recordingActive) }
    private var recordingActive: Bool { timeline.withLock { $0?.isRecording ?? false } }

    private func openIfNeeded() {
        guard engine == nil, shouldBeOpen else { return }
        guard Self.permission == .authorized else {
            if Self.permission == .notDetermined, UserDefaults.standard.bool(forKey: Self.grantedKey) {
                Task { _ = await Self.requestPermission() }
            } else {
                Self.log.info("microphone not opened: access is \(Self.permission.rawValue)")
            }
            return
        }
        retryWork?.cancel(); retryWork = nil
        let candidates = Self.candidates(Self.inputDevices(), defaultID: Self.defaultInputID())
        guard !candidates.isEmpty else {
            fail("No microphone is available.")
            return
        }
        for device in candidates {
            for attempt in 1...DictationConfig.openAttempts {
                do {
                    try start(device)
                    backoff = DictationConfig.reopenBackoffInitial
                    return
                } catch {
                    Self.log.warning("open \(device.name, privacy: .public) attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                    if attempt < DictationConfig.openAttempts { Thread.sleep(forTimeInterval: DictationConfig.openRetryDelay) }
                }
            }
        }
        fail("Can't open the microphone.")
    }

    private func fail(_ message: String) {
        state.withLock { $0.lastError = message }
        let work = DispatchWorkItem { [weak self] in self?.openIfNeeded() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, DictationConfig.reopenBackoffMax)
    }

    private func start(_ device: InputDevice) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.noAudioUnit }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.status("set device", status) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noFormat }

        let gen = generation.add(1, ordering: .sequentiallyConsistent).newValue
        let rate = format.sampleRate
        timeline.withLock { current in
            var fresh = CaptureTimeline(rate: rate)
            // A capture across a reopen has already failed (interrupted); carry it.
            if let recording = current?.recording { fresh.adopt(recording) }
            current = fresh
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            self?.receive(buffer, when: when, generation: gen)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            timeline.withLock { $0?.interrupt() }
            throw error
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.configurationChanged() }
        }
        if let press = coldPress {
            timeline.withLock { $0?.start(press: press) }
            coldPress = nil
        }
        state.withLock {
            $0.open = true; $0.device = device; $0.sampleRate = rate
            $0.opens += 1; $0.lastError = nil; $0.lastBufferAt = nil; $0.latency = nil
        }
        startStallWatch()
        Self.log.info("microphone open: \(device.name, privacy: .public) (\(device.transport.rawValue, privacy: .public)), \(rate) Hz, \(format.channelCount) ch")
    }

    private func close() {
        stallTimer?.cancel(); stallTimer = nil
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        guard let engine else { return }
        generation.add(1, ordering: .sequentiallyConsistent)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        timeline.withLock { timeline in
            if timeline?.isRecording == true { timeline?.interrupt() } else { timeline = nil }
        }
        levelBits.store(0, ordering: .relaxed)
        state.withLock { $0.open = false }
        Self.log.info("microphone closed")
    }

    private func reopen() {
        guard !simulating else { return }
        close()
        state.withLock { $0.reopens += 1 }
        openIfNeeded()
    }

    private func closeWhenIdle() {
        closeWork = nil
        if !(DictationConfig.keepMicWarmWhileActive && active) {
            wantWarm = false
            state.withLock { $0.warm = false }
        }
        if recordingActive || coldPress != nil { closeDue = true; return }
        if !wantWarm { close() }
    }

    /// After a capture finishes or is cancelled: apply what waited for it.
    private func afterCapture() {
        if recordingActive { return }
        if let delay = timeline.withLock({ $0?.lastColdDelay }) {
            state.withLock { $0.lastColdDelay = delay }
        }
        // Linger mode: stay open a while, so a follow-up dictation is warm.
        if !DictationConfig.keepMicWarmWhileActive, active, engine != nil {
            wantWarm = true
            state.withLock { $0.warm = true }
            scheduleClose(after: DictationConfig.micLinger)
        }
        // A capture that outlived its microphone is done: drop its timeline.
        if engine == nil, !simulating { timeline.withLock { $0 = nil } }
        if closeDue, !wantWarm { closeDue = false; close(); return }
        if reselectDue { reselectDue = false; reselect() }
        if engine == nil { openIfNeeded() }
    }

    /// Waits until a cold press queued on the mic queue has been applied.
    private func waitForPendingStart() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    // MARK: Queue: device changes and stalls

    private func installListeners() {
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyServiceRestarted] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let restart = selector == kAudioHardwarePropertyServiceRestarted
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
                if restart { self?.serviceRestarted() } else { self?.devicesChanged() }
            }
        }
    }

    private func devicesChanged() {
        if recordingActive { reselectDue = true; return }
        reselect()
    }

    /// Switches to the device the rule picks now, if it differs.
    private func reselect() {
        guard !simulating else { return }
        guard engine != nil else { openIfNeeded(); return }
        let best = Self.candidates(Self.inputDevices(), defaultID: Self.defaultInputID()).first
        if best?.id != state.withLock({ $0.device?.id }) {
            Self.log.info("input device changed; switching to \(best?.name ?? "none", privacy: .public)")
            reopen()
        }
    }

    private func serviceRestarted() {
        Self.log.warning("audio service restarted; reopening the microphone")
        reopen()
    }

    /// Posted for real changes (the engine stops itself) but also just after
    /// an open, while the engine keeps running. Reopen only when it stopped
    /// or the input format changed; a capture across a reopen fails.
    private func configurationChanged() {
        guard let engine else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        let current = state.withLock { $0.sampleRate }
        if engine.isRunning, format.sampleRate == current { return }
        Self.log.info("audio configuration changed (running \(engine.isRunning), \(format.sampleRate) Hz); reopening")
        reopen()
    }

    private func startStallWatch() {
        stallTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let opened = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, engine != nil else { return }
            let lastAt = state.withLock { $0.lastBufferAt } ?? opened
            if ProcessInfo.processInfo.systemUptime - lastAt > DictationConfig.stallTimeout {
                Self.log.warning("no microphone audio for \(DictationConfig.stallTimeout) s; reopening")
                state.withLock { $0.stalls += 1 }
                reopen()
            }
        }
        timer.resume()
        stallTimer = timer
    }

    // MARK: Tap (AVAudioEngine's tap thread)

    private func receive(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, generation gen: Int) {
        guard generation.load(ordering: .relaxed) == gen else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate
        let now = ProcessInfo.processInfo.systemUptime
        let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : now - Double(frames) / rate
        let channels = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        if channels == 1 {
            let mono = UnsafeBufferPointer(start: data[0], count: frames)
            for v in mono { sumSquares += v * v }
            timeline.withLockUnchecked { $0?.append(mono, at: start) }
        } else {
            let mono = CaptureClip.downmix(buffer)
            for v in mono { sumSquares += v * v }
            timeline.withLock { $0?.append(mono, at: start) }
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        levelBits.store(min(max((db + 50) / 50, 0), 1).bitPattern, ordering: .relaxed)
        let latency = now - (start + Double(frames) / rate)
        state.withLock { $0.lastBufferAt = now; $0.latency = latency }
    }

    enum CaptureError: Error, CustomStringConvertible {
        case noAudioUnit, noFormat
        case status(String, OSStatus)
        var description: String {
            switch self {
            case .noAudioUnit: "no input audio unit"
            case .noFormat: "the input has no audio format"
            case .status(let what, let status): "\(what) failed (\(status))"
            }
        }
    }

    // MARK: Devices (CoreAudio)

    /// The inputs to try, best first (Hex `resolve_input`, avoid_bluetooth on):
    /// a non-Bluetooth default; else the built-in microphone; else another
    /// wired input; else the Bluetooth default; else any other Bluetooth
    /// input. A virtual/aggregate input or an iPhone (Continuity) never
    /// stands in, though one that *is* the default is used.
    static func candidates(_ devices: [InputDevice], defaultID: AudioDeviceID?) -> [InputDevice] {
        let byDefault = devices.first { $0.id == defaultID }
        let standIn = devices.filter { $0.transport != .virtual && $0.transport != .continuity }
        var ordered: [InputDevice] = []
        if let byDefault, byDefault.transport != .bluetooth { ordered.append(byDefault) }
        ordered += standIn.filter { $0.transport == .builtIn }
        ordered += standIn.filter { $0.transport == .other }
        if let byDefault, byDefault.transport == .bluetooth { ordered.append(byDefault) }
        ordered += standIn.filter { $0.transport == .bluetooth }
        var seen = Set<AudioDeviceID>()
        return ordered.filter { seen.insert($0.id).inserted }
    }

    static func defaultInputID() -> AudioDeviceID? {
        let id: AudioDeviceID? = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return id == 0 ? nil : id
    }

    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let kind: UInt32 = read(id, kAudioDevicePropertyTransportType) ?? 0
            return InputDevice(id: id, uid: uid, name: name, transport: transport(kind))
        }
    }

    static func transport(_ kind: UInt32) -> Transport {
        switch kind {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
        default: .other
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return value.load(as: T.self)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
