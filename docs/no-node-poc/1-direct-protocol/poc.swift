// POC: drive Claude Code directly from Swift — no Node, no Agent SDK.
// Speaks the same stream-json control protocol the SDK speaks to `claude`.
//
//   swift poc.swift <cwd> [resume-session-id]
import Foundation

let cwd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let resume = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let t0 = Date()
func ms() -> String { String(format: "%6.0fms", Date().timeIntervalSince(t0) * 1000) }
func log(_ s: String) { print("\(ms())  \(s)"); fflush(stdout) }

// MARK: process (same argv the SDK uses)
let claude = "\(NSHomeDirectory())/.local/bin/claude"
var args = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
            "--permission-prompt-tool=stdio", "--tools=default", "--setting-sources=user,project,local",
            "--include-partial-messages", "--replay-user-messages"]
if let resume { args += ["--resume", resume] }

let p = Process()
p.executableURL = URL(fileURLWithPath: claude)
p.arguments = args
p.currentDirectoryURL = URL(fileURLWithPath: cwd)
// Like the app: no inherited Claude Code session variables.
var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "toasty"
env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts"
p.environment = env
let inPipe = Pipe(), outPipe = Pipe()
p.standardInput = inPipe; p.standardOutput = outPipe
p.standardError = FileHandle.standardError

func send(_ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj)
    inPipe.fileHandleForWriting.write(d + Data("\n".utf8))
}

// MARK: control requests (ours → claude) with awaited responses
final class Pending: @unchecked Sendable {
    var waiters: [String: CheckedContinuation<[String: Any], Never>] = [:]
    let lock = NSLock()
}
let pending = Pending()
func request(_ req: [String: Any]) async -> [String: Any] {
    let id = UUID().uuidString.prefix(10).lowercased()
    return await withCheckedContinuation { c in
        pending.lock.lock(); pending.waiters[String(id)] = c; pending.lock.unlock()
        send(["type": "control_request", "request_id": String(id), "request": req])
    }
}

// MARK: events
actor Events {
    var waiters: [(String, CheckedContinuation<[String: Any], Never>)] = []
    func wait(for kind: String) async -> [String: Any] {
        await withCheckedContinuation { waiters.append((kind, $0)) }
    }
    func fire(_ kind: String, _ msg: [String: Any]) {
        if let i = waiters.firstIndex(where: { $0.0 == kind }) { waiters.remove(at: i).1.resume(returning: msg) }
    }
}
let events = Events()
var sessionID = ""
var textChars = 0
var sawPermission = false

func handle(_ m: [String: Any]) {
    let type = m["type"] as? String ?? ""
    switch type {
    case "control_response":
        let r = m["response"] as? [String: Any] ?? [:]
        let id = r["request_id"] as? String ?? ""
        pending.lock.lock(); let c = pending.waiters.removeValue(forKey: id); pending.lock.unlock()
        c?.resume(returning: r)
    case "control_request":
        // claude → us: permission prompt.
        let id = m["request_id"] as? String ?? ""
        let req = m["request"] as? [String: Any] ?? [:]
        if req["subtype"] as? String == "can_use_tool" {
            sawPermission = true
            log("◆ PERMISSION ASK  tool=\(req["tool_name"] ?? "?")  input=\(req["input"] ?? [:])")
            log("  → answering: allow")
            send(["type": "control_response", "response": [
                "subtype": "success", "request_id": id,
                "response": ["behavior": "allow", "updatedInput": req["input"] ?? [:]]]])
        } else {
            log("? unhandled control_request \(req["subtype"] ?? "")")
            send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "unsupported"]])
        }
    case "control_cancel_request":
        log("◆ permission cancelled by claude")
    case "system":
        if m["subtype"] as? String == "init" {
            sessionID = m["session_id"] as? String ?? ""
            log("● init  session=\(sessionID)  model=\(m["model"] ?? "?")  tools=\((m["tools"] as? [Any])?.count ?? 0)")
        }
    case "stream_event":
        if let e = m["event"] as? [String: Any], let d = e["delta"] as? [String: Any], let t = d["text"] as? String {
            if textChars == 0 { log("● first streamed text token") }
            textChars += t.count
            Task { await events.fire("text", m) }
        }
    case "assistant":
        let blocks = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        for b in blocks {
            if b["type"] as? String == "text" { log("● assistant: \((b["text"] as? String ?? "").prefix(120))") }
            if b["type"] as? String == "tool_use" { log("● tool_use \(b["name"] ?? "")") }
        }
    case "result":
        log("● result  \(m["subtype"] ?? "")  stop=\(m["stop_reason"] ?? "-")  cost=$\(m["total_cost_usd"] ?? 0)")
        Task { await events.fire("result", m) }
    case "prompt_suggestion":
        log("● prompt suggestion: \(m["suggestion"] ?? "")")
    default: break
    }
}

// MARK: reader
var buffer = Data()
outPipe.fileHandleForReading.readabilityHandler = { h in
    let chunk = h.availableData
    if chunk.isEmpty { return }
    buffer.append(chunk)
    while let nl = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<nl]; buffer = Data(buffer[(nl + 1)...])
        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
    }
}

try! p.run()
log("spawned claude pid \(p.processIdentifier)")

func say(_ text: String) {
    send(["type": "user", "uuid": UUID().uuidString.lowercased(),
          "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull()])
}

Task {
    let ok = { (r: [String: Any]) in r["subtype"] as? String == "success" ? "ok" : "FAILED \(r["error"] ?? "")" }
    // 1. initialize — the SDK's first message. Response carries commands + models.
    let ini = await request(["subtype": "initialize", "promptSuggestions": true])
    let body = ini["response"] as? [String: Any] ?? [:]
    log("✓ initialize \(ok(ini))  commands=\((body["commands"] as? [Any])?.count ?? 0)  models=\((body["models"] as? [Any])?.count ?? 0)  keys=\(body.keys.sorted())")

    // 2. control knobs
    log("✓ set_model haiku: \(ok(await request(["subtype": "set_model", "model": "haiku"])))")
    log("✓ set_permission_mode default: \(ok(await request(["subtype": "set_permission_mode", "mode": "default"])))")

    // 3. a turn that needs permission
    if resume == nil {
        say("Create a file named poc.txt containing the word toasted, using the Write tool. Then reply with exactly: DONE")
    } else {
        say("What word did you write into poc.txt earlier? Answer in one word.")
    }
    _ = await events.wait(for: "result")

    let cu = await request(["subtype": "get_context_usage", "detail": "summary"])
    let u = cu["response"] as? [String: Any] ?? [:]
    log("✓ get_context_usage \(ok(cu))  \(u["totalTokens"] ?? "?")/\(u["maxTokens"] ?? "?") (\(u["percentage"] ?? "?")%)")

    // 4. interrupt mid-stream
    if resume == nil {
        say("Count slowly from 1 to 300, one number per line, with a word after each.")
        _ = await events.wait(for: "text")
        try? await Task.sleep(nanoseconds: 800_000_000)
        log("→ interrupt")
        log("✓ interrupt: \(ok(await request(["subtype": "interrupt"])))")
        _ = await events.wait(for: "result")
    }

    // 5. close stdin → claude ends cleanly
    try? inPipe.fileHandleForWriting.close()
    p.waitUntilExit()
    log("claude exited status \(p.terminationStatus)  permission-asked=\(sawPermission)")
    if resume == nil { print("\nSESSION \(sessionID)") }
    exit(0)
}
RunLoop.main.run()
