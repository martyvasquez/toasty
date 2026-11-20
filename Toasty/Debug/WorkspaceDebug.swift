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
                // "toHeading": dragged onto a heading's row (an index into the headings).
                if let h = cmd["toHeading"] as? Int {
                    guard store.headings.indices.contains(h) else { throw E("toHeading=") }
                    store.move(try target().id, to: store.headings[h].id)
                    break
                }
                guard let to = cmd["to"] as? Int, store.workspaces.indices.contains(to) else { throw E("to=") }
                store.move(try target().id, to: store.workspaces[to].id)
            case "close": store.close(try target().id)
            case "heading":  // "heading": index into the headings, or -1 for none
                let h = cmd["heading"] as? Int ?? -1
                store.move(try target().id, toHeading: store.headings.indices.contains(h) ? store.headings[h].id : nil)
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

        // {"cmd":"heading","action":"new","above":2,"name":"Clients"} · rename|remove|move ("by") with "heading" (an index into the headings).
        DebugControl.register("heading") { cmd in
            let action = cmd["action"] as? String ?? "new"
            @MainActor func target() throws -> UUID {
                guard let i = cmd["heading"] as? Int, store.headings.indices.contains(i) else { throw E("heading=") }
                return store.headings[i].id
            }
            switch action {
            case "new":
                store.newHeading(above: (cmd["above"] as? Int).flatMap { store.workspaces.indices.contains($0) ? store.workspaces[$0].id : nil })
                if let name = cmd["name"] as? String, let id = store.renamingID {
                    store.setHeadingName(name, for: id)
                    store.renamingID = nil
                }
            case "rename":
                if let name = cmd["name"] as? String { store.setHeadingName(name, for: try target()) }
                else { store.renamingID = try target() }
            case "remove": store.removeHeading(try target())
            case "move": store.moveHeading(try target(), by: cmd["by"] as? Int ?? 1)
            default: throw E("unknown action \(action)")
            }
            return state()
        }

        // {"cmd":"worktree","action":"new","index":0,"branch":"x"} creates without
        // the prompt; "prompt" shows it; "remove" shows the removal sheet
        // (press it with "sheet"); "sync"; "files" lists what would be copied.
        DebugControl.registerAsync("worktree") { cmd in
            let action = cmd["action"] as? String ?? "sync"
            let i = cmd["index"] as? Int ?? (store.workspaces.firstIndex { $0.id == store.activeID } ?? 0)
            guard store.workspaces.indices.contains(i) else { throw E("no workspace \(i)") }
            let w = store.workspaces[i]
            switch action {
            case "new":
                guard let branch = cmd["branch"] as? String else { throw E("branch=") }
                let result = await withCheckedContinuation { c in
                    store.createWorktree(for: w, branch: branch) { c.resume(returning: $0) }
                }
                if case .failure(let error) = result { throw E(error.localizedDescription) }
            case "prompt": store.requestNewWorktree(for: w.id)
            case "remove": store.requestRemoveWorktree(w.id)
            case "sync":
                store.syncWorktrees()
                try? await Task.sleep(for: .milliseconds(800))
            case "files":
                let folder = w.folder
                return await Task.detached { Worktrees.list(in: folder)?.first.map { Worktrees.ignoredFilesToCopy(in: $0.path) } ?? [] }.value
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
            if cmd["checkRemote"] as? Bool == true { w.changes.checkRemote() }
            if let i = cmd["diff"] as? Int {
                w.diffFile = w.changes.files.indices.contains(i) ? w.changes.files[i] : nil
            }
            return [
                "inspector": w.inspectorVisible, "tab": w.inspectorTab.rawValue, "terminal": w.terminalVisible,
                "fraction": store.inspectorFraction,
                "columnWidth": AppDelegate.shared.windowController.map { $0.split.terminalItem.isCollapsed ? 0 : $0.split.rightColumn.view.frame.width } ?? -1,
                "inspectorHeight": AppDelegate.shared.windowController?.split.rightColumn.inspectorItem.viewController.view.frame.height ?? -1,
                "git": "\(w.changes.state)", "branch": w.changes.branch ?? "", "ahead": w.changes.ahead, "behind": w.changes.behind,
                "base": w.changes.base ?? "", "behindBase": w.changes.behindBase,
                "files": w.changes.files.map { "\($0.status.rawValue) \($0.path) +\($0.added.map(String.init) ?? "-") -\($0.removed.map(String.init) ?? "-")" },
                "diff": w.diffFile?.path ?? "",
            ] as [String: Any]
        }

        // {"cmd":"teeup","action":"add","text":"…","files":"/a.png,/b.pdf"} ·
        // send|delete|edit|move (with "to") by "index" · done · new · drop with "files" ·
        // feed · pause · resume · stop · feedState · hold with "index" and "on" · check with "mode".
        DebugControl.register("teeup") { cmd in
            guard let w = store.active else { throw E("no active workspace") }
            let action = cmd["action"] as? String ?? "list"
            @MainActor func target() throws -> TeeUp {
                guard let i = cmd["index"] as? Int, w.teeUps.indices.contains(i) else { throw E("index=") }
                return w.teeUps[i]
            }
            let files = (cmd["files"] as? String)?.split(separator: ",").map { URL(fileURLWithPath: String($0)) } ?? []
            switch action {
            case "list": break
            case "add":
                var item = TeeUp(text: cmd["text"] as? String ?? "")
                item.attach(files)
                w.addTeeUp(item)
            case "new": w.newTeeUp(with: files)
            case "drop": w.attachToTeeUp(files)
            case "feed": cmd["ask"] as? Bool == true ? w.requestTeeUpFeed() : w.startTeeUpFeed()
            case "pause": w.pauseTeeUpFeed()
            case "resume": w.resumeTeeUpFeed()
            case "stop": w.stopTeeUpFeed()
            case "check":
                guard let c = (cmd["mode"] as? String).flatMap(TeeUpSettings.QuestionCheck.init(rawValue:)) else { throw E("mode=off|anyQuestion|smallModel") }
                TeeUpSettings.shared.questionCheck = c
            case "hold": w.setTeeUpHeld(try target().id, cmd["on"] as? Bool ?? true)
            case "feedState":
                return ["feeding": w.teeUpFeed != nil, "tab": w.teeUpFeedTab?.title ?? "",
                        "countingDown": w.teeUpFeed?.nextAt != nil, "checking": w.teeUpFeed?.checking != nil,
                        "check": TeeUpSettings.shared.questionCheck.rawValue, "paused": w.teeUpFeed?.paused as Any? ?? NSNull(), "verdict": w.teeUpFeed?.verdict ?? "",
                        "left": w.teeUps.filter { !$0.isHeld }.count] as [String: Any]
            case "edit": w.editTeeUp(try target().id)
            case "done": w.endTeeUpEdit()
            case "send": if !w.sendTeeUp(try target().id) { throw E("no tab to send to") }
            case "delete": w.removeTeeUp(try target().id)
            case "move":
                guard let to = cmd["to"] as? Int else { throw E("to=") }
                w.moveTeeUp(try target().id, to: to)
            default: throw E("unknown action \(action)")
            }
            return w.teeUps.map { ["text": $0.text, "images": $0.images.count, "files": $0.files, "held": $0.isHeld] as [String: Any] }
        }

        // What Auto-Send would make of a reply: {"cmd":"teeupJudge","asked":"…","reply":"…"}
        DebugControl.registerAsync("teeupJudge") { cmd in
            let reply = cmd["reply"] as? String ?? ""
            guard TeeUpQuestion.mightAsk(reply) else { return "no question: goes on without asking" }
            let result = await withCheckedContinuation { c in
                ClaudeAgentProcess.ask(TeeUpQuestion.prompt(asked: cmd["asked"] as? String ?? "", reply: reply),
                                       system: TeeUpQuestion.system, cwd: store.active?.folder ?? NSHomeDirectory()) { c.resume(returning: $0) }
            }
            switch result {
            case .success(let text): return "\(TeeUpQuestion.verdict(text)) ← \(text)"
            case .failure(let error): return "failed: \(error.localizedDescription)"
            }
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
            case "move":
                guard let to = cmd["to"] as? Int else { throw E("to=") }
                w.moveConversation(try target().id, to: to)
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
            case "move":
                guard let to = cmd["to"] as? Int else { throw E("to=") }
                w.moveTerminal(try target().id, to: to)
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

        // Time switching workspaces: {"cmd":"perfSwitch","count":10}.
        // Each switch is timed from activate until the main queue runs
        // again (the SwiftUI update, layout and commit all happen first).
        DebugControl.registerAsync("perfSwitch") { cmd in
            let count = cmd["count"] as? Int ?? 10
            guard store.workspaces.count > 1 else { throw E("need 2+ workspaces") }
            var times: [Double] = []
            for _ in 0..<count {
                let start = CACurrentMediaTime()
                // {"a":0,"b":3}: back and forth between two workspaces.
                if let a = cmd["a"] as? Int, let b = cmd["b"] as? Int, store.workspaces.indices.contains(a),
                   store.workspaces.indices.contains(b) {
                    store.activate(store.workspaces[store.active?.id == store.workspaces[a].id ? b : a].id)
                } else {
                    store.activateRelative(1)
                }
                await nextTurn()
                times.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(50))
            }
            return Self.summary(times)
        }

        // Time typing in the composer (each keystroke changes the
        // conversation the transcript observes): {"cmd":"perfType","count":20}.
        DebugControl.registerAsync("perfType") { cmd in
            guard let c = store.active?.selected else { throw E("no conversation") }
            let saved = c.draft
            var times: [Double] = []
            for _ in 0..<(cmd["count"] as? Int ?? 20) {
                let start = CACurrentMediaTime()
                c.draft += "a"
                await nextTurn()
                times.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(20))
            }
            c.draft = saved
            return Self.summary(times)
        }

        // Scroll the transcript up by hand in steps and time each one:
        // {"cmd":"perfScroll","steps":60,"dy":3}. "jumps" counts steps where
        // the view didn't land where the wheel put it.
        DebugControl.registerAsync("perfScroll") { cmd in
            guard let window = DebugControl.window else { throw E("no window") }
            let steps = cmd["steps"] as? Int ?? 60, dy = Int32(cmd["dy"] as? Int ?? 3)
            let x = cmd["x"] as? Double ?? 500, y = cmd["y"] as? Double ?? 300
            @MainActor func transcript(_ v: NSView) -> [NSScrollView] {
                ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(transcript)
            }
            guard let sv = transcript(window.contentView!).filter({ !($0.superview is TerminalScrollView) && $0.documentView?.isFlipped == true && !$0.isHiddenOrHasHiddenAncestor })
                .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { throw E("no transcript") }
            var times: [Double] = []
            var deltas: [Int] = []
            for _ in 0..<steps {
                let before = sv.contentView.bounds.origin.y
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy * 10, wheel2: 0, wheel3: 0) else { break }
                let screen = window.convertPoint(toScreen: NSPoint(x: x, y: window.frame.height - y))
                cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                guard let e = NSEvent(cgEvent: cg) else { break }
                let start = CACurrentMediaTime()
                window.sendEvent(e)
                await nextTurn()
                times.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(16))
                deltas.append(Int((sv.contentView.bounds.origin.y - before).rounded()))
            }
            var r = Self.summary(times)
            // Every step should move the same distance; others are jumps.
            let typical = deltas.sorted()[deltas.count / 2]
            r["jumps"] = deltas.filter { abs($0 - typical) > 1 }.count
            r["deltas"] = deltas.map(String.init).joined(separator: " ")
            r["height"] = sv.documentView?.frame.height ?? 0
            return r
        }
    }

    @MainActor private static func nextTurn() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    private static func summary(_ ms: [Double]) -> [String: Any] {
        let s = ms.sorted()
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return ["count": s.count, "medianMs": r(s.isEmpty ? 0 : s[s.count / 2]),
                "maxMs": r(s.last ?? 0), "meanMs": r(s.reduce(0, +) / Double(max(1, s.count)))]
    }

    static func state() -> [String: Any] {
        let wc = AppDelegate.shared.windowController
        return [
            "active": store.workspaces.firstIndex { $0.id == store.activeID } ?? -1,
            "sidebarVisible": store.sidebarVisible,
            "sidebarWidth": "\(Int(MainSplitViewController.sidebarWidth)) fixed, \(Int(AppDelegate.shared.windowController?.split.sidebarItem.viewController.view.frame.width ?? -1)) shown",
            "renaming": store.renamingID.flatMap { id in store.workspaces.firstIndex { $0.id == id } } ?? -1,
            "windowTitle": wc?.window?.title ?? "",
            "windowFrame": wc?.window.map { NSStringFromRect($0.frame) } ?? "",
            "firstResponder": wc?.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
            "terminalColumnWidth": wc?.layout.terminalWidth ?? 0,
            "dockBadge": NSApp.dockTile.badgeLabel ?? "",
            "keepingAwake": Activity.shared.keepingAwake,
            "pendingWorktrees": store.pendingWorktrees.map(\.name),
            "toast": Activity.shared.toast.map { "\($0.title) | \($0.body) | \($0.location)" } ?? "",
            "sidebar": store.items.map { item -> String in
                switch item {
                case .heading(let id): "# " + (store.headings.first { $0.id == id }?.name ?? "?")
                case .workspace(let id): store.workspaces.first { $0.id == id }?.name ?? "?"
                }
            },
            "workspaces": store.workspaces.map { w -> [String: Any] in
                [
                    "name": w.name,
                    "folder": w.folder,
                    "parent": w.parent?.name ?? "",
                    "copied": w.copiedFiles,
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
