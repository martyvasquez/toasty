// mctl: command-line client for Toasty Debug's control channel.
//
//   swiftc -O scripts/mctl.swift -o <scratch>/mctl
//   mctl screenshot path=/tmp/a.png
//   mctl click x=100 y=20 count=2
//   mctl key chars=t mods=cmd
//   mctl '{"cmd":"render","path":"/tmp/x.md"}'
//
// Arguments: a command name followed by key=value pairs (numbers and
// true/false are converted), or one raw JSON object. Prints the reply's
// result as JSON; exits 1 on error or timeout (MCTL_TIMEOUT, default 10s).
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else {
    FileHandle.standardError.write("usage: mctl <cmd> [key=value…] | mctl '<json>'\n".data(using: .utf8)!)
    exit(2)
}

var cmd: [String: Any]
if first.hasPrefix("{") {
    cmd = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any] ?? [:]
} else {
    cmd = ["cmd": first]
    for pair in args.dropFirst() {
        guard let eq = pair.firstIndex(of: "=") else { continue }
        let key = String(pair[..<eq]), raw = String(pair[pair.index(after: eq)...])
        if let i = Int(raw) { cmd[key] = i }
        else if let d = Double(raw) { cmd[key] = d }
        else if raw == "true" || raw == "false" { cmd[key] = raw == "true" }
        else { cmd[key] = raw }
    }
}
let id = UUID().uuidString
cmd["id"] = id

let center = DistributedNotificationCenter.default()
var reply: [String: Any]?
let token = center.addObserver(forName: Notification.Name("com.martyvasquez.toasty.debug.reply"), object: nil, queue: nil) { n in
    guard let s = n.object as? String,
          let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
          obj["id"] as? String == id else { return }
    reply = obj
}
let json = String(decoding: try! JSONSerialization.data(withJSONObject: cmd), as: UTF8.self)
center.postNotificationName(Notification.Name("com.martyvasquez.toasty.debug"), object: json, userInfo: nil, deliverImmediately: true)

let timeout = Double(ProcessInfo.processInfo.environment["MCTL_TIMEOUT"] ?? "") ?? 10
let deadline = Date().addingTimeInterval(timeout)
while reply == nil && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
center.removeObserver(token)
guard let reply else {
    FileHandle.standardError.write("mctl: no reply (is Toasty Debug running?)\n".data(using: .utf8)!)
    exit(1)
}
if reply["ok"] as? Bool != true {
    FileHandle.standardError.write("mctl: \(reply["error"] ?? "failed")\n".data(using: .utf8)!)
    exit(1)
}
if let result = reply["result"] {
    if let s = result as? String { print(s) }
    else if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]) {
        print(String(decoding: data, as: UTF8.self))
    }
}
