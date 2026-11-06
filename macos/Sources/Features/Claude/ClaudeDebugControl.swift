#if DEBUG
import AppKit

/// mostty (Debug builds only): drive native Claude tabs from outside for
/// testing, without Accessibility or Screen Recording permissions. Post a
/// distributed notification named `com.mostty.debug` whose object is a JSON
/// command, e.g. {"cmd":"open","cwd":"/tmp/x"}, {"cmd":"type","text":"hi"},
/// {"cmd":"submit"}, {"cmd":"snapshot","path":"/tmp/a.png"},
/// {"cmd":"dump","path":"/tmp/a.json"}, {"cmd":"allow"}, {"cmd":"deny"},
/// {"cmd":"answer","index":0}, {"cmd":"interrupt"}, {"cmd":"terminal"},
/// {"cmd":"runInTerminal","text":"ls"}, {"cmd":"quit"}.
@MainActor
enum ClaudeDebugControl {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.mostty.debug"), object: nil, queue: .main
        ) { n in
            guard let s = n.object as? String,
                  let data = s.data(using: .utf8),
                  let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            MainActor.assumeIsolated { handle(cmd) }
        }
    }

    private static var controller: TerminalController? {
        TerminalController.all.first { $0.workspace != nil && $0.window?.isKeyWindow == true }
            ?? TerminalController.all.first { $0.workspace != nil && $0.window?.alphaValue == 1 }
            ?? TerminalController.all.first { $0.workspace != nil }
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

    private static func handle(_ cmd: [String: Any]) {
        let conv = controller?.claude
        switch cmd["cmd"] as? String {
        case "open":
            NSApp.activate(ignoringOtherApps: true)
            WorkspaceManager.shared.newNativeClaudeTab(cwd: cmd["cwd"] as? String, resume: cmd["resume"] as? String)
        case "type":
            conv?.draft += cmd["text"] as? String ?? ""
        case "mode":
            conv?.setPermissionMode(cmd["mode"] as? String ?? "default")
        case "submit":
            conv?.submit()
        case "interrupt":
            conv?.interrupt()
        case "allow", "deny", "answer":
            guard let conv, let r = conv.requests.first else { return }
            switch cmd["cmd"] as? String {
            case "allow":
                conv.respond(to: r, ["behavior": "allow", "updatedInput": r.input])
            case "deny":
                conv.respond(to: r, ["behavior": "deny", "message": "The user rejected this.", "interrupt": true])
            default:
                var input = r.input
                let q = (input["questions"] as? [[String: Any]])?.first ?? [:]
                let opts = q["options"] as? [[String: Any]] ?? []
                let i = cmd["index"] as? Int ?? 0
                input["answers"] = [q["question"] as? String ?? "": opts.indices.contains(i) ? opts[i]["label"] as? String ?? "" : ""]
                conv.respond(to: r, ["behavior": "allow", "updatedInput": input])
            }
        case "terminal":
            controller?.workspace?.toggleTerminal()
        case "runInTerminal":
            controller?.workspace?.runInTerminal(cmd["text"] as? String ?? "")
        case "newTab":
            controller?.workspace?.newConversation()
        case "selectTab":
            controller?.workspace?.select(index: cmd["index"] as? Int ?? 0)
        case "newTerminal":
            controller?.workspace?.newTerminal()
        case "selectTerminal":
            if let w = controller?.workspace, let i = cmd["index"] as? Int, w.terminals.indices.contains(i) {
                w.selectTerminal(w.terminals[i].id)
            }
        case "screenshot":
            // Real pixels of our own window (an app may capture its own
            // windows without Screen Recording permission).
            guard let path = cmd["path"] as? String,
                  let window = controller?.window ?? NSApp.keyWindow,
                  let image = captureWindow(window.windowNumber) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        case "click":
            // A real click through the window's event dispatch, at (x, y) in
            // points from the window's top-left corner.
            guard let window = controller?.window else { return }
            let x = cmd["x"] as? Double ?? 0, y = cmd["y"] as? Double ?? 0
            let point = NSPoint(x: x, y: window.frame.height - y)
            let count = cmd["count"] as? Int ?? 1
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    window.sendEvent(e)
                }
            }
        case "legacyTest":
            // Two windows of one workspace, as an older mostty restores them
            // (native tabs), one with a Claude CLI session to migrate.
            guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
            let id = UUID()
            let cwd = cmd["cwd"] as? String ?? NSHomeDirectory()
            WorkspaceManager.shared.setName("Legacy", for: id)
            WorkspaceManager.shared.setFolder(cwd, for: id)
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = cwd
            TerminalController.pendingWorkspaceID = id
            let a = TerminalController.newWindow(ghostty, withBaseConfig: config)
            let b = TerminalController.newWindow(ghostty, withBaseConfig: config)
            TerminalController.pendingWorkspaceID = nil
            a.workspaceID = id
            b.workspaceID = id
            ClaudeWorkspace.migrate(a, sessions: [:])
            var sessions: [String: WorkspaceNotifier.ClaudeSession] = [:]
            if let sid = cmd["session"] as? String { sessions["x"] = .init(id: sid, cwd: cwd) }
            ClaudeWorkspace.migrate(b, sessions: sessions)
        case "render":
            if let path = cmd["path"] as? String, let text = try? String(contentsOfFile: path, encoding: .utf8) {
                conv?.debugAppendReply(text)
            }
        case "scroll":
            // Scroll the transcript to a fraction (0 top … 1 bottom).
            guard let root = controller?.window?.contentView else { return }
            func scrollViews(_ v: NSView) -> [NSScrollView] {
                (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews)
            }
            if let sv = scrollViews(root).filter({ ($0.documentView?.frame.height ?? 0) > 1000 })
                .max(by: { $0.frame.width < $1.frame.width }), let doc = sv.documentView {
                let f = cmd["to"] as? Double ?? 0
                let y = (doc.frame.height - sv.contentSize.height) * CGFloat(doc.isFlipped ? f : 1 - f)
                sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                sv.reflectScrolledClipView(sv.contentView)
            }
        case "workspace":
            WorkspaceManager.shared.activate(index: cmd["index"] as? Int ?? 0)
        case "terminalReturn":
            controller?.focusedSurface?.mosttySendReturn()
        case "snapshot":
            guard let path = cmd["path"] as? String, let root = controller?.window?.contentView else { return }
            // "transcript": just the conversation's scrolled content.
            func find(_ v: NSView) -> NSView? {
                if let sv = v as? NSScrollView, let doc = sv.documentView,
                   doc.frame.minX >= 0, sv.frame.width > 300, cmd["view"] as? String == "transcript",
                   String(describing: type(of: sv)).contains("Hosting") { return doc }
                for c in v.subviews { if let f = find(c) { return f } }
                return nil
            }
            let view = (cmd["view"] as? String == "transcript" ? root.subviews.lazy.compactMap { find($0) }.first : nil) ?? root
            let window = controller?.window
            let saved = window?.appearance
            if cmd["light"] as? Bool ?? true { window?.appearance = NSAppearance(named: .aqua) }
            defer { window?.appearance = saved }
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            // Composite over the window background (cacheDisplay leaves it out).
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.white.setFill()
            view.bounds.fill()
            rep.draw(in: view.bounds)
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
                try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        case "dump":
            guard let path = cmd["path"] as? String else { return }
            var out: [String: Any] = [:]
            if let conv {
                out["phase"] = "\(conv.phase)"
                out["session"] = conv.sessionID ?? NSNull()
                out["model"] = conv.model ?? NSNull()
                out["mode"] = conv.permissionMode
                out["requests"] = conv.requests.map { ["tool": $0.toolName, "suggestions": $0.suggestions.count] }
                out["items"] = conv.items.map { item -> [String: Any] in
                    ["kind": "\(item.kind)", "text": String(item.text.prefix(300)), "tool": item.toolName,
                     "result": String((item.result ?? "").prefix(200)), "finalized": item.finalized,
                     "children": item.children.count]
                }
                if let w = controller?.workspace {
                    out["terminalVisible"] = w.terminalVisible
                    out["tabs"] = w.conversations.map { $0.title }
                    out["selectedTab"] = w.conversations.firstIndex { $0.id == w.selected?.id } ?? -1
                    out["terminals"] = w.terminals.count
                    out["selectedTerminal"] = w.selectedTerminalIndex ?? -1
                    out["windows"] = TerminalController.all.count
                }
                var views: [String] = []
                func walk(_ v: NSView, _ depth: Int) {
                    let cls = String(describing: type(of: v))
                    if depth < 40 {
                        var line = String(repeating: " ", count: depth) + cls + " \(v.frame.integral) hidden=\(v.isHidden) alpha=\(v.alphaValue)"
                        if let t = v as? NSTextView { line += " text=" + String(t.string.prefix(40)).replacingOccurrences(of: "\n", with: " ") }
                        if let sv = v as? NSScrollView { line += " drawsBG=\(sv.drawsBackground) bg=\(sv.backgroundColor)" }
                        views.append(line)
                    }
                    v.subviews.forEach { walk($0, depth + 1) }
                }
                if let root = controller?.window?.contentView { walk(root, 0) }
                out["views"] = views
                out["firstResponder"] = controller?.window?.firstResponder.map { "\(type(of: $0))" } ?? ""
                out["title"] = controller?.window?.title ?? ""
                out["notifierState"] = WorkspaceNotifier.shared.agentState(conv).map { "\($0)" } ?? "idle"
                out["attention"] = conv.attention
            }
            out["workspaces"] = WorkspaceManager.shared.items.map { ["name": $0.name, "working": $0.working, "waiting": $0.waiting, "message": $0.message ?? ""] }
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }
}
#endif
