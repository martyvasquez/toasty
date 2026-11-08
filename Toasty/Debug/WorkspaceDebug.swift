#if DEBUG
import AppKit

/// Debug commands for workspaces, conversation tabs and terminal tabs.
enum WorkspaceDebug {
    typealias E = DebugControl.DebugError
    static var store: WorkspaceStore { .shared }

    static func install() {
        // The whole model plus the window's layout.
        DebugControl.register("state") { _ in state() }

        // {"cmd":"workspace","action":"new","folder":"/path"} · activate|rename|move|close|folder with "index".
        DebugControl.register("workspace") { cmd in
            let action = cmd["action"] as? String ?? "list"
            @MainActor func target() throws -> Workspace {
                if let i = cmd["index"] as? Int {
                    guard store.workspaces.indices.contains(i) else { throw E("no workspace \(i)") }
                    return store.workspaces[i]
                }
                guard let w = store.active else { throw E("no active workspace") }
                return w
            }
            switch action {
            case "list": break
            case "new":
                guard let folder = cmd["folder"] as? String else { throw E("folder=") }
                store.create(folder: folder, name: cmd["name"] as? String)
            case "activate": store.activate(try target().id)
            case "rename":
                if let name = cmd["name"] as? String { store.setName(name, for: try target().id) }
                else { store.renamingID = try target().id }
            case "move": store.move(try target().id, by: cmd["by"] as? Int ?? 1)
            case "moveTo":
                guard let to = cmd["to"] as? Int, store.workspaces.indices.contains(to) else { throw E("to=") }
                store.move(try target().id, to: store.workspaces[to].id)
            case "close": store.close(try target().id)
            case "folder":
                guard let path = cmd["path"] as? String else { throw E("path=") }
                let w = try target()
                w.folder = path
                store.setNeedsSave()
            case "next": store.activateRelative(1)
            case "previous": store.activateRelative(-1)
            default: throw E("unknown action \(action)")
            }
            return state()
        }

        // {"cmd":"inspector","tab":"changes","visible":true,"terminal":false,"diff":0}
        DebugControl.register("inspector") { cmd in
            guard let w = store.active else { throw E("no active workspace") }
            if let t = cmd["tab"] as? String, let tab = InspectorTab(rawValue: t) { w.showInspector(tab) }
            if let v = cmd["visible"] as? Bool { v ? w.showInspector() : w.hideInspector() }
            if let v = cmd["terminal"] as? Bool { v ? w.showTerminal() : w.hideTerminal() }
            if let f = cmd["fraction"] as? Double { store.inspectorFraction = f }
            if let i = cmd["diff"] as? Int {
                w.diffFile = w.changes.files.indices.contains(i) ? w.changes.files[i] : nil
            }
            return [
                "inspector": w.inspectorVisible, "tab": w.inspectorTab.rawValue, "terminal": w.terminalVisible,
                "fraction": store.inspectorFraction,
                "columnWidth": AppDelegate.shared.windowController.map { $0.split.terminalItem.isCollapsed ? 0 : $0.split.rightColumn.view.frame.width } ?? -1,
                "inspectorHeight": AppDelegate.shared.windowController?.split.rightColumn.inspectorItem.viewController.view.frame.height ?? -1,
                "git": "\(w.changes.state)", "branch": w.changes.branch ?? "", "ahead": w.changes.ahead, "behind": w.changes.behind,
                "files": w.changes.files.map { "\($0.status.rawValue) \($0.path) +\($0.added.map(String.init) ?? "-") -\($0.removed.map(String.init) ?? "-")" },
                "diff": w.diffFile?.path ?? "",
            ] as [String: Any]
        }

        // {"cmd":"tab","action":"new"} · select|close|rename|status with "index".
        DebugControl.register("tab") { cmd in
            guard let w = store.active else { throw E("no active workspace") }
            let action = cmd["action"] as? String ?? "new"
            @MainActor func target() throws -> ClaudeConversation {
                if let i = cmd["index"] as? Int {
                    guard w.conversations.indices.contains(i) else { throw E("no tab \(i)") }
                    return w.conversations[i]
                }
                guard let c = w.selected else { throw E("no tab") }
                return c
            }
            switch action {
            case "new": w.newConversation()
            case "select": w.select(try target())
            case "close": w.close(try target())
            case "rename":
                let c = try target()
                c.customTitle = cmd["name"] as? String
                w.renamed()
            case "attention":
                // Mark a tab as finished-unseen (checks the dot).
                try target().attention = cmd["on"] as? Bool ?? true
            default: throw E("unknown action \(action)")
            }
            return state()
        }

        // {"cmd":"terminal","action":"toggle"} · show|hide|new|select|close|focus with "index".
        DebugControl.register("terminal") { cmd in
            guard let w = store.active else { throw E("no active workspace") }
            let action = cmd["action"] as? String ?? "toggle"
            @MainActor func target() throws -> TerminalSession {
                if let i = cmd["index"] as? Int {
                    guard w.terminals.indices.contains(i) else { throw E("no terminal \(i)") }
                    return w.terminals[i]
                }
                guard let t = w.selectedTerminal else { throw E("no terminal") }
                return t
            }
            let wc = AppDelegate.shared.windowController
            switch action {
            case "toggle": wc?.toggleTerminal(nil)
            case "show": w.showTerminal()
            case "hide": w.hideTerminal()
            case "new": wc?.newTerminal(nil)
            case "select": w.selectTerminal(try target().id)
            case "close": w.closeTerminal(try target().id)
            case "focus": wc?.focusTerminal()
            case "drag":
                // Move the terminal divider like a drag would (a synthesized
                // drag would block in NSSplitView's tracking loop).
                guard let split = wc?.split else { break }
                let width = CGFloat(cmd["width"] as? Int ?? 400)
                split.splitView.setPosition(split.splitView.bounds.width - width, ofDividerAt: 1)
            case "width":
                store.rightColumnWidth = CGFloat(cmd["width"] as? Double ?? Double(cmd["width"] as? Int ?? 400))
            default: throw E("unknown action \(action)")
            }
            return state()
        }

        DebugControl.register("sidebar") { cmd in
            store.sidebarVisible = cmd["visible"] as? Bool ?? !store.sidebarVisible
            return state()
        }

        DebugControl.register("open") { cmd in
            guard let path = cmd["path"] as? String else { throw E("path=") }
            AppDelegate.shared.application(NSApp, open: [URL(fileURLWithPath: path)])
            return state()
        }

        DebugControl.register("toastAlwaysShow") { cmd in
            ActivityToastView.alwaysShow = cmd["on"] as? Bool ?? true
            return nil
        }
        // Show a toast about tab `index` of workspace `workspace`.
        DebugControl.register("toast") { cmd in
            let wi = cmd["workspace"] as? Int ?? 0, ti = cmd["index"] as? Int ?? 0
            guard store.workspaces.indices.contains(wi), store.workspaces[wi].conversations.indices.contains(ti) else { throw E("no such tab") }
            Activity.shared.present(source: store.workspaces[wi].conversations[ti], title: cmd["title"] as? String ?? "Test", body: cmd["body"] as? String ?? "",
                                    stopped: cmd["stopped"] as? Bool ?? false)
            return state()
        }
        // A fake pending request on tab `index` of workspace `workspace`:
        // {"cmd":"fakeRequest","tool":"Bash","title":"…"}; no "tool" clears it.
        // {"cmd":"notices"} lists the sidebar's notifications.
        DebugControl.register("fakeRequest") { cmd in
            let wi = cmd["workspace"] as? Int ?? 0, ti = cmd["index"] as? Int ?? 0
            guard store.workspaces.indices.contains(wi), store.workspaces[wi].conversations.indices.contains(ti) else { throw E("no such tab") }
            var input: [String: Any] = [:]
            if let q = cmd["question"] as? String { input["questions"] = [["question": q]] }
            store.workspaces[wi].conversations[ti].debugSetRequest(toolName: cmd["tool"] as? String, input: input,
                                                                   title: cmd["title"] as? String)
            return nil
        }
        DebugControl.register("notices") { _ in
            Activity.shared.notices.map { ["kind": "\($0.kind)", "text": $0.text, "tab": $0.conversation.title] }
        }
        // The window's sheet (alert): {"cmd":"sheet"} describes it,
        // {"cmd":"sheet","press":"Cancel"} presses a button.
        DebugControl.register("sheet") { cmd in
            guard let sheet = DebugControl.window?.attachedSheet else { return "none" }
            @MainActor func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
            @MainActor func texts(_ v: NSView) -> [String] {
                ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
            }
            let all = sheet.contentView.map(buttons) ?? []
            if let title = cmd["press"] as? String {
                guard let b = all.first(where: { $0.title == title }) else { throw E("no button \(title)") }
                b.performClick(nil)
                return "pressed \(title)"
            }
            return ["buttons": all.map(\.title), "text": sheet.contentView.map(texts) ?? []]
        }
        // {"cmd":"mostty"} lists what would be imported; {"cmd":"mostty","show":true}
        // opens the sheet; {"cmd":"mostty","perform":true} imports the defaults.
        DebugControl.register("mostty") { cmd in
            if cmd["show"] as? Bool == true { MosttyImport.present(store: store); return nil }
            if let press = cmd["press"] as? String {
                MosttyImport.finishSheet(perform: press == "Import", store: store)
                return state()
            }
            let model = MosttyImport()
            model.load(store: store)
            if cmd["perform"] as? Bool == true {
                // Loading is asynchronous: import once it's done.
                Task { @MainActor in
                    while model.loading { try? await Task.sleep(for: .milliseconds(100)) }
                    model.perform(store: store)
                }
                return "importing"
            }
            return MosttyImport.mosttyWorkspaces().map { w in
                ["name": w.name, "folder": w.folder,
                 "sessions": MosttyImport.recentSessions(in: w.folder, limit: 8).map { "\($0.title) · \($0.date)" }]
            }
        }

        DebugControl.register("jump") { _ in
            Activity.shared.jumpToLatest()
            return state()
        }

        DebugControl.register("save") { _ in
            store.save()
            return WorkspaceStore.stateURL.path
        }
    }

