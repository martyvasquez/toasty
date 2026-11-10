import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

/// ⇧⌘0, in any app: drag an area (or Space for a window) exactly as with
/// ⇧⌘4, and the screenshot is attached to the conversation open in Toasty.
/// Toasty stays in the background, so several can be taken in a row.
///
/// The picture is taken by the system's `screencapture`, which writes a file;
/// Toasty reads it into the composer and deletes it at once, so nothing is
/// left on the Desktop, in Downloads or in the temporary folder.
final class ScreenshotCapture: NSObject {
    static let shared = ScreenshotCapture()

    private var hotKey: EventHotKeyRef?
    private var handlerInstalled = false
    /// The picker that's on screen now, if any.
    private var running: Process?

    /// Every step is logged, so a press that did nothing can be explained:
    /// `/usr/bin/log show --last 10m --predicate 'category == "screenshot"'`
    nonisolated static let log = Logger(subsystem: "com.martyvasquez.toasty", category: "screenshot")

    /// Toasty Debug has a shortcut of its own (⌃⇧⌘0). Two apps can both
    /// register the same system-wide shortcut without an error and only one
    /// is told about the press, so with the same one the screenshot went to
    /// whichever copy of Toasty the system chose.
    #if DEBUG
    static let shortcutLabel = "⌃⇧⌘0"
    static let menuModifiers: NSEvent.ModifierFlags = [.control, .shift, .command]
    private static let carbonModifiers = UInt32(controlKey | shiftKey | cmdKey)
    #else
    static let shortcutLabel = "⇧⌘0"
    static let menuModifiers: NSEvent.ModifierFlags = [.shift, .command]
    private static let carbonModifiers = UInt32(shiftKey | cmdKey)
    #endif

    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToastyScreenshots", isDirectory: true)
    private static let askedKey = "ScreenshotAskedPermission"

    var isHotKeyRegistered: Bool { hotKey != nil }

    func start() {
        // A file left by a crash mid-capture.
        try? FileManager.default.removeItem(at: Self.folder)
        updateHotKey()
    }

    // MARK: The shortcut

    /// Register ⇧⌘0 with the system while "from any app" is on. Off, the
    /// menu item's shortcut still works inside Toasty.
    func updateHotKey() {
        if ScreenshotSettings.shared.global {
            guard hotKey == nil else { return }
            installHandler()
            let id = EventHotKeyID(signature: 0x54535459 /* TSTY */, id: 1)
            let status = RegisterEventHotKey(UInt32(kVK_ANSI_0), Self.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &hotKey)
            if status != noErr { hotKey = nil }
            Self.log.notice("register \(Self.shortcutLabel, privacy: .public): status \(status)")
        } else if let key = hotKey {
            UnregisterEventHotKey(key)
            hotKey = nil
            Self.log.notice("unregistered")
        }
    }

    /// Registering failed at launch (it's tried again whenever Toasty comes
    /// forward, and before Settings says so).
    func retryHotKeyIfNeeded() {
        if hotKey == nil { updateHotKey() }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), screenshotHotKeyPressed, 1, &spec, nil, nil)
        if status != noErr { Self.log.error("install handler: status \(status)") }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenshotCapture.shared.retryHotKeyIfNeeded() }
        }
    }

    // MARK: Capture

    @objc func capture(_ sender: Any?) {
        // The picker is already up. (Asked of the process itself, not a flag
        // that one missed callback would leave set until Toasty is reopened.)
        if let running, running.isRunning {
            Self.log.notice("pressed: picker already on screen")
            return
        }
        running = nil
        guard target != nil else {
            Self.log.notice("pressed: no conversation open")
            NSSound.beep()
            return
        }
        guard hasPermission() else {
            Self.log.notice("pressed: no Screen Recording permission")
            return
        }
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-t", "png", file.path]
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(file, status: status) } }
        }
        do {
            try process.run()
            running = process
            Self.log.notice("pressed: picker started")
        } catch {
            Self.log.error("screencapture didn't start: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// The conversation on screen in Toasty.
    private var target: ClaudeConversation? { AppDelegate.shared.store.active?.selected }

    private func finished(_ file: URL, status: Int32) {
        running = nil
        // No file: Esc cancelled the capture.
        guard let data = try? Data(contentsOf: file) else {
            Self.log.notice("picker ended with no picture (status \(status))")
            return
        }
        try? FileManager.default.removeItem(at: file)
        let attached = attach(data)
        Self.log.notice("picture of \(data.count) bytes, attached: \(attached)")
    }

    /// Add a picture to the open conversation's composer. False when there's
    /// no conversation or the data isn't a picture.
    @discardableResult
    func attach(_ data: Data) -> Bool {
        guard let conversation = target, let image = NSImage(data: data) else {
            NSSound.beep()
            return false
        }
        conversation.attachments.append(image)
        // Typing is ready when the user comes back; this doesn't bring Toasty forward.
        conversation.focusComposer()
        return true
    }

    // MARK: Screen Recording permission

    /// macOS asks by itself the first time. After that only System Settings
    /// can grant it, so say where.
    private func hasPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let asked = UserDefaults.standard.bool(forKey: Self.askedKey)
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        if CGRequestScreenCaptureAccess() { return true }
        guard asked else { return false }
        let alert = NSAlert()
        alert.messageText = "Toasty needs permission to take screenshots"
        alert.informativeText = "Turn on Toasty in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then quit and reopen Toasty."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        // The shortcut was pressed in another app, which macOS may not let
        // Toasty come in front of: the alert goes above everything by itself.
        alert.window.level = .floating
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}

/// Carbon calls this on the main thread when ⇧⌘0 is pressed in any app.
private nonisolated func screenshotHotKeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                                 _ context: UnsafeMutableRawPointer?) -> OSStatus {
    ScreenshotCapture.log.notice("hot key pressed")
    DispatchQueue.main.async { MainActor.assumeIsolated { ScreenshotCapture.shared.capture(nil) } }
    return noErr
}

/// Settings ▸ Screenshots.
final class ScreenshotSettings: ObservableObject {
    static let shared = ScreenshotSettings()
    private static let key = "ScreenshotFromAnyApp"

    /// ⇧⌘0 works in every app, not only in Toasty (on unless turned off).
    @Published var global: Bool {
        didSet {
            guard global != oldValue else { return }
            UserDefaults.standard.set(global, forKey: Self.key)
            ScreenshotCapture.shared.updateHotKey()
        }
    }

    private init() {
        global = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}

struct ScreenshotSettingsView: View {
    @ObservedObject private var settings = ScreenshotSettings.shared
    @State private var registered = true

    var body: some View {
        Form {
            Section {
                Toggle("Take screenshots from any app", isOn: $settings.global)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.global, !registered {
                        Text("\(ScreenshotCapture.shortcutLabel) couldn't be set up as a shortcut for every app. It still works in Toasty.")
                            .foregroundStyle(.orange)
                    }
                    Text("Press \(ScreenshotCapture.shortcutLabel) in any app, then drag over an area, or press Space to pick a window. The screenshot is attached to the conversation you have open in Toasty and isn't saved anywhere else.")
                    Text("Toasty stays in the background, so you can take several before coming back. While this is off, \(ScreenshotCapture.shortcutLabel) works only in Toasty.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: registered || !settings.global ? 172 : 200)
        .onAppear {
            ScreenshotCapture.shared.retryHotKeyIfNeeded()
            registered = ScreenshotCapture.shared.isHotKeyRegistered
        }
        .onChange(of: settings.global) { registered = ScreenshotCapture.shared.isHotKeyRegistered }
    }
}
