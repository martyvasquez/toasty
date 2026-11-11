#if DEBUG
import AppKit

/// Debug commands for what conversations leave running and the Local
/// Servers window.
enum ProcessDebug {
    static func install() {
        // {"cmd":"servers"} lists them; {"show":true} opens the window,
        // {"show":false} closes it; {"stop":4321} stops the one on a port.
        DebugControl.registerAsync("servers") { cmd in
            let controller = LocalServersWindowController.shared
            if let show = cmd["show"] as? Bool {
                if show { controller.show(nil) } else { controller.window?.close() }
            }
            let found = await Task.detached { LocalServers.scan() }.value
            if let port = cmd["stop"] as? Int, let server = found.first(where: { $0.ports.contains(port) }) {
                controller.model.stop(server)
            }
            return found.map { s in
                ["pid": Int(s.process.pid), "ports": s.ports, "folder": s.folder, "command": s.command,
                 "claude": s.startedByClaude] as [String: Any]
            }
        }

        // What carries a conversation tag of this app: each process's pid,
        // tag and command. {"conversation":"<uuid>"} narrows it to one.
        DebugControl.registerAsync("tagged") { cmd in
            let only = (cmd["conversation"] as? String).flatMap(UUID.init(uuidString:))
            let found = await Task.detached {
                ProcessReaper.tagged { $0.app == ProcessReaper.app && (only == nil || $0.conversation == only) }.map { e in
                    (e, ProcessTable.environment(ProcessReaper.variable, of: e.pid) ?? "",
                     LocalServers.command(ProcessTable.arguments(e.pid)?.arguments ?? []))
                }
            }.value
            return found.map { e, tag, command in
                ["pid": Int(e.pid), "parent": Int(e.parent), "tag": tag, "command": command] as [String: Any]
            }
        }
    }
}
#endif
