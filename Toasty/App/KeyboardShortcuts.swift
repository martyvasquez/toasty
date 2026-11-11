import AppKit
import SwiftUI

/// Help ▸ Keyboard Shortcuts (⌘/): every shortcut on one sheet.
///
/// Commands are listed by their menu action and their keys are read from
/// the menu, so a shortcut changed in `MainMenu` is right here too. What a
/// menu can't hold (Esc, holding Right Option, keys inside the composer)
/// is written out.
final class KeyboardShortcuts: NSObject {
    static let shared = KeyboardShortcuts()
    private var sheet: NSWindow?

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        if sheet != nil { dismiss(); return }
        guard let window = AppDelegate.shared.windowController?.window else { return }
        let host = NSHostingController(rootView: KeyboardShortcutsView(groups: Self.groups()) { [weak self] in self?.dismiss() })
        host.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: host)
        self.sheet = sheet
        window.beginSheet(sheet)
    }

    func dismiss() {
        if let sheet { sheet.sheetParent?.endSheet(sheet) }
        sheet = nil
    }

    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let keys: String
    }

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let rows: [Row]
    }

    // MARK: What's listed

    static func groups() -> [Group] {
        typealias W = MainWindowController
        /// A command, with the keys its menu item has now.
        func menu(_ title: String, _ action: Selector, tag: Int? = nil) -> Row? {
            keys(for: action, tag: tag).map { Row(title: title, keys: $0) }
        }
        func plain(_ title: String, _ keys: String) -> Row? { Row(title: title, keys: keys) }

        var groups = [
            Group(title: "Conversations", rows: [
                menu("New tab", #selector(W.newTab(_:))),
                menu("Close tab", #selector(W.closeTab(_:))),
                menu("Next tab", #selector(W.selectNextTab(_:))),
                menu("Previous tab", #selector(W.selectPreviousTab(_:))),
                plain("Send", "↩"),
                plain("New line", "⇧↩"),
                plain("Interrupt Claude, or deny a request", "esc"),
                plain("Commands", "/"),
                plain("Message another tab", "@"),
                menu("Attach a screenshot", #selector(ScreenshotCapture.capture(_:))),
                plain("Dictate", "hold right ⌥"),
            ].compactMap { $0 }),
            Group(title: "Workspaces", rows: [
                menu("New workspace", #selector(W.newWorkspace(_:))),
                menu("New worktree", #selector(W.newWorktree(_:))),
                menu("Rename workspace", #selector(W.renameWorkspace(_:))),
                menu("Next workspace", #selector(W.selectNextWorkspace(_:))),
                menu("Previous workspace", #selector(W.selectPreviousWorkspace(_:))),
                menu("Jump to the conversation needing you", #selector(W.jumpToAttention(_:))),
                plain("Open a notification", "⌘1 – ⌘9"),
            ].compactMap { $0 }),
            Group(title: "Window", rows: [
                menu("Workspaces", #selector(W.toggleWorkspaces(_:))),
                menu("Inspector and terminal", #selector(W.toggleRightColumn(_:))),
                menu("Inspector", #selector(W.toggleInspector(_:))),
            ].compactMap { $0 }
            + InspectorTab.allCases.enumerated().compactMap { i, tab in
                menu("Inspector: \(tab.title.lowercased())", #selector(W.showInspectorTab(_:)), tag: i)
            }
            + [
                menu("Terminal", #selector(W.toggleTerminal(_:))),
                menu("New terminal", #selector(W.newTerminal(_:))),
                menu("Clear terminal", #selector(TerminalView.clearTerminal(_:))),
                // macOS shows its own Globe-key shortcut on this menu item.
                plain("Full screen", "⌃⌘F"),
                menu("Settings", #selector(SettingsWindowController.show(_:))),
                menu("Keyboard shortcuts", #selector(KeyboardShortcuts.showKeyboardShortcuts(_:))),
            ].compactMap { $0 }),
        ]
        // The preview's, only while it's turned on.
        if PreviewSettings.shared.enabled {
            groups.append(Group(title: "Preview", rows: [
                menu("Show or hide the preview", #selector(W.togglePreview(_:))),
                menu("Phone or desktop size", #selector(W.togglePreviewSize(_:))),
                menu("Desktop page beside the conversation, or across the window", #selector(W.togglePreviewLayout(_:))),
                menu("Comment on the page", #selector(W.togglePreviewComment(_:))),
                plain("Send a comment to Claude", "↩"),
                plain("Add a comment to the message instead", "⇧↩"),
                plain("Done commenting", "esc"),
            ].compactMap { $0 }))
        }
        return groups
    }

    // MARK: Keys from the menu

    /// The keys of the menu item with this action (not a hidden alternate).
    static func keys(for action: Selector, tag: Int?) -> String? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                // Not the alternates kept hidden, nor the Globe-key ones
                // macOS adds beside its own commands (full screen).
                if item.action == action, !item.keyEquivalent.isEmpty, !item.allowsKeyEquivalentWhenHidden,
                   !item.keyEquivalentModifierMask.contains(.function),
                   tag == nil || item.tag == tag { return item }
                if let found = item.submenu.flatMap(find) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find).map(keys(of:))
    }

    /// "⇧⌘S", "⌥⌘→", "⌃⌘1": modifiers in the order menus draw them.
    static func keys(of item: NSMenuItem) -> String {
        var mods = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        // An uppercase key equivalent means Shift.
        if key.count == 1, key != key.lowercased() { mods.insert(.shift) }
        switch key.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey: key = "↑"
        case NSDownArrowFunctionKey: key = "↓"
        case NSLeftArrowFunctionKey: key = "←"
        case NSRightArrowFunctionKey: key = "→"
        default: key = key.uppercased()
        }
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + key
    }
}

struct KeyboardShortcutsView: View {
    let groups: [KeyboardShortcuts.Group]
    let dismiss: () -> Void

    /// Two columns of about the same height.
    private var columns: [[KeyboardShortcuts.Group]] {
        let total = groups.reduce(0) { $0 + $1.rows.count + 2 }
        var left: [KeyboardShortcuts.Group] = [], right: [KeyboardShortcuts.Group] = []
        var count = 0
        for group in groups {
            if count * 2 < total { left.append(group) } else { right.append(group) }
            count += group.rows.count + 2
        }
        return [left, right]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 16)
            HStack(alignment: .top, spacing: 36) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(column) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 6)
                                ForEach(group.rows) { row in
                                    HStack(spacing: 12) {
                                        Text(row.title)
                                            .font(.system(size: 12.5))
                                            .lineLimit(1)
                                        Spacer(minLength: 12)
                                        KeyCap(keys: row.keys)
                                    }
                                    .frame(height: 26)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                    .frame(width: 320, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(24)
        .onExitCommand(perform: dismiss)
    }
}

private struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
