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
            case "prompt":
                // Stand-in for a first prompt (titles the tab) until Phase 3.
                let c = try target()
                c.firstPrompt = cmd["text"] as? String
                w.renamed()
            case "status":
                // Fake a status to check the tab and sidebar indicators.
                let c = try target()
                switch cmd["status"] as? String ?? "idle" {
                case "working": c.phase = .working; c.requests = []; c.attention = false
                case "waiting": c.phase = .working; c.requests = ["permission"]; c.attention = false
                case "attention": c.phase = .idle; c.requests = []; c.attention = true
                default: c.phase = .idle; c.requests = []; c.attention = false
                }
                w.objectWillChange.send()
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
                w.terminalWidth = CGFloat(cmd["width"] as? Double ?? Double(cmd["width"] as? Int ?? 520))
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
            "workspaces": store.workspaces.map { w -> [String: Any] in
                [
                    "name": w.name,
                    "folder": w.folder,
                    "tabs": w.conversations.map(\.title),
                    "selected": w.conversations.firstIndex { $0.id == w.selectedID } ?? -1,
                    "terminals": w.terminals.map { "\($0.displayTitle)\($0.isStarted ? "" : " (not started)")" },
                    "selectedTerminal": w.terminals.firstIndex { $0.id == w.selectedTerminalID } ?? -1,
                    "terminalVisible": w.terminalVisible,
                    "terminalWidth": w.terminalWidth,
                ]
            },
        ]
    }
}
#endif
