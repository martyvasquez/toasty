import AppKit

/// The main menu, built in code. Later phases add their items here.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Toasty"

        let app = NSMenu(title: name)
        let about = NSMenuItem(title: "About \(name)", action: #selector(AboutPanel.show(_:)), keyEquivalent: "")
        about.target = AboutPanel.shared
        app.addItem(about)
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(SettingsWindowController.show(_:)), keyEquivalent: ",")
        settings.target = SettingsWindowController.shared
        app.addItem(settings)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        typealias W = MainWindowController
        let file = NSMenu(title: "File")
        file.addItem(item("New Tab", #selector(W.newTab(_:)), "t"))
        file.addItem(item("New Terminal", #selector(W.newTerminal(_:)), "t", [.command, .option]))
        file.addItem(item("New Workspace…", #selector(W.newWorkspace(_:)), "n"))
        file.addItem(item("Import from mostty…", #selector(W.importFromMostty(_:)), ""))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(W.closeTab(_:)), "w"))
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Clear Terminal", action: #selector(TerminalView.clearTerminal(_:)), keyEquivalent: "k")
        edit.addItem(.separator())
        edit.addItem(DictationController.menu())
        add(edit, to: main)

        let view = NSMenu(title: "View")
        view.addItem(item("Hide Workspaces", #selector(W.toggleWorkspaces(_:)), "s", [.command, .control]))
        view.addItem(item("Show Terminal", #selector(W.toggleTerminal(_:)), "t", [.command, .control]))
        view.addItem(item("Show Inspector", #selector(W.toggleInspector(_:)), "i", [.command, .control]))
        view.addItem(item("Hide Inspector and Terminal", #selector(W.toggleRightColumn(_:)), "0", [.command, .option]))
        // Hidden (shortcut and all) while the preview is turned off.
        view.addItem(item("Show Preview", #selector(W.togglePreview(_:)), "p", [.command, .control]))
        view.addItem(.separator())
        for (i, tab) in InspectorTab.allCases.enumerated() {
            let t = item(tab.title, #selector(W.showInspectorTab(_:)), tab.shortcut, [.command, .control])
            t.tag = i
            view.addItem(t)
        }
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(view, to: main)

        let workspace = NSMenu(title: "Workspace")
        workspace.addItem(item("New Workspace…", #selector(W.newWorkspace(_:)), ""))
        workspace.addItem(item("Rename Workspace", #selector(W.renameWorkspace(_:)), "r", [.command, .control]))
        workspace.addItem(item("New Worktree…", #selector(W.newWorktree(_:)), "N"))
        workspace.addItem(item("Remove Worktree…", #selector(W.removeWorktree(_:)), ""))
        workspace.addItem(.separator())
        workspace.addItem(item("Change Folder…", #selector(W.changeWorkspaceFolder(_:)), ""))
        workspace.addItem(item("Open in Finder", #selector(W.openWorkspaceInFinder(_:)), ""))
        workspace.addItem(.separator())
        workspace.addItem(item("Next Workspace", #selector(W.selectNextWorkspace(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]))
        workspace.addItem(item("Previous Workspace", #selector(W.selectPreviousWorkspace(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]))
        // ⌃⌘J / ⌃⌘K: the older shortcuts, kept as hidden alternates.
        workspace.addItem(hidden(item("Next Workspace", #selector(W.selectNextWorkspace(_:)), "j", [.command, .control])))
        workspace.addItem(hidden(item("Previous Workspace", #selector(W.selectPreviousWorkspace(_:)), "k", [.command, .control])))
        workspace.addItem(item("Jump to Conversation Needing You", #selector(W.jumpToAttention(_:)), "u", [.command, .control]))
        for n in 1...9 {
            // ⌘1–9: the nth row of the sidebar's Notifications list.
            let i = item("Notification \(n)", #selector(W.openNotification(_:)), "\(n)")
            i.tag = n
            workspace.addItem(hidden(i))
        }
        workspace.addItem(.separator())
        workspace.addItem(item("Close Workspace", #selector(W.closeWorkspace(_:)), ""))
        add(workspace, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(item("Show Next Tab", #selector(W.selectNextTab(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]))
        window.addItem(item("Show Previous Tab", #selector(W.selectPreviousTab(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]))
        // ⌘} / ⌘{: the macOS-standard tab shortcuts, kept as hidden alternates.
        window.addItem(hidden(item("Show Next Tab", #selector(W.selectNextTab(_:)), "}")))
        window.addItem(hidden(item("Show Previous Tab", #selector(W.selectPreviousTab(_:)), "{")))
        add(window, to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        let setup = item("Check Claude Setup…", #selector(ClaudeSetupMenu.show(_:)), "")
        setup.target = ClaudeSetupMenu.shared
        help.addItem(setup)
        add(help, to: main)
        NSApp.helpMenu = help
        return main
    }

    static func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    /// A key equivalent for an arrow key (NSUpArrowFunctionKey, …).
    static func arrow(_ key: Int) -> String { String(UnicodeScalar(UInt16(key))!) }

    /// Hidden from the menu; the shortcut still works.
    static func hidden(_ i: NSMenuItem) -> NSMenuItem {
        i.isHidden = true
        i.allowsKeyEquivalentWhenHidden = true
        return i
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        main.addItem(i)
    }
}

/// The standard About panel, with a line on what Toasty is built on.
final class AboutPanel: NSObject {
    static let shared = AboutPanel()

    @objc func show(_ sender: Any?) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
        ]
        let credits = NSMutableAttributedString(
            string: "\(ClaudeSDK.shared.summary)\nTerminal emulation by libghostty-vt.\n"
                + "Dictation by NVIDIA Parakeet, on this Mac.\n",
            attributes: attributes)
        // The full notices (Parakeet, Silero VAD, transcribe.cpp, ggml, miniz, Hex).
        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
            var link = attributes
            link[.link] = url
            credits.append(NSAttributedString(string: "Acknowledgements", attributes: link))
        }
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
