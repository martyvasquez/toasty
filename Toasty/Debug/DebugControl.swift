#if DEBUG
import AppKit

/// Debug builds only: drive Toasty from outside for testing, without
/// Accessibility or Screen Recording permissions.
///
/// A command is a distributed notification named
/// `com.martyvasquez.toasty.debug` whose object is a JSON string, e.g.
/// `{"id":"1","cmd":"screenshot","path":"/tmp/a.png"}`. Toasty answers with
/// `com.martyvasquez.toasty.debug.reply` carrying `{"id":…,"ok":…,"result":…}`.
/// `scripts/mctl.swift` is the matching command-line client.
///
/// Features add their own commands with `register` (terminal, workspaces,
/// conversations); the generic ones live here.
@MainActor
enum DebugControl {
    static let name = Notification.Name("com.martyvasquez.toasty.debug")
    static let replyName = Notification.Name("com.martyvasquez.toasty.debug.reply")

    typealias Handler = @MainActor ([String: Any]) throws -> Any?
    private static var handlers: [String: Handler] = [:]

    static func register(_ cmd: String, _ handler: @escaping Handler) { handlers[cmd] = handler }

    static func install() {
        registerBuiltins()
        // Listen on a thread of our own and hop to the main queue: AppKit
        // keeps servicing the main queue during modal sheets and the quit
        // confirmation, when the main run loop doesn't deliver notifications.
        let listener = Thread {
            DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil) { n in
                guard let s = n.object as? String else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { receive(s) } }
            }
            RunLoop.current.run()
        }
        listener.name = "Toasty debug control"
        listener.start()
    }

    private static func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let id = cmd["id"] as? String ?? ""
        var reply: [String: Any] = ["id": id]
        do {
            guard let name = cmd["cmd"] as? String, let handler = handlers[name] else {
                throw DebugError("unknown command \(cmd["cmd"] ?? "nil"); known: \(handlers.keys.sorted().joined(separator: ", "))")
            }
            reply["ok"] = true
            if let result = try handler(cmd) { reply["result"] = result }
        } catch {
            reply["ok"] = false
            reply["error"] = "\(error)"
        }
        send(reply)
    }

    private static func send(_ reply: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"ok":false,"error":"reply not serializable"}"#.utf8)
        DistributedNotificationCenter.default().postNotificationName(
            replyName, object: String(decoding: data, as: UTF8.self), userInfo: nil, deliverImmediately: true)
    }

    struct DebugError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static var window: NSWindow? {
        AppDelegate.shared.windowController?.window ?? NSApp.keyWindow
    }

    // MARK: Built-in commands

    private static func registerBuiltins() {
        register("ping") { _ in "pong" }

        // Quits without the confirmation unless {"confirm":true}.
        register("quit") { cmd in
            AppDelegate.shared.skipQuitConfirmation = !(cmd["confirm"] as? Bool ?? false)
            // From the run loop, not a main-queue block: the confirmation's
            // nested loop would otherwise block the main queue (and this
            // channel) until it's answered.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            return nil
        }

        // Real pixels of our own window: an app may capture its own windows
        // without Screen Recording permission. `appearance`: light|dark.
        register("screenshot") { cmd in
            guard let main = window else { throw DebugError("no window") }
            // {"sheet":true}: the attached sheet (a window of its own).
            let window = cmd["sheet"] as? Bool == true ? (main.attachedSheet ?? main) : main
            let path = cmd["path"] as? String ?? NSTemporaryDirectory() + "toasty-\(Int(Date().timeIntervalSince1970)).png"
            window.displayIfNeeded()
            guard let image = captureWindow(window.windowNumber) else { throw DebugError("capture failed") }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw DebugError("png encode failed")
            }
            try png.write(to: URL(fileURLWithPath: path))
            return ["path": path, "width": image.width, "height": image.height]
        }

        register("appearance") { cmd in
            switch cmd["mode"] as? String {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
            return nil
        }

        register("frame") { cmd in
            guard let window else { throw DebugError("no window") }
            if let w = cmd["width"] as? Double, let h = cmd["height"] as? Double {
                var f = window.frame
                f.origin.y += f.height - h
                f.size = NSSize(width: w, height: h)
                // Optional top-left position in screen points from the top.
                if let x = cmd["x"] as? Double, let top = cmd["top"] as? Double, let screen = NSScreen.screens.first {
                    f.origin = NSPoint(x: x, y: screen.frame.height - top - h)
                }
                window.setFrame(f, display: true)
            }
            return ["width": window.frame.width, "height": window.frame.height]
        }

        // A real click through the window's event dispatch, at (x, y) in
        // points from the window's top-left corner.
        register("click") { cmd in
            guard let window else { throw DebugError("no window") }
            let x = cmd["x"] as? Double ?? 0, y = cmd["y"] as? Double ?? 0
            let point = NSPoint(x: x, y: window.frame.height - y)
            let count = cmd["count"] as? Int ?? 1
            let mods = modifiers(cmd["mods"] as? String)
            let right = cmd["button"] as? String == "right"
            let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            for type in types {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: mods,
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: count, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            return nil
        }

        // A real drag: mouse down at (x1,y1), dragged in steps to (x2,y2), up.
        register("drag") { cmd in
            guard let window else { throw DebugError("no window") }
            let x1 = cmd["x1"] as? Double ?? 0, y1 = cmd["y1"] as? Double ?? 0
            let x2 = cmd["x2"] as? Double ?? 0, y2 = cmd["y2"] as? Double ?? 0
            let mods = modifiers(cmd["mods"] as? String)
            let steps = 8
            // Synthesized drags aren't routed by AppKit without a physical
            // button down, so call the view under the start point directly.
            let start = NSPoint(x: x1, y: window.frame.height - y1)
            guard let view = window.contentView?.hitTest(start) else { throw DebugError("no view") }
            func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.frame.height - y), modifierFlags: mods,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, x1, y1))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                view.mouseDragged(with: event(.leftMouseDragged, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t))
            }
            view.mouseUp(with: event(.leftMouseUp, x2, y2))
            return String(describing: type(of: view))
        }

        // A real scroll-wheel event at (x, y): {"cmd":"wheel","x":..,"y":..,"dy":-5}
        // (dy in lines; negative scrolls toward older content like a trackpad
        // swipe down).
        register("wheel") { cmd in
            guard let window else { throw DebugError("no window") }
            let dy = Int32(cmd["dy"] as? Int ?? 0)
            let x = cmd["x"] as? Double ?? 200, y = cmd["y"] as? Double ?? 200
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else {
                throw DebugError("no event")
            }
            let screen = window.convertPoint(toScreen: NSPoint(x: x, y: window.frame.height - y))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
            guard let e = NSEvent(cgEvent: cg),
                  let view = window.contentView?.hitTest(NSPoint(x: x, y: window.frame.height - y)) else { throw DebugError("no event") }
            view.scrollWheel(with: e)
            return String(describing: type(of: view))
        }

        // Debug builds copy/paste through a private pasteboard.
        TerminalView.pasteboard = NSPasteboard(name: NSPasteboard.Name("com.martyvasquez.toasty.debug"))
        register("pasteboard") { cmd in
            let pb = TerminalView.pasteboard
            if let s = cmd["set"] as? String {
                pb.clearContents()
                pb.setString(s, forType: .string)
            }
            return pb.string(forType: .string) ?? ""
        }

        // Send an action up the responder chain (copy:, paste:, clearTerminal:…).
        register("action") { cmd in
            guard let name = cmd["name"] as? String else { throw DebugError("name required") }
            // To the window's first responder chain even while Toasty is in
            // the background (a nil target would need a key window).
            guard let responder = window?.firstResponder else { throw DebugError("no first responder") }
            return responder.tryToPerform(Selector(name), with: nil)
        }

        // A real key press through the window: {"chars":"a","mods":"cmd,shift","keyCode":0}
        register("key") { cmd in
            guard let window else { throw DebugError("no window") }
            let chars = cmd["chars"] as? String ?? ""
            let mods = modifiers(cmd["mods"] as? String)
            let code = UInt16(cmd["keyCode"] as? Int ?? 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                    // The real path: key equivalents (menus) first, then the
                    // first responder.
                    if window.isKeyWindow { NSApp.sendEvent(e); continue }
                    // Not key (another app is in front; we never steal focus):
                    // menus have no target, so find the item and send its
                    // action down this window's responder chain.
                    if type == .keyDown, !mods.intersection([.command, .control, .option]).isEmpty {
                        if let item = menuItem(key: chars, mods: mods, in: NSApp.mainMenu), let action = item.action {
                            NSApp.mainMenu?.update()
                            let responder = window.firstResponder ?? window
                            if !responder.tryToPerform(action, with: item) { window.windowController?.tryToPerform(action, with: item) }
                            continue
                        }
                        if window.firstResponder?.performKeyEquivalent(with: e) == true { continue }
                    }
                    window.sendEvent(e)
                }
            }
            return nil
        }

        // Which menu item a shortcut hits: {"cmd":"menuMatch","chars":"1","mods":"opt"}
        register("menuMatch") { cmd in
            let item = menuItem(key: cmd["chars"] as? String ?? "", mods: modifiers(cmd["mods"] as? String), in: NSApp.mainMenu)
            return item.map { "\($0.title) \($0.action.map(NSStringFromSelector) ?? "-") tag=\($0.tag)" } ?? "none"
        }

        register("dump") { _ in
            guard let window else { throw DebugError("no window") }
            var views: [String] = []
            @MainActor func walk(_ v: NSView, _ depth: Int) {
                guard depth < 40 else { return }
                var line = String(repeating: " ", count: depth) + String(describing: type(of: v))
                    + " \(v.frame.integral)" + (v.isHidden ? " hidden" : "")
                if let t = v as? NSTextView { line += " text=" + String(t.string.prefix(40)).replacingOccurrences(of: "\n", with: " ") }
                views.append(line)
                v.subviews.forEach { walk($0, depth + 1) }
            }
            if let root = window.contentView?.superview { walk(root, 0) }
            var out: [String: Any] = [
                "frame": NSStringFromRect(window.frame),
                "title": window.title,
                "key": window.isKeyWindow,
                "firstResponder": window.firstResponder.map { "\(type(of: $0))" } ?? "",
                "views": views,
            ]
            for (k, v) in dumpers { out[k] = v() }
            return out
        }
    }

    /// Extra state for `dump`, contributed by features.
    private static var dumpers: [String: @MainActor () -> Any] = [:]
    static func addDump(_ key: String, _ f: @escaping @MainActor () -> Any) { dumpers[key] = f }

    /// The menu item whose shortcut is `key` + `mods` (hidden items too).
    static func menuItem(key: String, mods: NSEvent.ModifierFlags, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        let want = mods.intersection([.command, .control, .option, .shift])
        for item in menu.items {
            if let sub = menuItem(key: key, mods: mods, in: item.submenu) { return sub }
            guard !item.keyEquivalent.isEmpty else { continue }
            var itemMods = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            var itemKey = item.keyEquivalent
            // An uppercase or shifted-symbol key equivalent implies Shift.
            if itemKey.lowercased() != itemKey || "{}|:\"<>?~!@#$%^&*()_+".contains(itemKey) { itemMods.insert(.shift) }
            itemKey = itemKey.lowercased()
            if itemMods == want, itemKey == key.lowercased() { return item }
        }
        return nil
    }

    static func modifiers(_ s: String?) -> NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        for part in (s ?? "").split(separator: ",") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd": m.insert(.command)
            case "shift": m.insert(.shift)
            case "opt", "alt": m.insert(.option)
            case "ctrl": m.insert(.control)
            default: break
            }
        }
        return m
    }

    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage, looked up at runtime (it's unavailable to
    /// Swift in the current SDK).
    private static func captureWindow(_ number: Int) -> CGImage? {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: CaptureFn.self)
        // CGRectNull, kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return fn(.null, 1 << 3, UInt32(number), 1 << 0)?.takeRetainedValue()
    }
}
#endif
