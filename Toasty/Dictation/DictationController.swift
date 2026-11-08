import AppKit
import os

/// Runs dictation inside Toasty (plan §9): the trigger state machine, one
/// capture at a time, transcription jobs (several may be in flight), and
/// insertion into the composer in the order dictations were made. Never
/// submits: text is only inserted at the caret.
///
/// Target (the user's choice): only a Claude composer. The composer with the
/// focus at the press, else the visible conversation's composer, which is
/// then focused. With no composer on screen, the press does nothing.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()
    nonisolated private static let log = Logger(subsystem: "com.martyvasquez.toasty", category: "dictation")

    enum Phase: Equatable {
        case idle, listening, transcribing
        case failed(String)
    }

    /// What the indicator shows, for the composer `target`.
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var target: UUID?
    @Published private(set) var locked = false
    /// Microphone level 0…1 while listening.
    @Published private(set) var level: Float = 0

    /// The last successful dictation (memory only).
    private(set) var lastDictation: (raw: String, final: String)?
    /// The vocabulary the last dictation used (debug).
    private(set) var lastVocabulary: Vocabulary.Effective?
    /// Event time vs. handling time of the last trigger press (clock check).
    private(set) var lastEventDelay: TimeInterval?

    private var machine = TriggerStateMachine()
    private var monitor: TriggerMonitor?
    private var capture: Capture?
    private var nextJob = 0
    private var nextToInsert = 0
    private var finished: [Int: Job] = [:]
    private var pending = 0
    private var levelTimer: Timer?
    private var phaseWork: DispatchWorkItem?
    private var transcribingSince: TimeInterval?

    private struct Capture {
        let id: Int
        weak var view: ComposerTextView?
        let conversation: UUID?
        /// The target's workspace folder (its project vocabulary).
        let folder: String?
        /// Context vocabulary, gathered in the background while you speak.
        let context: Task<[ContextVocabulary.Found], Never>
    }

    private struct Job {
        weak var view: ComposerTextView?
        var text: String?
        var failure: String?
        var vocabulary = Vocabulary.Effective()
    }

    private init() {}

    func start() {
        guard monitor == nil else { return }
        let monitor = TriggerMonitor { [weak self] event, nsEvent in
            self?.handle(event, nsEvent: nsEvent) ?? false
        }
        monitor.start()
        self.monitor = monitor
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.handle(.resignActive(ProcessInfo.processInfo.systemUptime), nsEvent: nil)
            }
        }
    }

    /// The mic button: start a locked dictation, or finish one.
    func toggleFromButton() {
        _ = handle(.button(ProcessInfo.processInfo.systemUptime), nsEvent: nil)
    }

    var isRecording: Bool { machine.isRecording }
    var triggerState: String { "\(machine.state)" }

    // MARK: Trigger

    /// Returns true to swallow the event (only a cancelling Escape).
    @discardableResult
    func handle(_ event: TriggerStateMachine.Event, nsEvent: NSEvent?) -> Bool {
        if case .triggerDown(let at) = event { lastEventDelay = ProcessInfo.processInfo.systemUptime - at }
        guard let action = machine.handle(event) else {
            locked = machine.isLocked
            return false
        }
        locked = machine.isLocked
        switch action {
        case .start(let press): begin(press: press)
        case .finish(let release): finish(release: release)
        case .discard: drop(reason: "chord")
        case .cancel: drop(reason: "cancelled")
        }
        return action == .cancel
    }

    private func begin(press: TimeInterval) {
        guard let view = Self.currentComposer() else {
            Self.log.info("dictation press ignored: no composer on screen")
            capture = nil
            return
        }
        if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        switch MicCapture.permission {
        case .authorized: break
        case .notDetermined where MicCapture.previouslyGranted:
            break  // the microphone re-asks silently as it opens
        case .notDetermined:
            // First dictation: ask (the prompt takes this press).
            capture = nil
            Task { _ = await MicCapture.requestPermission() }
            return
        default:
            capture = nil
            show(.failed("Microphone access is off in System Settings › Privacy & Security."), for: view.dictationID)
            return
        }
        nextJob += 1
        let workspace = WorkspaceStore.shared.workspaces
            .first { $0.conversations.contains { $0.id == view.dictationID } }
        let input = Self.contextInput(workspace: workspace, conversation: view.dictationID)
        let context = Task.detached(priority: .userInitiated) { ContextVocabulary.gather(input) }
        capture = Capture(id: nextJob, view: view, conversation: view.dictationID,
                          folder: workspace?.folder, context: context)
        MicCapture.shared.begin(press: press)
        target = view.dictationID
        setPhase(.listening)
        startLevelMeter()
    }

    private func finish(release: TimeInterval) {
        guard let capture else { return }
        self.capture = nil
        stopLevelMeter()
        pending += 1
        setPhase(.transcribing)
        Task {
            let vocabulary = Vocabulary.effective(projectFolder: capture.folder, context: await capture.context.value)
            lastVocabulary = vocabulary
            let outcome = await MicCapture.shared.finish(release: release)
            let job = await Self.transcribe(outcome, view: capture.view, vocabulary: vocabulary)
            complete(capture.id, job)
        }
    }

    private func drop(reason: String) {
        guard let capture else { return }
        Self.log.info("dictation dropped (\(reason, privacy: .public))")
        self.capture = nil
        finished[capture.id] = Job()
        MicCapture.shared.cancel()
        stopLevelMeter()
        flush()
        settlePhase()
    }

    // MARK: Jobs

    /// Gates → engine. A silent or too-short capture yields no text and no failure.
    nonisolated private static func transcribe(_ outcome: MicCapture.Outcome, view: ComposerTextView?,
                                               vocabulary: Vocabulary.Effective) async -> Job {
        switch outcome {
        case .none, .tooShort:
            return Job(view: view)
        case .failed(let failure):
            return Job(view: view, failure: failure.description)
        case .clip(let clip):
            let gate = await CaptureClip.gate(clip) { await SpeechEngine.shared.containsSpeech($0) }
            switch gate {
            case .keep: break
            case .digitalSilence:
                MicCapture.shared.reopenSilentStream()
                return Job(view: view)
            case .silent, .noSpeech:
                log.info("dictation discarded: \(gate.description, privacy: .public)")
                return Job(view: view)
            }
            do {
                let result = try await SpeechEngine.shared.transcribe(clip.samples, vocabulary: vocabulary.engine)
                return Job(view: view, text: result.text, vocabulary: vocabulary)
            } catch {
                return Job(view: view, failure: String(describing: error))
            }
        }
    }

    private func complete(_ id: Int, _ job: Job) {
        pending -= 1
        finished[id] = job
        flush()
        settlePhase(failure: job.failure)
    }

    /// Inserts finished jobs strictly in the order they were made (a
    /// dropped capture leaves an empty result, so nothing waits on it).
    private func flush() {
        while let job = finished.removeValue(forKey: nextToInsert + 1) {
            nextToInsert += 1
            if let raw = job.text, !raw.isEmpty { insert(raw, into: job.view, vocabulary: job.vocabulary) }
        }
    }

    private func insert(_ raw: String, into view: ComposerTextView?, vocabulary: Vocabulary.Effective) {
        guard let view = (view?.window != nil ? view : nil) ?? Self.currentComposer() else {
            lastDictation = (raw, raw)
            Self.log.info("dictation kept as last dictation: no composer")
            return
        }
        let caret = view.selectedRange()
        let before = (view.string as NSString).substring(to: min(caret.location, (view.string as NSString).length))
        let text = TextPipeline.forComposer(TextPipeline.process(raw, vocabulary: vocabulary), before: before)
        guard !text.isEmpty else { return }
        view.insertText(text, replacementRange: caret)
        lastDictation = (raw, text)
    }

    // MARK: Indicator

    private func setPhase(_ new: Phase) {
        phaseWork?.cancel(); phaseWork = nil
        if new == .transcribing, phase != .transcribing { transcribingSince = ProcessInfo.processInfo.systemUptime }
        phase = new
    }

    /// After a job ends: listening wins, then transcribing, then a brief
    /// failure, then idle (transcribing stays up at least 200 ms).
    private func settlePhase(failure: String? = nil) {
        if capture != nil { return setPhase(.listening) }
        if pending > 0 { return setPhase(.transcribing) }
        if let failure {
            Self.log.error("dictation failed: \(failure, privacy: .public)")
            NSSound.beep()
            return show(.failed(failure), for: target)
        }
        let shown = transcribingSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        let wait = phase == .transcribing ? max(0, DictationConfig.transcribingMinimumVisible - shown) : 0
        later(wait) { [weak self] in self?.phase = .idle; self?.target = nil }
    }

    private func show(_ failure: Phase, for conversation: UUID?) {
        setPhase(failure)
        target = conversation
        later(DictationConfig.failureVisible) { [weak self] in self?.phase = .idle; self?.target = nil }
    }

    private func later(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        phaseWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        phaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startLevelMeter() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.level = MicCapture.shared.level }
        }
    }

    private func stopLevelMeter() {
        levelTimer?.invalidate(); levelTimer = nil
        level = 0
    }

    #if DEBUG
    /// Shows an indicator state on the visible composer (screenshots only).
    func debugShow(_ phase: Phase, level: Float, locked: Bool) {
        target = Self.currentComposer()?.dictationID
        self.phase = phase
        self.level = level
        self.locked = locked
    }
    #endif

    /// What the context vocabulary reads, taken on the main actor: the
    /// conversation's recent text (newest first) and the changed files.
    static func contextInput(workspace: Workspace?, conversation id: UUID?) -> ContextVocabulary.Input {
        var input = ContextVocabulary.Input(folder: workspace?.folder)
        if let conversation = workspace?.conversations.first(where: { $0.id == id }) {
            var texts = [conversation.draft]
            for item in conversation.items.suffix(60).reversed() {
                texts.append(item.text)
                texts += item.input.values.compactMap { $0 as? String }
            }
            input.conversation = texts
        }
        input.changed = workspace?.changes.files.map(\.path) ?? []
        return input
    }

    // MARK: Target

    /// The focused composer, else the visible one in the key window.
    static func currentComposer() -> ComposerTextView? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            if let view = window.firstResponder as? ComposerTextView { return view }
            if let view = find(in: window.contentView) { return view }
        }
        // Toasty in the background (debug commands): any visible window.
        for window in NSApp.orderedWindows where window.isVisible {
            if let view = find(in: window.contentView) { return view }
        }
        return nil
    }

    private static func find(in view: NSView?) -> ComposerTextView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let composer = view as? ComposerTextView, !composer.visibleRect.isEmpty { return composer }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }
}
