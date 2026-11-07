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
        #endif
        store.load()
        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
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
