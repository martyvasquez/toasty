#if DEBUG
import AppKit

/// Debug commands for the preview browser (the active workspace's).
enum PreviewDebug {
    static func install() {
        // {"cmd":"preview","enabled":true} turns the feature on or off;
        // {"cmd":"preview"} says what the active workspace's preview shows.
        DebugControl.register("preview") { cmd in
            if let on = cmd["enabled"] as? Bool { PreviewSettings.shared.enabled = on }
            if let to = (cmd["commentsTo"] as? String).flatMap(PreviewSettings.CommentDestination.init(rawValue:)) {
                PreviewSettings.shared.commentsTo = to
            }
            if let pane = cmd["settings"] as? String {
                SettingsWindowController.shared.show(nil)
                SettingsWindowController.shared.debugSelect(pane)
            }
            guard PreviewSettings.shared.enabled, let w = WorkspaceStore.shared.active else {
                return ["enabled": PreviewSettings.shared.enabled]
            }
            let s = PreviewStore.shared.session(for: w)
            // {"open":"localhost:3000"} opens a page without showing the
            // window; {"window":true} shows it, false closes it.
            if let address = cmd["open"] as? String { s.open(address) }
            if let show = cmd["window"] as? Bool {
                if show { PreviewStore.shared.showWindow() } else { PreviewStore.shared.presenter?.close() }
            }
            // {"showWorkspace":"name"}: pick it in the window's workspace menu.
            if let name = cmd["showWorkspace"] as? String {
                PreviewStore.shared.presenter?.show(WorkspaceStore.shared.workspaces.first { $0.name == name })
            }
            if let v = (cmd["viewport"] as? String).flatMap(PreviewViewport.init(rawValue:)) { s.setViewport(v) }
            if let on = cmd["commenting"] as? Bool { s.setCommenting(on) }
            var out: [String: Any] = ["enabled": true, "address": s.address, "loading": s.isLoading]
            out["url"] = s.url?.absoluteString ?? ""
            out["viewport"] = s.viewportDescription
            out["failure"] = s.failure?.reason ?? ""
            out["commenting"] = s.commenting
            if let pick = s.pick { out["pick"] = "\(pick.kind.rawValue) \(pick.selector) \(pick.rect)" }
            out["console"] = s.console.map { "[\($0.level)] \($0.text)" }
            out["hosted"] = s.stage != nil
            if let web = s.webView { out["frame"] = NSStringFromRect(web.convert(web.bounds, to: nil)) }
            // {"action":"closeTab:"}: a menu command, sent the way the menu
            // sends it (to the key window's responder chain).
            if let action = cmd["action"] as? String {
                out["handled"] = NSApp.sendAction(NSSelectorFromString(action), to: nil, from: nil)
            }
            // {"commentTab":1}: pick the active workspace's second tab in the comment field.
            if let i = cmd["commentTab"] as? Int, w.conversations.indices.contains(i) { s.commentTabID = w.conversations[i].id }
            if cmd["back"] as? Bool == true { s.goBack() }
            out["canGoBack"] = s.canGoBack
            out["commentTab"] = s.commentTab(in: w)?.title ?? ""
            out["selectedTab"] = w.selected?.title ?? ""
            out["withPages"] = PreviewStore.shared.workspacesWithPages().map(\.name)
            out["activeWorkspace"] = w.name
            // {"browserFrame":"{{x, y}, {w, h}}"}: move the browser window (for pictures).
            if let f = cmd["browserFrame"] as? String { PreviewStore.shared.presenter?.window?.setFrame(NSRectFromString(f), display: true) }
            // {"pageSize":"1440x900"}: a desktop preset from the size menu.
            if let p = cmd["pageSize"] as? String {
                let n = p.split(separator: "x").compactMap { Double($0) }
                if n.count == 2 { PreviewStore.shared.presenter?.setPageSize(CGSize(width: n[0], height: n[1])) }
            }
            if let shown = PreviewStore.shared.presenter?.session {
                out["shownViewport"] = shown.viewport.rawValue
                out["shownPage"] = "\(Int(shown.shownPageSize.width))x\(Int(shown.shownPageSize.height))"
            }
            // {"shot":"/path.png"}: a picture of the browser window itself.
            if let path = cmd["shot"] as? String, let window = PreviewStore.shared.presenter?.window,
               let image = DebugControl.captureWindow(window.windowNumber),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            out["windowOpen"] = s.windowOpen
            out["backstage"] = PreviewBackstage.shared.holding
            out["agentActive"] = s.agentActive
            if let window = PreviewStore.shared.presenter?.window {
                out["windowShows"] = PreviewStore.shared.presenter?.workspace?.name ?? "" 
                out["windowVisible"] = window.isVisible
                out["windowKey"] = window.isKeyWindow
                out["windowFrame"] = NSStringFromRect(window.frame)
            }
            out["mainKey"] = AppDelegate.shared.windowController?.window?.isKeyWindow ?? false
            out["tools"] = PreviewTools.servers().count
            out["draft"] = w.selected?.draft ?? ""
            out["attachments"] = w.selected?.attachments.count ?? 0
            return out
        }

        // One of Claude's tools, as the bridge would relay it:
        // {"cmd":"previewTool","tool":"navigate","input":{"url":"localhost:3000"}}
        // A screenshot's image is written to {"path":…} instead of returned.
        DebugControl.registerAsync("previewTool") { cmd in
            // {"workspace":"name"}: that workspace's conversation, on screen or not.
            let named = (cmd["workspace"] as? String).flatMap { name in WorkspaceStore.shared.workspaces.first { $0.name == name } }
            guard let c = (named ?? WorkspaceStore.shared.active)?.selected else { throw DebugControl.DebugError("no conversation") }
            let call: [String: Any] = ["server": PreviewTools.serverName, "tool": cmd["tool"] as? String ?? "",
                                       "input": cmd["input"] as? [String: Any] ?? [:]]
            final class Box: @unchecked Sendable { var value: [String: Any] = [:] }
            let box = Box()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                PreviewTools.handle(call, from: c) { box.value = $0; continuation.resume() }
            }
            let result = box.value
            var out: [String: Any] = ["isError": result["isError"] as? Bool ?? false]
            var texts: [String] = []
            for block in result["content"] as? [[String: Any]] ?? [] {
                if let t = block["text"] as? String { texts.append(t) }
                if let data = (block["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                    out["imageBytes"] = data.count
                    out["mimeType"] = block["mimeType"] as? String ?? ""
                    if let path = cmd["path"] as? String { try data.write(to: URL(fileURLWithPath: path)) }
                }
            }
            out["text"] = texts.joined(separator: "\n")
            return out
        }

        // JavaScript in the picker's own world: {"cmd":"previewPicker","js":"return 1"}
        DebugControl.registerAsync("previewPicker") { cmd in
            guard let w = WorkspaceStore.shared.active else { throw DebugControl.DebugError("no workspace") }
            let value = try await PreviewStore.shared.session(for: w).debugPickerWorld(cmd["js"] as? String ?? "")
            return "\(value ?? "nil")"
        }

        // Type a note for the current pick and send it: {"to":"teeUp"} or
        // "conversation" (default: where the setting says).
        DebugControl.registerAsync("previewComment") { cmd in
            guard let w = WorkspaceStore.shared.active else { throw DebugControl.DebugError("no workspace") }
            await PreviewStore.shared.session(for: w).comment(cmd["note"] as? String ?? "", in: w,
                to: (cmd["to"] as? String).flatMap(PreviewSettings.CommentDestination.init(rawValue:)) ?? PreviewSettings.shared.commentsTo)
            return ["draft": w.selected?.draft ?? "", "attachments": w.selected?.attachments.count ?? 0,
                    "teeUps": w.teeUps.map { "\($0.text) [\($0.images.count) image(s)]" }]
        }
    }
}
#endif
