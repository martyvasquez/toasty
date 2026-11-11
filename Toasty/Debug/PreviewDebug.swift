#if DEBUG
import AppKit

/// Debug commands for the preview browser (the active workspace's).
enum PreviewDebug {
    static func install() {
        // {"cmd":"preview","enabled":true} turns the feature on or off;
        // {"cmd":"preview"} says what the active workspace's preview shows.
        DebugControl.register("preview") { cmd in
            if let on = cmd["enabled"] as? Bool { PreviewSettings.shared.enabled = on }
            // {"drawer":false} puts the conversation away (while a desktop
            // page has the whole window); true slides it out.
            if let open = cmd["drawer"] as? Bool { PreviewDrawer.shared.setOpen(open) }
            if let pane = cmd["settings"] as? String {
                SettingsWindowController.shared.show(nil)
                SettingsWindowController.shared.debugSelect(pane)
            }
            guard PreviewSettings.shared.enabled, let w = WorkspaceStore.shared.active else {
                return ["enabled": PreviewSettings.shared.enabled]
            }
            let s = PreviewStore.shared.session(for: w)
            if let address = cmd["open"] as? String {
                w.showPreview()
                s.open(address)
            }
            if let show = cmd["show"] as? Bool { show ? w.showPreview() : w.hidePreview() }
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
            out["titlebarWidth"] = AppDelegate.shared.windowController?.layout.terminalWidth ?? -1
            if let w = cmd["phoneWidth"] as? Double ?? (cmd["phoneWidth"] as? Int).map(Double.init) {
                PreviewSettings.shared.phoneColumnWidth = CGFloat(w)
                AppDelegate.shared.windowController?.split.applyColumn()
            }
            out["phoneWidth"] = Double(PreviewSettings.shared.phoneColumnWidth)
            out["drawerActive"] = PreviewDrawer.shared.active
            out["drawerOpen"] = PreviewDrawer.shared.open
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

        // Type a note for the current pick and add it to the composer.
        DebugControl.registerAsync("previewComment") { cmd in
            guard let w = WorkspaceStore.shared.active else { throw DebugControl.DebugError("no workspace") }
            await PreviewStore.shared.session(for: w).comment(cmd["note"] as? String ?? "", in: w, send: cmd["send"] as? Bool ?? true)
            return ["draft": w.selected?.draft ?? "", "attachments": w.selected?.attachments.count ?? 0]
        }
    }
}
#endif
