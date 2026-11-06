import AppKit

/// The one Toasty window. Phase 0: an empty window with the standard
/// compact-toolbar titlebar; the split view arrives in Phase 2.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Toasty"
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 480)
        // An empty compact toolbar gives the titlebar the standard height of
        // a Mac app with tabs in its toolbar (Safari, Xcode).
        window.toolbar = NSToolbar(identifier: "Toasty")
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .textBackgroundColor
        window.center()
        window.setFrameAutosaveName("ToastyMain")
        self.init(window: window)
        window.delegate = self
    }
}
