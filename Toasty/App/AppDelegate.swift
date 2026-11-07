import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: MainWindowController?
    let store = WorkspaceStore.shared
    /// Folders opened before the window existed (launch via `open -a`).
    private var pendingFolders: [String] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugControl.install()
        TerminalDebug.install()
        WorkspaceDebug.install()
        ClaudeDebug.install()
        #endif
        store.load()
        Activity.shared.start()
        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        store.startShownConversation()
        pendingFolders.forEach(store.openFolder)
        pendingFolders = []
        NSApp.activate()
    }

    /// Folders from Finder, the Dock or `open -a Toasty <dir>`: their
    /// workspace, or a new one.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let folder = isDir.boolValue ? url.path : url.deletingLastPathComponent().path
            if windowController == nil {
                pendingFolders.append(folder)
            } else {
                store.openFolder(folder)
                windowController?.showWindow(nil)
            }
        }
        NSApp.activate()
    }

    /// Quitting stops Claude and terminal programs: ask first if any are busy.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
