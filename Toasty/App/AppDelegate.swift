import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: MainWindowController?
    let store = WorkspaceStore.shared
    /// Folders opened before the window existed (launch via `open -a`).
    private var pendingFolders: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    /// Unit tests run hosted in the Debug app: start nothing (no window,
    /// workspaces, Claude or terminals), so tests never touch real state.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isRunningTests { return }
        // Finder's Services menu: "New Toasty Tab Here".
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        #if DEBUG
        DebugControl.install()
        TerminalDebug.install()
        WorkspaceDebug.install()
        ClaudeDebug.install()
        DictationDebug.install()
        PreviewDebug.install()
        ScreenshotDebug.install()
        ProcessDebug.install()
        #endif
        store.load()
        // Anything a crashed or force-quit run left running stops now.
        ProcessReaper.sweepLeftovers()
        Activity.shared.start()
        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        store.startShownConversation()
        pendingFolders.forEach(store.openFolder)
        pendingFolders = []
        // Dictation's speech model loads and prewarms in the background once
        // the window is up, so the first dictation is ready.
        SpeechEngine.shared.preload()
        DictationController.shared.start()
        Vocabulary.preload()
        // ⇧⌘0 in any app: a screenshot into the open conversation.
        ScreenshotCapture.shared.start()
        // Claude conversations need Claude Code and Node: say so if either
        // is missing (quiet when both are there).
        ClaudeSetup.checkAtLaunch()
        // First launch: offer to bring over mostty's workspaces.
        if store.isFirstLaunch, MosttyImport.isAvailable,
           !UserDefaults.standard.bool(forKey: "ToastyImportedFromMostty") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [store] in MosttyImport.present(store: store) }
        }
        NSApp.activate()
    }

    /// Folders from Finder, the Dock or `open -a Toasty <dir>`: their
    /// workspace, or a new one.
    func application(_ application: NSApplication, open urls: [URL]) {
        openFolders(urls)
    }

    /// Each URL's folder (a file's enclosing folder): a new tab in its
    /// workspace, or a new workspace. Shared by Finder's "Open With", the
    /// Dock, `open -a` and the "New Toasty Tab Here" service.
    func openFolders(_ urls: [URL]) {
        var seen = Set<String>()
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let folder = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
            guard seen.insert(WorkspaceStore.normalize(folder)).inserted else { continue }
            if windowController == nil {
                pendingFolders.append(folder)
            } else {
                store.openFolder(folder)
                windowController?.showWindow(nil)
            }
        }
        NSApp.activate()
    }

    /// Dictation's microphone stays warm while Toasty is active (instant
    /// start with pre-roll) and closes 30 s after it isn't (plan D9).
    func applicationDidBecomeActive(_ notification: Notification) {
        if !Self.isRunningTests { MicCapture.shared.appBecameActive() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if !Self.isRunningTests { MicCapture.shared.appResignedActive() }
    }

    /// Quitting stops Claude and terminal programs: ask first if any are busy.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An open import sheet would block quitting.
        MosttyImport.finishSheet(perform: false, store: store)
        let conversations = store.workspaces.flatMap(\.conversations)
        let terminals = store.workspaces.flatMap(\.terminals)
        guard let warning = Activity.shared.closeWarning(conversations: conversations, terminals: terminals, action: "quit"),
              !skipQuitConfirmation else { return .terminateNow }
        Activity.shared.confirm(warning, title: "Quit Toasty?", button: "Quit",
                                cancel: { NSApp.reply(toApplicationShouldTerminate: false) },
                                proceed: { NSApp.reply(toApplicationShouldTerminate: true) })
        return .terminateLater
    }

    /// Set by the debug `quit` command so tests can quit without a prompt.
    var skipQuitConfirmation = false

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
        // What Claude started in any conversation stops with Toasty.
        if !Self.isRunningTests {
            ProcessReaper.reapAtQuit(agents: store.workspaces.flatMap(\.conversations).compactMap(\.agentPID))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }
}

extension AppDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }
}
