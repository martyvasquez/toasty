import AppKit
import SwiftUI

/// Toasty ▸ Settings… (⌘,): a standard Mac settings window with a
/// preference-style toolbar. One pane today (Dictation); the toolbar is
/// ready for more.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private static let dictation = NSToolbarItem.Identifier("dictation")

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: DictationSettingsView()))
        window.title = "Dictation"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ToastySettings")
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "ToastySettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.dictation
        window.toolbar = toolbar
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func show(_ sender: Any?) {
        if window?.isVisible != true { window?.center() }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Dictation"
        item.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Dictation")
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: Any?) {}

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.dictation] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.dictation] }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.dictation] }
}
