import AppKit

/// The preview's tools for Claude: an MCP server named `preview`, given to
/// conversations that start while the preview is turned on (and to none
/// otherwise). The bridge relays each call here and the answer back.
///
/// This is the one place Toasty adds tools to Claude Code (BUILD_PLAN §1):
/// they only drive the workspace's browser, and the setting removes them
/// entirely. They work whether the browser window is open or not, and never
/// open it, bring it forward or take the keyboard: the user shows it when
/// they want to watch (the titlebar's indicator says when Claude is in it).
@MainActor
enum PreviewTools {
    static let serverName = "preview"

    /// The `mcpServers` a conversation starts with: the preview's, or none.
    static func servers() -> [[String: Any]] {
        guard PreviewSettings.shared.enabled else { return [] }
        return [["name": serverName, "instructions": instructions, "tools": tools]]
    }

    private static let instructions = """
        The preview is a browser in Toasty, the app this conversation runs in, for the site the user is developing. \
        Use it for local dev servers: it leaves the user's own browser alone. \
        Each workspace has its own, with its own cookies and storage; this conversation's is its workspace's. \
        It runs in the background: the user's browser window, which shows the workspace they have selected, may be hidden or showing another workspace, and using the browser never shows it or interrupts the user. \
        When they look at this workspace's browser they see the same page you are using, and can use it too. \
        It shows a page at one of three sizes: mobile (an iPhone, 402×874), mobile-max (an iPhone Pro Max, 440×956), both with an iPhone user agent, or desktop (1280 wide); every result says which. \
        It is WebKit (Safari's engine), not Chromium. \
        The user can comment on things in the page: a comment arrives in their message with a CSS selector, the viewport and a screenshot with the thing outlined.
        """

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:],
                             required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "openWorldHint": false]]
    }

    private static let tools: [[String: Any]] = [
        tool("navigate", "Open a URL in the preview and wait for it to load. `localhost:3000` or just a port (`3000`) works.",
             ["url": ["type": "string", "description": "The address to open."]], required: ["url"]),
        tool("screenshot", "A picture of what the preview shows now, at the current viewport.", readOnly: true),
        tool("read_console", "The page's console since it loaded: logs, warnings, uncaught errors, failed requests and resources that didn't load.",
             ["clear": ["type": "boolean", "description": "Empty the console after reading it."]], readOnly: true),
        tool("set_viewport", "Show the page as an iPhone (mobile, 402×874), an iPhone Pro Max (mobile-max, 440×956), both with an iPhone user agent, or a desktop (1280 wide). The page reloads.",
             ["viewport": ["type": "string", "enum": PreviewViewport.allCases.map(\.rawValue)]], required: ["viewport"]),
        tool("evaluate", "Run JavaScript in the page and get its result. The code is the body of an async function: use `return` to send a value back, and `await` freely.",
             ["javascript": ["type": "string"]], required: ["javascript"]),
        tool("click", "Click the first element matching a CSS selector.",
             ["selector": ["type": "string"]], required: ["selector"]),
        tool("type", "Replace the text of the field matching a CSS selector (input, textarea, select or contenteditable).",
             ["selector": ["type": "string"], "text": ["type": "string"],
              "press_enter": ["type": "boolean", "description": "Press Return afterwards (submits the field's form)."]],
             required: ["selector", "text"]),
    ]

    // MARK: Calls

    /// A tool call from the conversation's Claude, relayed by the bridge.
    /// `reply` gets the MCP result.
    static func handle(_ call: [String: Any], from conversation: ClaudeConversation, reply: @escaping ([String: Any]) -> Void) {
        guard call["server"] as? String == serverName else {
            reply(error("Unknown server."))
            return
        }
        guard PreviewSettings.shared.enabled else {
            reply(error("The preview is turned off in Toasty's Settings."))
            return
        }
        guard let workspace = conversation.workspace else {
            reply(error("This conversation has no workspace."))
            return
        }
        let session = PreviewStore.shared.session(for: workspace)
        let input = call["input"] as? [String: Any] ?? [:]
        let name = call["tool"] as? String ?? ""
        session.agentBegan(from: conversation.id)
        Task {
            await session.readyForAgent()
            do {
                reply(try await run(name, input, session: session))
            } catch {
                reply(self.error(error.localizedDescription))
            }
            session.agentEnded()
        }
    }

    private static func run(_ name: String, _ input: [String: Any], session: PreviewSession) async throws -> [String: Any] {
        func string(_ key: String) throws -> String {
            guard let s = input[key] as? String, !s.isEmpty else { throw PreviewError("`\(key)` is required.") }
            return s
        }
        switch name {
        case "navigate":
            let target = try string("url")
            if let problem = await session.navigate(target) {
                return error("Couldn't open \(target): \(problem)\n\(status(session))")
            }
            return text("Loaded.\n\(status(session))")

        case "screenshot":
            try loaded(session)
            let picture = try await session.snapshot()
            // PNG keeps text sharp; a page full of photos is smaller as JPEG.
            var data = picture.representation(using: .png, properties: [:])
            var type = "image/png"
            if (data?.count ?? 0) > 1_500_000, let jpeg = picture.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                data = jpeg
                type = "image/jpeg"
            }
            guard let data else { throw PreviewError("Couldn't take a picture of the page.") }
            return ["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": type],
                                ["type": "text", "text": status(session)]]]

        case "read_console":
            let entries = session.console
            if input["clear"] as? Bool == true { session.clearConsole() }
            let lines = entries.map { "[\($0.level)] \($0.text)" }.joined(separator: "\n")
            return text((entries.isEmpty ? "The console is empty." : lines) + "\n\n\(status(session, console: false))")

        case "set_viewport":
            guard let viewport = PreviewViewport(rawValue: try string("viewport")) else {
                throw PreviewError("`viewport` is mobile, mobile-max or desktop.")
            }
            let changes = viewport != session.viewport
            session.setViewport(viewport)
            // The page reloads (when it has one) and is laid out at its new
            // size: the result says that size, not the old one.
            if changes { await settle(session) }
            return text(status(session))

        case "evaluate":
            try loaded(session)
            let value = try await session.run(try string("javascript"))
            return text("\(describe(value))\n\n\(status(session))")

        case "click":
            try loaded(session)
            let selector = try string("selector")
            let tag = try await session.run(PreviewScripts.click, arguments: ["selector": selector])
            await settle(session)
            return text("Clicked <\(tag as? String ?? "element")>.\n\(status(session))")

        case "type":
            try loaded(session)
            let selector = try string("selector")
            guard let value = input["text"] as? String else { throw PreviewError("`text` is required.") }
            let enter = input["press_enter"] as? Bool ?? false
            let tag = try await session.run(PreviewScripts.type, arguments: ["selector": selector, "text": value, "enter": enter])
            if enter { await settle(session) }
            return text("Typed into <\(tag as? String ?? "element")>.\n\(status(session))")

        default:
            throw PreviewError("The preview has no tool named \(name).")
        }
    }

    private static func loaded(_ session: PreviewSession) throws {
        if session.url == nil { throw PreviewError("The preview has no page open. Use navigate first.") }
        if let failure = session.failure { throw PreviewError("The preview couldn't open \(failure.address): \(failure.reason)") }
    }

    /// Give a click, a submit or a reload a moment to show its effect, and a
    /// navigation it started time to finish.
    private static func settle(_ session: PreviewSession) async {
        try? await Task.sleep(for: .milliseconds(300))
        var waited = 0
        while session.isLoading, waited < 50 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
    }

    /// Said with every result: where the preview is and which layout it's in.
    private static func status(_ session: PreviewSession, console: Bool = true) -> String {
        var lines = ["URL: \(session.url?.absoluteString ?? "none")", "Viewport: \(session.viewportDescription)"]
        if console {
            let errors = session.console.filter { $0.level == "error" }.count
            if errors > 0 { lines.append("Console: \(errors) error\(errors == 1 ? "" : "s") (read_console shows them)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "undefined" }
        if let s = value as? String { return String(s.prefix(20_000)) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(String(decoding: data, as: UTF8.self).prefix(20_000))
        }
        return String("\(value)".prefix(20_000))
    }

    private static func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }
    private static func error(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": true] }
}
