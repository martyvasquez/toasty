import AppKit

/// Hold Right Option to dictate; double-tap it to lock hands-free, press it
/// again to finish (plan §9.1–9.2, Hex suppression/hotkey.rs with
/// double-tap on, hold mode). Pure: event times in, actions out, so every
/// boundary is unit-tested with synthetic times.
///
/// Toasty's own rule (the user's choice): Escape (or ⌘.) cancels a held or
/// locked dictation, and that key is swallowed (Hex ignores Escape, #786).
nonisolated struct TriggerStateMachine: Equatable {
    enum Event: Equatable {
        /// Right Option went down alone (no other modifier held).
        case triggerDown(TimeInterval)
        case triggerUp(TimeInterval)
        /// Any other key went down (not a repeat).
        case keyDown(TimeInterval)
        case escape(TimeInterval)
        case mouseDown(TimeInterval)
        /// Another modifier went down while the trigger is held.
        case extraModifier(TimeInterval)
        /// The composer's mic button.
        case button(TimeInterval)
        /// Toasty stopped being the active app (a held key's release won't arrive).
        case resignActive(TimeInterval)
    }

    enum Action: Equatable {
        case start(TimeInterval)
        case finish(TimeInterval)
        /// A chord (Right Option used as a modifier): drop the capture silently.
        case discard
        /// Escape: drop the capture.
        case cancel
    }

    enum State: Equatable {
        case idle(lastRelease: TimeInterval?)
        case holding(started: TimeInterval, previousRelease: TimeInterval?)
        case locked
        /// Ended (chord, cancel, lock finish) with the trigger still down:
        /// ignore everything until it goes up.
        case dirty
    }

    private(set) var state: State = .idle(lastRelease: nil)

    var isRecording: Bool {
        switch state {
        case .holding, .locked: true
        case .idle, .dirty: false
        }
    }

    var isLocked: Bool { state == .locked }

    mutating func handle(_ event: Event) -> Action? {
        let window = DictationConfig.doubleTapWindow, hold = DictationConfig.minimumHold
        switch (state, event) {
        case (.idle(let lastRelease), .triggerDown(let now)):
            let previous = lastRelease.flatMap { Self.under(now - $0, window) ? $0 : nil }
            state = .holding(started: now, previousRelease: previous)
            return .start(now)

        case (.idle, .button(let now)):
            state = .locked
            return .start(now)

        case (.holding(_, let previous?), .triggerUp(let now)) where Self.under(now - previous, window):
            // Second short tap: keep recording hands-free.
            state = .locked
            return nil

        case (.holding, .triggerUp(let now)):
            // The capture decides on the minimum hold (event times).
            state = .idle(lastRelease: now)
            return .finish(now)

        case (.holding, .keyDown):
            // A modifier-only trigger plus any key is a chord at any time.
            state = .dirty
            return .discard

        case (.holding(let started, _), .mouseDown(let now)), (.holding(let started, _), .extraModifier(let now)):
            guard Self.under(now - started, hold) else { return nil }
            state = .dirty
            return .discard

        case (.holding, .escape), (.locked, .escape):
            state = triggerHeldAfterCancel ? .dirty : .idle(lastRelease: nil)
            return .cancel

        case (.holding, .button(let now)), (.holding, .resignActive(let now)):
            state = .idle(lastRelease: nil)
            return .finish(now)

        case (.locked, .triggerDown(let now)):
            state = .dirty
            return .finish(now)

        case (.locked, .button(let now)):
            state = .idle(lastRelease: nil)
            return .finish(now)

        case (.dirty, .triggerUp):
            state = .idle(lastRelease: nil)
            return nil

        default:
            return nil
        }
    }

    /// `elapsed < limit` to the microsecond: 300 ms must not read as 299.99… ms.
    static func under(_ elapsed: TimeInterval, _ limit: TimeInterval) -> Bool { elapsed + 1e-6 < limit }

    /// While holding, Escape arrives with the trigger down; while locked it's up.
    private var triggerHeldAfterCancel: Bool {
        if case .holding = state { return true }
        return false
    }
}

/// Watches Toasty's own key and mouse events (a local monitor: no
/// Accessibility permission, nothing outside Toasty) and feeds the state
/// machine. Right Option events pass through; only a cancelling Escape is
/// swallowed.
@MainActor
final class TriggerMonitor {
    /// Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK).
    private static let rightOptionMask: UInt = 0x40
    private static let leftOptionMask: UInt = 0x20
    private static let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .shift, .function]

    private var monitor: Any?
    private let handle: (TriggerStateMachine.Event, NSEvent) -> Bool

    /// `handle` returns true to swallow the event.
    init(handle: @escaping (TriggerStateMachine.Event, NSEvent) -> Bool) {
        self.handle = handle
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let mapped = Self.map(event) else { return event }
            return handle(mapped, event) ? nil : event
        }
    }

    static func map(_ event: NSEvent) -> TriggerStateMachine.Event? {
        let at = event.timestamp
        switch event.type {
        case .flagsChanged:
            let raw = event.modifierFlags.rawValue
            if event.keyCode == DictationConfig.triggerKeyCode {
                guard raw & rightOptionMask != 0 else { return .triggerUp(at) }
                // Pressed together with another modifier: not a dictation press.
                let others = !event.modifierFlags.intersection(otherModifiers).isEmpty || raw & leftOptionMask != 0
                return others ? nil : .triggerDown(at)
            }
            // Another modifier went down (Left Option too).
            let down = !event.modifierFlags.intersection(otherModifiers).isEmpty || raw & leftOptionMask != 0
            return down ? .extraModifier(at) : nil
        case .keyDown:
            if event.isARepeat { return nil }
            // Esc, or ⌘. (the Mac's other Cancel), cancels a dictation.
            let commandPeriod = event.charactersIgnoringModifiers == "."
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            return event.keyCode == 53 || commandPeriod ? .escape(at) : .keyDown(at)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .mouseDown(at)
        default:
            return nil
        }
    }
}
