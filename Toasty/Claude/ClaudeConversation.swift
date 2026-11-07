import AppKit
import Combine
import SwiftUI

/// One item in a conversation's transcript.
@MainActor
final class ClaudeItem: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case user
        case assistant
        case thinking
        case tool
        case notice
        case error
    }

    let id: String
    let kind: Kind
    /// Markdown (assistant, thinking, notice) or plain text (user, error).
    @Published var text: String
    /// Images attached to a user prompt.
    var images: [NSImage] = []
    /// "37s · 4:41 PM" under the last reply of a turn.
    @Published var footer: String?

    /// The API message this came from, while it is streaming.
    var messageID: String?
    /// False while text is still streaming in.
    @Published var finalized: Bool

    // Tool calls
    var toolName: String = ""
    @Published var input: [String: Any] = [:]
    @Published var result: String?
    @Published var resultIsError = false
    /// Structured result from Claude Code (e.g. an Edit's patch), if any.
    var toolUseResult: Any?
    @Published var elapsed: Double?
    /// Tool calls made by a subagent this tool started (Task / Agent).
    @Published var children: [ClaudeItem] = []

    init(id: String = UUID().uuidString, kind: Kind, text: String = "", finalized: Bool = true) {
        self.id = id
        self.kind = kind
        self.text = text
        self.finalized = finalized
    }

    static func tool(id: String, name: String, input: [String: Any], finalized: Bool) -> ClaudeItem {
        let item = ClaudeItem(id: id, kind: .tool, finalized: finalized)
        item.toolName = name
        item.input = input
        return item
    }
}

/// A permission prompt (or question) Claude Code is waiting on. It
/// came through the SDK's `canUseTool` callback, exactly where the CLI would
/// have shown its own prompt.
struct ClaudePermissionRequest: Identifiable {
    let id: String
    let toolName: String
    let input: [String: Any]
    let toolUseID: String?
    /// Permission rule updates Claude Code suggests ("don't ask again …").
    let suggestions: [[String: Any]]
    let decisionReason: String?
    let blockedPath: String?
    let title: String?
    let description: String?
}

/// A Claude Code conversation (one tab): the transcript, the agent
/// process, and pending prompts. It renders what Claude Code reports and
/// forwards what the user types or decides; it never steers the agent.
@MainActor
final class ClaudeConversation: ObservableObject, Identifiable {
    let id: UUID
    weak var workspace: Workspace?

    /// Something finished or needs the user while they weren't looking at
    /// this tab (a dot on the tab; cleared when it's shown).
    @Published var attention = false {
        didSet { if attention != oldValue { Activity.shared.attentionChanged() } }
    }

    var isSelected: Bool { workspace?.selected === self }

    /// A name the user gave the tab, if any.
    @Published var customTitle: String? {
        didSet { if customTitle != oldValue { stateDidChange() } }
    }

