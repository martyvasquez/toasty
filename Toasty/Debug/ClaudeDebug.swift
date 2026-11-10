#if DEBUG
import AppKit

/// Debug commands for the selected conversation of the active workspace.
/// Responses mirror exactly what the request card's buttons send.
enum ClaudeDebug {
    typealias E = DebugControl.DebugError

    static var conversation: ClaudeConversation? { WorkspaceStore.shared.active?.selected }

    static func install() {
        ClaudeSetup.installDebug()
        func conv() throws -> ClaudeConversation {
            guard let c = conversation else { throw E("no conversation") }
            return c
        }
        func request() throws -> (ClaudeConversation, ClaudePermissionRequest) {
            let c = try conv()
            guard let r = c.requests.first else { throw E("no pending request") }
            return (c, r)
        }

        // Append to the composer's draft: {"cmd":"type","text":"hi"}
        DebugControl.register("type") { cmd in
            try conv().draft += (cmd["text"] as? String ?? "").replacingOccurrences(of: "\\n", with: "\n")
            return nil
        }
        // Show a prompt suggestion (ghost text): {"cmd":"suggest","text":"…"}
        DebugControl.register("suggest") { cmd in
            try conv().debugSuggest(cmd["text"] as? String)
            return nil
        }
        DebugControl.register("submit") { _ in try conv().submit(); return nil }
        DebugControl.register("interrupt") { _ in try conv().interrupt(); return nil }
        DebugControl.register("mode") { cmd in
            try conv().setPermissionMode(cmd["mode"] as? String ?? "default")
            return nil
        }
        DebugControl.register("model") { cmd in
            guard let m = cmd["model"] as? String else { throw E("model=") }
            try conv().setModel(m)
            return nil
        }

        // {"cmd":"allow"} · {"cmd":"allow","always":true}
        DebugControl.register("allow") { cmd in
            let (c, r) = try request()
            var response: [String: Any] = ["behavior": "allow", "updatedInput": r.input]
            if cmd["always"] as? Bool == true { response["updatedPermissions"] = r.suggestions }
            c.respond(to: r, response)
            return nil
        }
        // {"cmd":"deny"} (Esc) · {"cmd":"deny","feedback":"do X instead"}
        DebugControl.register("deny") { cmd in
            let (c, r) = try request()
            if let feedback = cmd["feedback"] as? String {
                c.respond(to: r, ["behavior": "deny", "message": feedback, "interrupt": false])
            } else {
                c.respond(to: r, ["behavior": "deny", "message": "The user rejected this.", "interrupt": true])
            }
            return nil
        }
        // AskUserQuestion: {"cmd":"answer","index":0} answers every question
        // with that option; "labels":"A, B" answers the first question.
        DebugControl.register("answer") { cmd in
            let (c, r) = try request()
            var input = r.input
            var answers: [String: String] = [:]
            for q in input["questions"] as? [[String: Any]] ?? [] {
                let question = q["question"] as? String ?? ""
                let opts = q["options"] as? [[String: Any]] ?? []
                if let labels = cmd["labels"] as? String {
                    answers[question] = labels
                } else {
                    let i = cmd["index"] as? Int ?? 0
                    answers[question] = opts.indices.contains(i) ? opts[i]["label"] as? String ?? "" : ""
                }
            }
            input["answers"] = answers
            c.respond(to: r, ["behavior": "allow", "updatedInput": input])
            return nil
        }
        // ExitPlanMode: {"cmd":"approvePlan","mode":"acceptEdits"}
        DebugControl.register("approvePlan") { cmd in
            let (c, r) = try request()
            let mode = cmd["mode"] as? String ?? "default"
            c.respond(to: r, ["behavior": "allow", "updatedInput": r.input,
                              "updatedPermissions": [["type": "setMode", "mode": mode, "destination": "session"]]])
            c.noteModeChange(mode)
            return nil
        }

        // Show a Markdown file as if Claude had replied with it.
        DebugControl.register("render") { cmd in
            guard let path = cmd["path"] as? String,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw E("path=") }
            try conv().debugAppendReply(text)
            return nil
        }

        // A long synthetic session: {"cmd":"longSession","turns":600} (3 rows per turn).
        // {"turns":60,"workspace":1}: into that workspace's selected tab.
        DebugControl.register("longSession") { cmd in
            let c: ClaudeConversation
            if let i = cmd["workspace"] as? Int {
                guard WorkspaceStore.shared.workspaces.indices.contains(i),
                      let s = WorkspaceStore.shared.workspaces[i].selected else { throw E("no workspace \(i)") }
                c = s
            } else {
                c = try conv()
            }
            let start = Date()
            c.debugAppendLongSession(turns: cmd["turns"] as? Int ?? 600)
            return ["items": c.items.count, "appendSeconds": Date().timeIntervalSince(start)]
        }

        // {"cmd":"remote","enabled":true}
        DebugControl.register("remote") { cmd in
            try conv().setRemoteControl(cmd["enabled"] as? Bool ?? true)
            return nil
        }