    static func state() -> [String: Any] {
        let wc = AppDelegate.shared.windowController
        return [
            "active": store.workspaces.firstIndex { $0.id == store.activeID } ?? -1,
            "sidebarVisible": store.sidebarVisible,
            "renaming": store.renamingID.flatMap { id in store.workspaces.firstIndex { $0.id == id } } ?? -1,
            "windowTitle": wc?.window?.title ?? "",
            "windowFrame": wc?.window.map { NSStringFromRect($0.frame) } ?? "",
            "firstResponder": wc?.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "terminalColumnWidth": wc?.layout.terminalWidth ?? 0,
            "dockBadge": NSApp.dockTile.badgeLabel ?? "",
            "keepingAwake": Activity.shared.keepingAwake,
            "toast": Activity.shared.toast.map { "\($0.title) | \($0.body) | \($0.location)" } ?? "",
            "workspaces": store.workspaces.map { w -> [String: Any] in
                [
                    "name": w.name,
                    "folder": w.folder,
                    "tabs": w.conversations.map(\.title),
                    "selected": w.conversations.firstIndex { $0.id == w.selectedID } ?? -1,
                    "terminals": w.terminals.map { "\($0.displayTitle)\($0.isStarted ? "" : " (not started)")" },
                    "selectedTerminal": w.terminals.firstIndex { $0.id == w.selectedTerminalID } ?? -1,
                    "terminalVisible": w.terminalVisible,
                    "rightColumnWidth": store.rightColumnWidth,
                ]
            },
        ]
    }
}
#endif
