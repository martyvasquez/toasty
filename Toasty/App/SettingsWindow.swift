import AppKit
import SwiftUI

/// Toasty ▸ Settings… (⌘,): a standard Mac settings window with a
/// preference-style toolbar: Dictation, Screenshots (⇧⌘0 from any app), and
/// Preview (the experimental preview browser's on/off switch).
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private enum Pane: String, CaseIterable {
        case dictation, screenshots, preview

        var id: NSToolbarItem.Identifier { .init(rawValue) }

        var title: String {
            switch self {
            case .dictation: "Dictation"
            case .screenshots: "Screenshots"
            case .preview: "Preview"
            }
        }

        var symbol: String {
            switch self {
            case .dictation: "mic"
            case .screenshots: "camera.viewfinder"
            case .preview: "safari"
            }
        }

        @MainActor func makeController() -> NSViewController {
            switch self {
            case .dictation: NSHostingController(rootView: DictationSettingsView())
            case .screenshots: NSHostingController(rootView: ScreenshotSettingsView())
            case .preview: NSHostingController(rootView: PreviewSettingsView())
            }
        }
    }

    private var pane = Pane.dictation

    private init() {
        let window = NSWindow(contentViewController: Pane.dictation.makeController())
        window.title = Pane.dictation.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ToastySettings")
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "ToastySettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Pane.dictation.id
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func show(_ sender: Any?) {
        if window?.isVisible != true { window?.center() }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }

    /// Show a pane, keeping the window's top edge where it is.
    private func select(_ new: Pane) {
        guard new != pane, let window else { return }
        pane = new
        let top = window.frame.maxY
        window.contentViewController = new.makeController()
        window.title = new.title
        window.toolbar?.selectedItemIdentifier = new.id
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        if let pane = Pane(rawValue: sender.itemIdentifier.rawValue) { select(pane) }
    }

    #if DEBUG
    /// Debug: show a pane by name ("dictation", "screenshots", "preview").
    func debugSelect(_ name: String) {
        if let pane = Pane(rawValue: name) { select(pane) }
    }
    #endif

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
}
