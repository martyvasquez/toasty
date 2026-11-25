import AppKit
import SwiftUI

/// Toasty ▸ Settings… (⌘,): a standard Mac settings window with a
/// preference-style toolbar: General (the default model, appearance,
/// the sound, updates), Dictation,
/// Screenshots (⇧⌘0 from any app), Tee-Up (Auto-Send), and Browser (the experimental
/// browser's on/off switch).
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case general, terminal, dictation, screenshots, teeUp, preview

        var id: NSToolbarItem.Identifier { .init(rawValue) }

        var title: String {
            switch self {
            case .general: "General"
            case .terminal: "Terminal"
            case .dictation: "Dictation"
            case .screenshots: "Screenshots"
            case .teeUp: "Tee-Up"
            case .preview: "Browser"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .terminal: "terminal"
            case .dictation: "mic"
            case .screenshots: "camera.viewfinder"
            case .teeUp: WidgetKind.teeUp.symbol
            case .preview: "globe"  // unused: drawn (BrowserGlyph)
            }
        }

        @MainActor func makeController() -> NSViewController {
            switch self {
            case .general: NSHostingController(rootView: GeneralSettingsView())
            case .terminal: NSHostingController(rootView: TerminalSettingsView())
            case .dictation: NSHostingController(rootView: DictationSettingsView())
            case .screenshots: NSHostingController(rootView: ScreenshotSettingsView())
            case .teeUp: NSHostingController(rootView: TeeUpSettingsView())
            case .preview: NSHostingController(rootView: PreviewSettingsView())
            }
        }
    }

    private var pane = Pane.general

    private init() {
        let window = NSWindow(contentViewController: Pane.general.makeController())
        window.title = Pane.general.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ToastySettings")
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "ToastySettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Pane.general.id
        window.toolbar = toolbar
        pinTopLeft(window)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func show(_ sender: Any?) {
        if window?.isVisible != true {
            window?.center()
            anchor = window.map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY) }
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }

    /// Where the window's top-left corner stays while panes change size
    /// (updated when the window is moved).
    private var anchor: NSPoint?
    private var observers: [NSObjectProtocol] = []

    /// Keep the top-left corner put whenever the window resizes: a pane's
    /// SwiftUI content settles its size after it's shown, and AppKit
    /// resizes from the bottom-left, so the window would jump.
    private func pinTopLeft(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchor = NSPoint(x: window.frame.minX, y: window.frame.maxY) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let anchor = self?.anchor, window.frame.width > 0 else { return }
                if window.frame.minX != anchor.x || window.frame.maxY != anchor.y { window.setFrameTopLeftPoint(anchor) }
            }
        })
    }

    /// Show a pane, keeping the window's top-left corner where it is: the
    /// new pane is measured first and the window takes its size in one step.
    private func select(_ new: Pane) {
        guard new != pane, let window else { return }
        pane = new
        let anchor = self.anchor ?? NSPoint(x: window.frame.minX, y: window.frame.maxY)
        self.anchor = anchor
        let controller = new.makeController()
        let size = controller.view.fittingSize
        if size.width > 0, size.height > 0 { controller.view.setFrameSize(size) }
        window.contentViewController = controller
        window.title = new.title
        window.toolbar?.selectedItemIdentifier = new.id
        window.setFrameTopLeftPoint(anchor)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = pane == .preview ? BrowserGlyph.image(size: 17, diameter: 10.6, line: 0.72)
            : NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        if let pane = Pane(rawValue: sender.itemIdentifier.rawValue) { select(pane) }
    }

    /// Show the window on a pane, by name ("general", "dictation", …).
    func show(pane name: String) {
        if let pane = Pane(rawValue: name) { select(pane) }
        show(nil)
    }

    #if DEBUG
    /// Debug: show a pane by name ("general", "dictation", "screenshots", "teeUp", "preview").
    func debugSelect(_ name: String) {
        if let pane = Pane(rawValue: name) { select(pane) }
    }
    #endif

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
}
