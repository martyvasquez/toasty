import AppKit
import SwiftUI

/// Settings ▸ General ▸ Appearance: Light, Dark or Automatic (the
/// system's). Dark until the user picks.
@MainActor
final class AppearanceSetting: ObservableObject {
    static let shared = AppearanceSetting()

    enum Mode: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    private static let key = "ToastyAppearance"

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.key).flatMap(Mode.init) ?? .dark
    }

    /// Set the whole app's appearance (at launch, before any window, and
    /// on every change).
    func apply() {
        switch mode {
        case .automatic: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Settings ▸ General: the terminal's cursor blinks while it has focus
/// (as Terminal and Ghostty do). On until turned off; off, it blinks only
/// when the program in the terminal asks.
@MainActor
final class TerminalCursorSetting: ObservableObject {
    static let shared = TerminalCursorSetting()
    static let changed = Notification.Name("ToastyTerminalCursorChanged")
    private static let key = "ToastyTerminalCursorBlink"

    @Published var blink: Bool {
        didSet {
            UserDefaults.standard.set(blink, forKey: Self.key)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private init() {
        blink = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}

/// Settings ▸ General ▸ Sound: the sound when a conversation finishes or
/// needs you. On, with Toasty's own bell, until the user picks.
@MainActor
final class AlertSound: ObservableObject {
    static let shared = AlertSound()

    /// Toasty's own sound, synthesized (see `Ding`), listed first as the default.
    static let toasty = "Toasty"

    private static let enabledKey = "ToastySoundEnabled"
    private static let nameKey = "ToastySound"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// `toasty`, or a sound in /System/Library/Sounds or ~/Library/Sounds.
    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        var stored = defaults.string(forKey: Self.nameKey) ?? Self.toasty
        // Before this setting, "none" was how to turn the sound off.
        if stored.lowercased() == "none" {
            stored = Self.toasty
            defaults.set(stored, forKey: Self.nameKey)
            if defaults.object(forKey: Self.enabledKey) == nil { defaults.set(false, forKey: Self.enabledKey) }
        }
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        name = stored
        // A sound that's gone (a deleted ~/Library/Sounds file) is shown
        // and played as the default.
        if !choices.contains(name) { name = Self.toasty }
    }

    /// Toasty's first, then the macOS alert sounds (and the user's own),
    /// by name.
    let choices: [String] = {
        let fm = FileManager.default
        let dirs = ["/System/Library/Sounds", (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")]
        var names = Set<String>()
        for dir in dirs {
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !file.hasPrefix(".") {
                names.insert((file as NSString).deletingPathExtension)
            }
        }
        names.remove(AlertSound.toasty)
        return [AlertSound.toasty] + names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    private var playing: NSSound?

    /// The sound for a finished or waiting conversation, if it's on.
    func playIfEnabled() {
        if enabled { play() }
    }

    /// The chosen sound, regardless of the switch (a preview).
    func play() {
        playing?.stop()
        let sound = name == Self.toasty ? Ding.sound : (NSSound(named: NSSound.Name(name)) ?? Ding.sound)
        sound?.stop()
        sound?.play()
        playing = sound
    }
}

/// Toasty's bell: struck partials decaying at their own rates,
/// synthesized so nothing is bundled.
@MainActor
enum Ding {
    static let sound: NSSound? = NSSound(data: DictationTones.wav(samples(rate: 44_100), rate: 44_100))

    nonisolated static func samples(rate: Double) -> [Float] {
        let fundamental = 1046.5   // C6
        // (ratio to the fundamental, level, decay per second): a bell's
        // inharmonic partials, the high ones dying first.
        let partials: [(Double, Double, Double)] = [
            (1.0, 1.0, 3.2), (2.0, 0.32, 5.5), (2.76, 0.16, 8), (5.4, 0.06, 14),
        ]
        let level = 0.2
        let seconds = 1.3
        let length = Int(seconds * rate)
        let total = partials.reduce(0) { $0 + $1.1 }
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) / rate
            let attack = min(1, t / 0.003)
            let release = min(1, Double(length - i) / (0.08 * rate))
            var v = 0.0
            for (ratio, amp, decay) in partials {
                v += amp * exp(-t * decay) * sin(2 * .pi * fundamental * ratio * t)
            }
            out[i] = Float(level * attack * release * v / total)
        }
        return out
    }
}

/// Settings ▸ General ▸ Appearance and Sound.
struct AppearanceAndSoundSection: View {
    @ObservedObject private var appearance = AppearanceSetting.shared
    @ObservedObject private var sound = AlertSound.shared

    /// The section's height in the General pane.
    static let height: CGFloat = 172

    var body: some View {
        Section {
            Picker("Appearance", selection: $appearance.mode) {
                ForEach(AppearanceSetting.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Play a sound when a conversation finishes or needs you", isOn: $sound.enabled)
            Picker("Sound", selection: Binding(get: { sound.name }, set: { sound.name = $0; sound.play() })) {
                ForEach(sound.choices, id: \.self) { name in
                    Text(name == AlertSound.toasty ? "Toasty (Default)" : name).tag(name)
                    if name == AlertSound.toasty { Divider() }
                }
            }
            .disabled(!sound.enabled)
        } footer: {
            Text("Automatic follows macOS. Choosing a sound plays it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Whether a click and drag sideways over the widgets switches spaces
/// (on by default; the two-finger swipe always does).
@MainActor final class WidgetDragSetting: ObservableObject {
    static let shared = WidgetDragSetting()
    private static let key = "ToastyWidgetDragSwitchesSpaces"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}

struct WidgetSettingsSection: View {
    @ObservedObject private var drag = WidgetDragSetting.shared

    /// The section's height in the General pane.
    static let height: CGFloat = 116

    var body: some View {
        Section {
            Toggle("Drag sideways to switch spaces", isOn: $drag.enabled)
        } header: {
            Text("Widgets")
        } footer: {
            Text("Click and drag over the widgets to move between spaces, as a swipe does. Not while editing them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