        DebugControl.register("runInTerminal") { cmd in
            WorkspaceStore.shared.active?.runInTerminal(cmd["text"] as? String ?? "")
            return nil
        }

        // Scroll the transcript to a fraction (0 top … 1 bottom).
        DebugControl.register("scroll") { cmd in
            guard let root = DebugControl.window?.contentView else { throw E("no window") }
            @MainActor func scrollViews(_ v: NSView) -> [NSScrollView] {
                ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
            }
            let candidates = scrollViews(root).filter { !($0.superview is TerminalScrollView) && !($0.documentView is FlippedView) && !$0.isHiddenOrHasHiddenAncestor }
            guard let sv = candidates.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
                  let doc = sv.documentView else { throw E("no transcript") }
            // Respect the content insets (the transcript runs under the titlebar).
            let top = -sv.contentInsets.top
            let bottom = doc.frame.height - sv.contentSize.height + sv.contentInsets.bottom
            // No "to": report how far from the bottom the view is (points).
            guard cmd["to"] != nil else {
                let y = sv.contentView.bounds.origin.y
                return ["fromBottom": doc.isFlipped ? bottom - y : y - top, "height": doc.frame.height,
                        "lastUserScroll": -WheelWatcher.shared.lastScroll.timeIntervalSinceNow]
            }
            // {"user":true}: as if the user scrolled there by hand.
            if cmd["user"] as? Bool == true { WheelWatcher.shared.markUserScroll() }
            let f = cmd["to"] as? Double ?? Double(cmd["to"] as? Int ?? 1)
            let y = top + (bottom - top) * CGFloat(doc.isFlipped ? f : 1 - f)
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
            return NSStringFromRect(doc.frame)
        }

        // The Agent SDK in use and on disk: {"cmd":"sdk"}. Actions:
        // "refresh" (check npm now, even if `claude` didn't change),
        // "installBroken" (a fake newest SDK that can't load, to exercise the
        // fallback: open a new conversation tab next), "reset" (forget
        // downloads and bad marks).
        DebugControl.registerAsync("sdk") { cmd in
            let sdk = ClaudeSDK.shared
            switch cmd["action"] as? String {
            case "refresh":
                let env: ClaudeEnvironment.Resolved = try await withCheckedThrowingContinuation { k in
                    ClaudeEnvironment.resolve { k.resume(with: $0) }
                }
                sdk.refresh(environment: env, force: true)
            case "installBroken":
                try sdk.debugInstallBroken()
            case "reset":
                sdk.debugReset()
            case nil:
                break
            case let other?:
                throw E("unknown action \(other)")
            }
            let choice = sdk.choice()
            return [
                "choice": choice.version, "choicePath": choice.path ?? "bundled",
                "claude": sdk.claudeVersion ?? "",
                "bundled": ClaudeSDK.bundled?.version ?? "",
                "installed": sdk.installed.map { "\($0.version) (Claude Code \($0.claudeCode))" },
                "bad": Array(sdk.bad).sorted(),
                "summary": sdk.summary,
            ] as [String: Any]
        }

        // Fork the conversation at its last reply, like the reply's Fork button.
        DebugControl.register("fork") { _ in
            let c = try conv()
            guard let w = c.workspace else { throw E("no workspace") }
            guard let item = c.items.last(where: { $0.kind == .assistant && $0.entryUUID != nil }) else { throw E("no reply to fork at") }
            w.fork(c, at: item)
            return nil
        }

        // The conversation's state; poll it to wait for a turn.
        DebugControl.register("conv") { cmd in
            let c = try conv()
            let limit = cmd["items"] as? Int ?? 12
            return [
                "phase": "\(c.phase)",
                "session": c.sessionID ?? "",
                "model": c.model ?? "",
                "modelName": c.modelName ?? "",
                "models": c.models.map { "\($0.value) | \($0.name) | \($0.detail)" },
                "mode": c.permissionMode,
                "status": c.status ?? "",
                "title": c.title,
                "draft": c.draft,
                "attention": c.attention,
                "remoteControl": "\(c.remoteControl)",
                "turn": ["step": "\(c.activity.step)", "outputTokens": c.activity.outputTokens,
                             "elapsed": c.turnStarted.map { Date().timeIntervalSince($0) } ?? -1] as [String: Any],
                "remoteControlAvailable": c.remoteControlAvailable,
                "activity": Activity.shared.state(of: c).rawValue,
                "requests": c.requests.map { ["tool": $0.toolName, "title": $0.title ?? "", "suggestions": $0.suggestions.count] },
                "itemCount": c.items.count,
                "items": c.items.suffix(limit).map { item -> [String: Any] in
                    ["kind": "\(item.kind)", "text": String(item.text.prefix(240)), "tool": item.toolName,
                     "result": String((item.result ?? "").prefix(160)), "finalized": item.finalized,
                     "finishedAt": item.finishedAt.map { "\($0)" } ?? ""]
                },
            ] as [String: Any]
        }
    }
}
#endif