    /// The tab's title: its name, else the conversation's first prompt.
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        guard let first = items.first(where: { $0.kind == .user })?.text else { return "New Chat" }
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 40 ? String(t.prefix(39)) + "…" : t
    }

    enum Phase: Equatable {
        /// No turn running (the agent may or may not be started yet).
        case idle
        /// The agent process is starting.
        case starting
        /// Claude is working on a turn.
        case working
    }

    @Published private(set) var items: [ClaudeItem] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var requests: [ClaudePermissionRequest] = []
    @Published private(set) var sessionID: String?
    @Published private(set) var model: String?
    @Published private(set) var permissionMode: String = "default"
    @Published private(set) var status: String?
    @Published private(set) var slashCommands: [String] = []
    @Published private(set) var turnStarted: Date?
    @Published var draft: String = ""

    struct ModelOption: Identifiable, Equatable {
        let value: String
        let name: String
        let detail: String
        var id: String { value }
    }

    /// Remote Control (claude.ai and the Claude app), as /remote-control in
    /// the CLI: this session can be continued from another device.
    enum RemoteControl: Equatable {
        case off
        case connecting
        case on(url: String?)
        case failed(String)

        var isOn: Bool { if case .on = self { return true } else { return false } }
    }

    @Published private(set) var remoteControl: RemoteControl = .off
    /// False when Claude Code says Remote Control can never work here
    /// (e.g. org policy or a third-party API provider).
    @Published private(set) var remoteControlAvailable = true

    /// Turn Remote Control on or off for this session.
    func setRemoteControl(_ enabled: Bool) {
        remoteControlUserChoice = enabled
        remoteControl = enabled ? .connecting : .off
        if let agent, agent.isRunning, !launching {
            agent.send(["type": "remote_control", "enabled": enabled])
        } else if enabled {
            // Starting the session enables it (see remote_control_init).
            start()
        }
    }

    /// What the user last chose for this tab; it outlives agent restarts
    /// (otherwise the user's remoteControlAtStartup setting decides).
    private var remoteControlUserChoice: Bool?

    /// Models Claude Code offers (its own list, as in /model).
    @Published private(set) var models: [ModelOption] = []
    /// The project's current git branch, if it's a repository.
    @Published private(set) var branch: String?
    @Published var attachments: [NSImage] = []
    /// Bumped to move keyboard focus to the composer.
    @Published var composerFocusToken = 0

    let cwd: String

    private var agent: ClaudeAgentProcess?
    private var queued: [[String: Any]] = []
    private var interrupted = false
    private var turnsInFlight = 0
    private var lastAssistantText = ""
    /// Tool items by tool_use id (top level and subagents).
    private var tools: [String: ClaudeItem] = [:]
    /// Streaming content blocks of the current API message, by index.
    private var streaming: [Int: ClaudeItem] = [:]
    private var streamingMessageID: String?
    private var toolInputJSON: [Int: String] = [:]

    init(id: UUID = UUID(), cwd: String, sessionID: String? = nil, customTitle: String? = nil) {
        self.id = id
        self.cwd = cwd
        self.sessionID = sessionID
        self.customTitle = customTitle
        // Until Claude Code reports its mode (first turn), show the default
        // it will start in: `permissions.defaultMode` from the settings files.
        if let mode = Self.configuredDefaultMode(cwd: cwd) {
            permissionMode = mode
            if mode == "auto" { autoModeAvailable = true }
        }
        if let sessionID { loadHistory(sessionID) }
        refreshBranch()
    }

    /// Reads the branch from `.git/HEAD` (no git process needed).
    func refreshBranch() {
        var dir = URL(fileURLWithPath: cwd)
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var head = git.appendingPathComponent("HEAD")
            // Worktrees: .git is a file pointing at the real git dir.
            if let pointer = try? String(contentsOf: git, encoding: .utf8), pointer.hasPrefix("gitdir:") {
                let path = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                head = URL(fileURLWithPath: path, relativeTo: dir).appendingPathComponent("HEAD")
            }
            if let text = try? String(contentsOf: head, encoding: .utf8) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
                if b != branch { branch = b }
                return
            }
            dir.deleteLastPathComponent()
        }
        if branch != nil { branch = nil }
    }

    /// A readable name for the current model ("Opus 5.5").
    var modelName: String? {
        guard let model else {
            // Before the first turn: Claude Code's default, as /model shows it.
            // Claude Code's default entry names its model first
            // ("Opus 5.5 · Best for everyday, complex tasks").
            return models.first { $0.value == "default" }.map { m in
                m.detail.components(separatedBy: " · ").first.flatMap { $0.isEmpty ? nil : $0 } ?? "Default Model"
            }
        }
        if let m = models.first(where: { $0.value == model }) { return m.name }
        return Self.prettyModel(model)
    }

    static func prettyModel(_ id: String) -> String {
        var parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        // Drop a trailing date stamp (e.g. 20251001).
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        let extra = parts.dropFirst().filter { Int($0) == nil }.joined(separator: " ")
        return [family.capitalized, version, extra].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func setModel(_ value: String) {
        model = value
        send(["type": "set_model", "model": value])
    }

    var projectName: String { (cwd as NSString).lastPathComponent }

    var isBusy: Bool { phase != .idle || !requests.isEmpty }

    // MARK: User actions

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let images = attachments
        draft = ""
        attachments = []

        let item = ClaudeItem(kind: .user, text: text)
        item.images = images
        items.append(item)

        var message: [String: Any] = ["type": "user", "text": text]
        if !images.isEmpty {
            message["images"] = images.compactMap { image -> [String: String]? in
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return nil }
                return ["media_type": "image/png", "data": png.base64EncodedString()]
            }
        }
        if turnsInFlight == 0 {
            interrupted = false
            turnStarted = Date()
        }
        // A message sent while Claude works is queued by Claude Code and
        // runs as its own turn, with its own result.
        turnsInFlight += 1
        setPhase(.working)
        send(message)
    }

    /// Stop the current turn, like Esc in the CLI.
    func interrupt() {
        guard phase == .working || !requests.isEmpty else { return }
        interrupted = true
        // Pending prompts are cancelled by the interrupt itself.
        requests.removeAll()
        agent?.send(["type": "interrupt"])
    }

    func respond(to request: ClaudePermissionRequest, _ response: [String: Any]) {
        requests.removeAll { $0.id == request.id }
        // Denying with an interrupt (Esc) ends the turn like the CLI's Esc:
        // "Interrupted · What should Claude do instead?", no error.
        if response["behavior"] as? String == "deny", response["interrupt"] as? Bool == true {
            interrupted = true
        }
        agent?.send(["type": "permission_response", "id": request.id, "response": response])
        if phase == .working { reportState() }
    }

    func setPermissionMode(_ mode: String) {
        permissionMode = mode
        send(["type": "set_permission_mode", "mode": mode])
    }

    /// Auto mode was available when the session started (it's the user's
    /// configured default), so it is offered like the CLI does.
    @Published private(set) var autoModeAvailable = false

    /// The mode changed on Claude Code's side (e.g. after approving a plan).
    func noteModeChange(_ mode: String) { permissionMode = mode }

    /// Cycle permission modes like Shift-Tab in the CLI.
    func cyclePermissionMode() {
        let modes = ["default", "acceptEdits", "plan"] + (autoModeAvailable ? ["auto"] : [])
        let i = modes.firstIndex(of: permissionMode) ?? -1
        setPermissionMode(modes[(i + 1) % modes.count])
    }

    func focusComposer() { composerFocusToken += 1 }

    // MARK: Agent process

    private func send(_ message: [String: Any]) {
        if let agent, agent.isRunning, !launching {
            agent.send(message)
            return
        }
        queued.append(message)
        if !launching && !(agent?.isRunning ?? false) { startAgent() }
    }

    /// True from starting the agent until the bridge reports it's ready.
    private var launching = false

    private func startAgent() {
        launching = true
        if phase == .idle { setPhase(.starting) }
        ClaudeEnvironment.resolve { [weak self] result in
            guard let self else { return }
            @MainActor func fail(_ error: Error) {
                self.launching = false
                self.queued.removeAll()
                self.append(.error, error.localizedDescription)
                self.setPhase(.idle)
            }
            switch result {
            case .failure(let error):
                fail(error)
            case .success(let env):
                guard env.claude != nil else { fail(ClaudeAgentError.noClaude); return }
                let agent = ClaudeAgentProcess(
                    onMessage: { [weak self] in self?.handle($0) },
                    onExit: { [weak self] status, err in self?.agentExited(status, stderr: err) })
                var options: [String: Any] = ["cwd": self.cwd]
                if let id = self.sessionID { options["resume"] = id }
                do {
                    try agent.start(environment: env, options: options)
                    self.agent = agent
                } catch {
                    fail(error)
                }
            }
        }
    }

    /// Start the agent now (it otherwise starts with the first prompt).
    func start() {
        guard agent == nil, !launching else { return }
        startAgent()
    }

    func stop() {
        agent?.terminate()
        agent = nil
    }

    private func agentExited(_ status: Int32, stderr: String) {
        agent = nil
        remoteControl = .off
        turnsInFlight = 0
        launching = false
        queued.removeAll()
        requests.removeAll()
        if phase != .idle || status != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if status != 0 || phase == .working {
                append(.error, "Claude Code stopped unexpectedly\(status != 0 ? " (exit \(status))" : "").\(detail.isEmpty ? "" : "\n\n" + detail)")
            }
        }
        setPhase(.idle)
    }

    // MARK: Messages from the bridge

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            launching = false
            let pending = queued
            queued.removeAll()
            setPhase(pending.contains { $0["type"] as? String == "user" } ? .working : .idle)
            pending.forEach { agent?.send($0) }
        case "sdk":
            if let m = message["message"] as? [String: Any] {
                #if DEBUG
                Self.debugLog(m)
                #endif
                handleSDK(m)
            }
        case "permission_request":
            permissionRequest(message)
        case "models":
            models = (message["models"] as? [[String: Any]] ?? []).compactMap { m in
                guard let value = m["value"] as? String else { return nil }
                return ModelOption(value: value,
                                   name: m["displayName"] as? String ?? Self.prettyModel(value),
                                   detail: m["description"] as? String ?? "")
            }
        case "permission_cancel":
            // Answered elsewhere too (e.g. from Remote Control).
            requests.removeAll { $0.id == message["id"] as? String }
            reportState()
        case "remote_control_init":
            remoteControlAvailable = message["available"] as? Bool ?? true
            // Like the CLI: start Remote Control with the session when the
            // user's settings say so, unless they turned it off for this tab.
            if remoteControlAvailable,
               remoteControlUserChoice ?? (message["autoEnable"] as? Bool ?? false) {
                remoteControl = .connecting
                agent?.send(["type": "remote_control", "enabled": true])
            }
        case "remote_control":
            if let error = message["error"] as? String {
                remoteControl = .failed(error)
            } else if message["enabled"] as? Bool == true {
                remoteControl = .on(url: message["sessionURL"] as? String)
            } else {
                remoteControl = .off
            }
        case "error":
            append(.error, message["message"] as? String ?? "Unknown error")
            if message["fatal"] as? Bool == true { setPhase(.idle) }
        case "end":
            // The query finished (stdin closed or the session ended).
            setPhase(.idle)
        default:
            break
        }
    }

    #if DEBUG
    /// Non-streaming SDK messages, for inspecting what Claude Code sends
    /// (`$TMPDIR/toasty-sdk.log`).
    private static func debugLog(_ m: [String: Any]) {
        guard m["type"] as? String != "stream_event",
              let data = try? JSONSerialization.data(withJSONObject: m),
              let url = Optional(URL(fileURLWithPath: NSTemporaryDirectory() + "toasty-sdk.log")) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); h.write(Data("\n".utf8)); try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }
    #endif

    private func permissionRequest(_ m: [String: Any]) {
        guard let id = m["id"] as? String, let tool = m["toolName"] as? String else { return }
        let request = ClaudePermissionRequest(
            id: id,
            toolName: tool,
            input: m["input"] as? [String: Any] ?? [:],
            toolUseID: m["toolUseID"] as? String,
            suggestions: m["suggestions"] as? [[String: Any]] ?? [],
            decisionReason: m["decisionReason"] as? String,
            blockedPath: m["blockedPath"] as? String,
            title: m["title"] as? String,
            description: m["description"] as? String)
        requests.append(request)
        reportState()

        let what: String
        switch tool {
        case "AskUserQuestion": what = (request.input["questions"] as? [[String: Any]])?.first?["question"] as? String ?? "Claude has a question"
        case "ExitPlanMode": what = "Claude has a plan ready for review"
        default: what = request.title ?? "Claude needs your permission to use \(ClaudeToolInfo.displayName(tool))"
        }
        notify(title: "Claude Code needs you", body: what)
    }

    /// Handles one SDK message. Also used to replay a saved transcript, so it
    /// must not have side effects beyond the transcript when `live` is false.
    private func handleSDK(_ m: [String: Any], live: Bool = true) {
        let parent = m["parent_tool_use_id"] as? String

        // A turn Toasty didn't start (a prompt sent through Remote Control):
        // show it as working, like one typed here.
        if live, phase != .working, turnsInFlight == 0,
           ["stream_event", "assistant"].contains(m["type"] as? String ?? ""),
           (m["message"] as? [String: Any])?["model"] as? String != "<synthetic>" {
            interrupted = false
            turnStarted = Date()
            turnsInFlight = 1
            setPhase(.working)
        }

        switch m["type"] as? String {
        case "system":
            switch m["subtype"] as? String {
            case "init":
                if let id = m["session_id"] as? String, id != sessionID {
                    sessionID = id
                    stateDidChange()
                }
                model = m["model"] as? String
                if let mode = m["permissionMode"] as? String {
                    permissionMode = mode
                    if mode == "auto" { autoModeAvailable = true }
                }
                slashCommands = m["slash_commands"] as? [String] ?? []
            case "compact_boundary":
                append(.notice, "Conversation compacted")
            case "status":
                status = (m["status"] as? String) == "compacting" ? "Compacting conversation…" : nil
            case "local_command_output":
                if let text = m["content"] as? String, !text.isEmpty { append(.notice, text) }
            case "api_retry":
                let attempt = m["attempt"] as? Int
                status = "Retrying\(attempt.map { " (attempt \($0))" } ?? "")…"
            default:
                break
            }

        case "stream_event":
            guard live, parent == nil, let event = m["event"] as? [String: Any] else { return }
            streamEvent(event)

        case "assistant":
            guard let message = m["message"] as? [String: Any] else { return }
            // Claude Code's own placeholder replies (e.g. "No response
            // requested." after an interrupt); the CLI doesn't show them.
            if message["model"] as? String == "<synthetic>" { return }
            let messageID = message["id"] as? String
            let content = message["content"] as? [[String: Any]] ?? []
            if let parent {
                subagentContent(content, parent: parent)
                return
            }
            for block in content { assistantBlock(block, messageID: messageID) }
            if let error = m["error"] as? String, live {
                append(.error, ClaudeToolInfo.describeAssistantError(error))
            }

        case "user":
            guard let message = m["message"] as? [String: Any] else { return }
            let toolUseResult = m["tool_use_result"] ?? m["toolUseResult"]
            if let text = message["content"] as? String {
                if !live || m["isReplay"] as? Bool == true { userText(text) }
                return
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    guard let id = block["tool_use_id"] as? String, let item = tools[id] else { continue }
                    let text = Self.resultText(block["content"])
                    // Claude Code's rejection notice is addressed to Claude;
                    // show the user what happened instead (like the CLI).
                    item.result = text.hasPrefix("The user doesn't want to proceed with this tool use") ? "You rejected this." : text
                    item.resultIsError = block["is_error"] as? Bool ?? false
                    if parent == nil { item.toolUseResult = toolUseResult }
                    item.finalized = true
                case "text":
                    if parent == nil, !live || m["isReplay"] as? Bool == true, let t = block["text"] as? String {
                        userText(t)
                    }
                default:
                    break
                }
            }

        case "tool_progress":
            if let id = m["tool_use_id"] as? String { tools[id]?.elapsed = m["elapsed_time_seconds"] as? Double }

        case "result":
            guard live else { return }
            finishStreaming()
            status = nil
            let subtype = m["subtype"] as? String ?? ""
            let isError = m["is_error"] as? Bool ?? false
            if !interrupted, subtype != "success" || isError {
                let errors = (m["errors"] as? [String])?.joined(separator: "\n")
                let detail = (m["result"] as? String) ?? errors ?? subtype
                append(.error, detail.isEmpty ? "Claude Code stopped with an error." : detail)
            }
            let wasInterrupted = interrupted
            turnsInFlight = wasInterrupted ? 0 : max(0, turnsInFlight - 1)
            if turnsInFlight > 0 {
                // The next queued message is starting.
                turnStarted = Date()
                return
            }
            if let started = turnStarted, !wasInterrupted,
               let last = items.last(where: { $0.kind == .assistant }) {
                let secs = max(1, Int(Date().timeIntervalSince(started)))
                let time = Date().formatted(date: .omitted, time: .shortened)
                last.footer = "\(ClaudeToolInfo.duration(secs)) · \(time)"
            }
            refreshBranch()
            turnStarted = nil
            interrupted = false
            requests.removeAll()
            setPhase(.idle)
            if wasInterrupted {
                append(.notice, "Interrupted · What should Claude do instead?")
            } else if subtype == "success" && !isError {
                let summary = (m["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lastAssistantText
                notify(title: "Claude Code finished · \(projectName)",
                       body: String(summary.prefix(600)).isEmpty ? "Done" : String(summary.prefix(600)))
            } else {
                notify(title: "Claude Code stopped · \(projectName)", body: (m["result"] as? String) ?? subtype)
            }

        default:
            break
        }
    }

    private func streamEvent(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "message_start":
            finishStreaming()
            streamingMessageID = (e["message"] as? [String: Any])?["id"] as? String
        case "content_block_start":
            guard let index = e["index"] as? Int, let block = e["content_block"] as? [String: Any] else { return }
            switch block["type"] as? String {
            case "text":
                let item = ClaudeItem(kind: .assistant, finalized: false)
                item.messageID = streamingMessageID
                streaming[index] = item
                items.append(item)
            case "thinking":
                let item = ClaudeItem(kind: .thinking, finalized: false)
                item.messageID = streamingMessageID
                streaming[index] = item
                items.append(item)
            case "tool_use":
                guard let id = block["id"] as? String else { return }
                let item = ClaudeItem.tool(id: id, name: block["name"] as? String ?? "Tool", input: [:], finalized: false)
                item.messageID = streamingMessageID
                tools[id] = item
                streaming[index] = item
                toolInputJSON[index] = ""
                items.append(item)
            default:
                break
            }
        case "content_block_delta":
            guard let index = e["index"] as? Int, let delta = e["delta"] as? [String: Any],
                  let item = streaming[index] else { return }
            switch delta["type"] as? String {
            case "text_delta": item.text += delta["text"] as? String ?? ""
            case "thinking_delta": item.text += delta["thinking"] as? String ?? ""
            case "input_json_delta":
                toolInputJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
        case "message_stop":
            break
        default:
            break
        }
    }

    private func assistantBlock(_ block: [String: Any], messageID: String?) {
        switch block["type"] as? String {
        case "text":
            let text = block["text"] as? String ?? ""
            lastAssistantText = text
            if let item = streaming.values.first(where: { $0.kind == .assistant && !$0.finalized && $0.messageID == messageID }) {
                item.text = text
                item.finalized = true
            } else if !text.isEmpty {
                items.append(ClaudeItem(kind: .assistant, text: text))
            }
        case "thinking":
            let text = block["thinking"] as? String ?? ""
            if let item = streaming.values.first(where: { $0.kind == .thinking && !$0.finalized && $0.messageID == messageID }) {
                if !text.isEmpty { item.text = text }
                item.finalized = true
            } else if !text.isEmpty {
                items.append(ClaudeItem(kind: .thinking, text: text))
            }
        case "redacted_thinking":
            break
        case "tool_use":
            guard let id = block["id"] as? String else { return }
            let name = block["name"] as? String ?? "Tool"
            let input = block["input"] as? [String: Any] ?? [:]
            if let item = tools[id] {
                item.input = input
                if item.toolName.isEmpty { item.toolName = name }
            } else {
                let item = ClaudeItem.tool(id: id, name: name, input: input, finalized: false)
                tools[id] = item
                items.append(item)
            }
        default:
            break
        }
    }

    private func subagentContent(_ content: [[String: Any]], parent: String) {
        guard let parentItem = tools[parent] else { return }
        for block in content where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, tools[id] == nil else { continue }
            let item = ClaudeItem.tool(
                id: id, name: block["name"] as? String ?? "Tool",
                input: block["input"] as? [String: Any] ?? [:], finalized: false)
            tools[id] = item
            parentItem.children.append(item)
        }
    }

    private func finishStreaming() {
        for item in streaming.values where !item.finalized && item.kind != .tool {
            item.finalized = true
        }
        streaming.removeAll()
        toolInputJSON.removeAll()
    }

    private func userText(_ raw: String) {
        // Slash commands are saved as tagged text; show them as typed.
        if let name = Self.tag("command-name", in: raw) {
            let args = Self.tag("command-args", in: raw) ?? ""
            items.append(ClaudeItem(kind: .user, text: args.isEmpty ? name : "\(name) \(args)"))
            return
        }
        if let out = Self.tag("local-command-stdout", in: raw) {
            if !out.isEmpty { append(.notice, out) }
            return
        }
        if raw.hasPrefix("<") && (raw.contains("<system-reminder>") || raw.hasPrefix("<local-command") || raw.hasPrefix("<command-message>")) {
            return
        }
        if raw.hasPrefix("[Request interrupted by user") {
            append(.notice, "Interrupted")
            return
        }
        items.append(ClaudeItem(kind: .user, text: raw))
    }

    private func append(_ kind: ClaudeItem.Kind, _ text: String) {
        items.append(ClaudeItem(kind: kind, text: text))
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { b -> String? in
                switch b["type"] as? String {
                case "text": return b["text"] as? String
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: History

    /// Shows the saved conversation of a resumed session. Claude Code keeps
    /// it in `~/.claude/projects/<project>/<session>.jsonl`; its entries have
    /// the same shape as SDK messages.
    private func loadHistory(_ id: String) {
        guard let url = Activity.transcriptURL(for: id),
              let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        // Only the tail: long sessions would take a while to lay out.
        for line in lines.suffix(1500) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true { continue }
            if entry["isCompactSummary"] as? Bool == true { continue }
            switch entry["type"] as? String {
            case "user", "assistant":
                handleSDK(entry, live: false)
            case "system":
                if entry["subtype"] as? String == "compact_boundary" { append(.notice, "Conversation compacted") }
            default:
                break
            }
        }
        // Anything left unfinished (e.g. a tool call interrupted by quitting).
        for item in items where !item.finalized { item.finalized = true }
        if !items.isEmpty { append(.notice, "Resumed session") }
    }

    // MARK: State reporting (sidebar, tab, dock, sounds, keep awake)

    private func setPhase(_ p: Phase) {
        guard phase != p else { reportState(); return }
        phase = p
        reportState()
    }

    private var reportedState: String?

    /// Tell Toasty's activity hub (sidebar, dock badge, keep-awake, quit
    /// warnings) what Claude is doing in this conversation.
    func reportState() {
        let state = !requests.isEmpty ? "waiting" : (phase == .working ? "working" : "idle")
        guard state != reportedState || state == "working" else { return }
        reportedState = state
        Activity.shared.setAgentState(self, state)
    }

    private func notify(title: String, body rawBody: String) {
        // Plain text for banners and the sidebar: drop Markdown markers.
        let body = rawBody
            .replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[`*_]{1,3}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        Activity.shared.present(source: self, title: title, body: body)
    }

    private func stateDidChange() {
        workspace?.store?.setNeedsSave()
    }

    /// `permissions.defaultMode` as Claude Code resolves it: local, then
    /// project, then user settings. Display only; nothing is sent.
    nonisolated static func configuredDefaultMode(cwd: String) -> String? {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let files = [
            (cwd as NSString).appendingPathComponent(".claude/settings.local.json"),
            (cwd as NSString).appendingPathComponent(".claude/settings.json"),
            (configDir as NSString).appendingPathComponent("settings.json"),
        ]
        for f in files {
            guard let data = FileManager.default.contents(atPath: f),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mode = (json["permissions"] as? [String: Any])?["defaultMode"] as? String else { continue }
            return mode
        }
        return nil
    }

    // MARK: Restoration

    /// A conversation restored from state.json: resumes its session if
    /// Claude Code still has the transcript (loaded now, resumed lazily
    /// when the agent starts).
    convenience init(restoring id: UUID, cwd: String, sessionID: String?, customTitle: String?) {
        let resumable = sessionID.flatMap { Activity.transcriptURL(for: $0) != nil ? $0 : nil }
        self.init(id: id, cwd: cwd, sessionID: resumable, customTitle: customTitle)
    }
}

#if DEBUG
extension ClaudeConversation {
    /// Debug: show Markdown as if Claude had replied with it.
    func debugAppendReply(_ markdown: String) {
        items.append(ClaudeItem(kind: .assistant, text: markdown))
    }

    /// Debug: a long session (`turns` × prompt, tool call, reply) in one go.
    func debugAppendLongSession(turns: Int) {
        var new: [ClaudeItem] = []
        for i in 1...turns {
            new.append(ClaudeItem(kind: .user, text: "Question \(i): how does part \(i) of the pipeline work?"))
            let tool = ClaudeItem.tool(id: "debug-\(UUID().uuidString)", name: "Read",
                                       input: ["file_path": "\(cwd)/src/part\(i).swift"], finalized: true)
            tool.result = "// part \(i)"
            new.append(tool)
            new.append(ClaudeItem(kind: .assistant, text: """
            Part **\(i)** reads the input, validates it with `validate()`, and passes it on:

            - It checks the schema first.
            - Then it normalizes dates.

            ```swift
            func part\(i)(_ input: Input) throws -> Output { try validate(input).normalized() }
            ```
            """))
        }
        items.append(contentsOf: new)
    }
}
#endif
