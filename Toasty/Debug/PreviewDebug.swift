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
            // {"redButton":true}: the close button of the browser window in front.
            if cmd["redButton"] as? Bool == true { PreviewStore.shared.frontWindow?.window?.performClose(nil) }
            // {"reopen":true}: the first moved-out tab's pseudo-tab, clicked.
            if cmd["reopen"] as? Bool == true, let ref = w.browserTabs.first(where: \.isDetached) {
                PreviewStore.shared.showWindow(page: ref.id, in: w)
            }
            // {"raise":true}: the browser window in front of Toasty's, forward (its pseudo-tab's click).
            if cmd["raise"] as? Bool == true, let c = PreviewStore.shared.frontWindow { PreviewStore.shared.showWindow(page: c.session.pageID, in: c.workspace) }
            // {"window":true}: ⇧⌘B (the browser tab); false: close the window in front.
            if let show = cmd["window"] as? Bool {
                if show { PreviewStore.shared.showTab(w) } else { PreviewStore.shared.frontWindow?.close() }
            }
            // {"move":"window"} / {"move":"tab"}: the tab's Move to Window, the window's Move to Tab.
            // {"newTab":"address"}: + ▸ Browser, then open the address in it.
            if let address = cmd["newTab"] as? String {
                w.newBrowserTab()
                if let id = w.shownBrowserTabID { PreviewStore.shared.page(id, in: w).open(address) }
            }
            // {"agent":0,"agentOpen":"address"}: the page conversation 0's Claude drives (its own tab), opened.
            if let i = cmd["agent"] as? Int, w.conversations.indices.contains(i) {
                let page = PreviewStore.shared.agentPage(for: w.conversations[i], in: w)
                if let address = cmd["agentOpen"] as? String { page.open(address) }
            }
            // {"closePage":true}: close the shown browser tab (⌘W).
            if cmd["closePage"] as? Bool == true, let id = w.shownBrowserTabID { PreviewStore.shared.closeBrowserTab(id, in: w) }
            // {"move":"window"}: the shown browser tab's Move to Window;
            // {"move":"tab"}: the window in front's Move Back to Tab.
            if let to = cmd["move"] as? String {
                if to == "window", let id = w.shownBrowserTabID { PreviewStore.shared.detach(id, in: w) }
                if to == "tab", let c = PreviewStore.shared.frontWindow { PreviewStore.shared.attach(c.session.pageID, in: c.workspace) }
            }
            if let v = (cmd["viewport"] as? String).flatMap(PreviewViewport.init(rawValue:)) { s.setViewport(v) }
            if let on = cmd["commenting"] as? Bool { s.setCommenting(on) }
            // {"twinPhone":"mobile-max"}: side by side's iPhone menu.
            if let v = (cmd["twinPhone"] as? String).flatMap(PreviewViewport.init(rawValue:)) { s.setTwinPhone(v) }
            // {"sideBySide":true}: the footer's side-by-side button.
            if let on = cmd["sideBySide"] as? Bool {
                s.setSideBySide(on)
                PreviewStore.shared.window(for: s)?.fitSideBySide(of: s)
            }
            var out: [String: Any] = ["enabled": true, "address": s.address, "loading": s.isLoading]
            out["url"] = s.url?.absoluteString ?? ""
            out["viewport"] = s.viewportDescription
            out["failure"] = s.failure?.reason ?? ""
            out["commenting"] = s.commenting
            out["sideBySide"] = s.sideBySide
            out["twinURL"] = s.twin?.url?.absoluteString ?? ""
            if let twin = s.twin { out["twinFrame"] = NSStringFromRect(twin.convert(twin.bounds, to: nil)) }
            if let pick = s.pick { out["pick"] = "\(pick.kind.rawValue) \(pick.selector) \(pick.rect)" }
            out["console"] = s.console.map { "[\($0.level)] \($0.text)" }
            out["hosted"] = s.stage != nil
            if let f = PreviewStore.shared.frontWindow?.session {
                out["front"] = "started=\(f.started) url=\(f.url?.absoluteString ?? "-") address=\(f.address) open=\(f.windowOpen) hosted=\(f.stage != nil) web=\(f.webView?.superview.map { "\(type(of: $0))" } ?? "none") loading=\(f.isLoading) failure=\(f.failure?.reason ?? "-") webFrame=\(f.webView.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? "-") hidden=\(f.webView?.isHiddenOrHasHiddenAncestor ?? false) inWindow=\(f.webView?.window === PreviewStore.shared.frontWindow?.window) backstage=\(f.webView?.window.map { "\(type(of: $0)) \($0.frame)" } ?? "-")"
            }
            out["windowOpen"] = s.windowOpen
            out["webSuperview"] = s.webView?.superview.map { "\(type(of: $0)) in \($0.window.map { "\(type(of: $0))" } ?? "no window")" } ?? "none"
            if let web = s.webView { out["frame"] = NSStringFromRect(web.convert(web.bounds, to: nil)) }
            // {"action":"closeTab:"}: a menu command, sent the way the menu
            // sends it (to the key window's responder chain).
            if let action = cmd["action"] as? String {
                out["handled"] = NSApp.sendAction(NSSelectorFromString(action), to: nil, from: nil)
            }
            // {"commentTab":1}: pin the active workspace's second tab in the comment field;
            // {"commentTab":-1}: back to the last active tab.
            if let i = cmd["commentTab"] as? Int {
                s.commentTabID = w.conversations.indices.contains(i) ? w.conversations[i].id : nil
            }
            if cmd["back"] as? Bool == true { s.goBack() }
            // {"commentText":"…"}: typed into the comment field (as dictation inserts).
            if let text = cmd["commentText"] as? String, let window = PreviewStore.shared.frontWindow?.window,
               let field = window.firstResponder as? ComposerTextView {
                field.insertText(text, replacementRange: field.selectedRange())
            }
            out["canGoBack"] = s.canGoBack
            out["commentTab"] = s.commentTab(in: w)?.title ?? ""
            out["selectedTab"] = w.selected?.title ?? ""
            out["windows"] = w.browserTabs.filter(\.isDetached).count
            out["activeWorkspace"] = w.name
            // {"browserFrame":"{{x, y}, {w, h}}"}: move the browser window (for pictures).
            if let f = cmd["browserFrame"] as? String { PreviewStore.shared.frontWindow?.window?.setFrame(NSRectFromString(f), display: true) }
            // {"pageSize":"1440x900"}: a desktop preset from the size menu.
            if let p = cmd["pageSize"] as? String {
                let n = p.split(separator: "x").compactMap { Double($0) }
                if n.count == 2 { PreviewStore.shared.frontWindow?.setPageSize(CGSize(width: n[0], height: n[1])) }
            }
            if let shown = PreviewStore.shared.frontWindow?.session {
                out["shownViewport"] = shown.viewport.rawValue
                out["shownPage"] = "\(Int(shown.shownPageSize.width))x\(Int(shown.shownPageSize.height))"
            }
            // {"click":[x, y]}: a click in the browser window, in points from its
            // top-left (through the app, where menus' event monitors listen).
            if let xy = cmd["click"] as? [Double], xy.count == 2, let window = PreviewStore.shared.frontWindow?.window {
                let point = NSPoint(x: xy[0], y: window.frame.height - xy[1])
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.sendEvent(e)
                    }
                }
            }
            // {"menuShot":"/path.png"}: a picture of the menu open over the browser window.
            if let path = cmd["menuShot"] as? String, let window = PreviewStore.shared.frontWindow?.window,
               let panel = window.childWindows?.first(where: { $0.isVisible }) {
                out["menuFrame"] = NSStringFromRect(panel.frame)
                out["menuContentFitting"] = NSStringFromSize(panel.contentView?.fittingSize ?? .zero)
                if let v = panel.contentView {
                    let i = v.safeAreaInsets
                    out["menuSafeArea"] = "\(i.top) \(i.left) \(i.bottom) \(i.right)"
                    out["menuBounds"] = NSStringFromRect(v.bounds)
                }
                if let image = DebugControl.captureWindow(panel.windowNumber),
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
            // {"windowMenu":true}: Window ▸ Browser, as the menu does it.
            if cmd["windowMenu"] as? Bool == true, let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Window" })?.submenu,
               let i = menu.items.firstIndex(where: { $0.title == "Browser" }) {
                menu.update()
                out["windowMenuShown"] = !menu.items[i].isHidden
                menu.performActionForItem(at: i)
            }
            // {"shot":"/path.png"}: a picture of the browser window itself.
            if let path = cmd["shot"] as? String, let window = PreviewStore.shared.frontWindow?.window,
               let image = DebugControl.captureWindow(window.windowNumber),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            out["windowOpen"] = s.windowOpen
            out["backstage"] = PreviewBackstage.shared.holding
            out["agentActive"] = s.agentActive
            if let window = PreviewStore.shared.frontWindow?.window {
                out["windowShows"] = PreviewStore.shared.frontWindow?.workspace.name ?? "" 
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
        // ({"twin":true}: side by side's iPhone page)
        DebugControl.registerAsync("previewPicker") { cmd in
            guard let w = WorkspaceStore.shared.active else { throw DebugControl.DebugError("no workspace") }
            let value = try await PreviewStore.shared.session(for: w).debugPickerWorld(cmd["js"] as? String ?? "", inTwin: cmd["twin"] as? Bool == true)
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
