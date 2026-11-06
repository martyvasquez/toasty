import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var windowController: MainWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugControl.install()
        #endif
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
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
