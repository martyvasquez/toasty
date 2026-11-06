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
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { n in
            guard let s = n.object as? String else { return }
            MainActor.assumeIsolated { receive(s) }
        }
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

        register("quit") { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return nil
        }

        // Real pixels of our own window: an app may capture its own windows
        // without Screen Recording permission. `appearance`: light|dark.
        register("screenshot") { cmd in
            guard let window else { throw DebugError("no window") }
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
                    if type == .keyDown, mods.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: e) == true { continue }
                    window.sendEvent(e)
                }
            }
            return nil
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
