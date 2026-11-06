#if DEBUG
import AppKit

/// Debug commands for the terminal (Phase 1 spike: the window's terminal).
enum TerminalDebug {
    static var terminal: TerminalView? { AppDelegate.shared.windowController?.terminal?.terminal }

    static func install() {
        // Type text into the shell: {"cmd":"terminalType","text":"ls\r"}
        DebugControl.register("terminalType") { cmd in
            guard let t = terminal else { throw DebugControl.DebugError("no terminal") }
            t.debugType((cmd["text"] as? String ?? "").replacingOccurrences(of: "\\r", with: "\r"))
            return nil
        }
        DebugControl.register("terminalText") { _ in terminal?.vt.plainText ?? "" }
        DebugControl.register("terminalState") { _ in terminal?.debugState ?? [:] }
        // IME: {"cmd":"terminalIME","marked":"に"} then {"cmd":"terminalIME","commit":"日本"}
        DebugControl.register("terminalIME") { cmd in
            guard let t = terminal else { return nil }
            if let m = cmd["marked"] as? String {
                t.setMarkedText(m, selectedRange: NSRange(location: m.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            if let c = cmd["commit"] as? String { t.insertText(c, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            return NSStringFromRect(t.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil))
        }
        DebugControl.register("activate") { _ in
            NSApp.activate(ignoringOtherApps: true)
            terminal?.window?.makeKeyAndOrderFront(nil)
            return nil
        }
        DebugControl.register("terminalFocus") { _ in
            guard let t = terminal else { return nil }
            t.window?.makeFirstResponder(t)
            return nil
        }
    }
}
#endif
