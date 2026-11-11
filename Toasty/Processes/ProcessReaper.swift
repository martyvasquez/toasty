import Darwin
import Foundation
import os

/// Stops what a conversation's Claude Code leaves running when the
/// conversation ends: closing its tab or its workspace, or quitting Toasty.
///
/// A program Claude starts can detach from it (`nohup`, a dev server that
/// puts itself in the background), and then nothing stops it: it loses its
/// parent, so it can't be found from the conversation's process. It does
/// keep its environment, though. So each conversation's Claude Code is
/// started with a variable naming the conversation, everything it starts
/// inherits that, and ending the conversation stops every process carrying
/// it. Only what Toasty's Claude started is ever touched: a server the user
/// runs in a terminal, in the same folder or not, doesn't carry the tag.
nonisolated enum ProcessReaper {
    private static let logger = Logger(subsystem: "com.martyvasquez.toasty", category: "reaper")

    /// The variable every process of a conversation carries.
    static let variable = "TOASTY_CONVERSATION"

    /// Which Toasty a process belongs to (Toasty and Toasty Debug are
    /// separate apps), which run of it, and which conversation.
    struct Tag: Equatable, Sendable {
        var app: String
        var owner: pid_t
        var conversation: UUID

        var value: String { "\(app):\(owner):\(conversation.uuidString)" }

        init(app: String, owner: pid_t, conversation: UUID) {
            self.app = app
            self.owner = owner
            self.conversation = conversation
        }

        init?(_ value: String) {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, let owner = pid_t(parts[1]), owner > 0,
                  let conversation = UUID(uuidString: String(parts[2])) else { return nil }
            self.init(app: String(parts[0]), owner: owner, conversation: conversation)
        }
    }

    static let app = Bundle.main.bundleIdentifier ?? "com.martyvasquez.toasty"

    /// The tag for a conversation of this run of Toasty.
    static func tag(for conversation: UUID) -> Tag {
        Tag(app: app, owner: getpid(), conversation: conversation)
    }

    /// The user's processes carrying a tag that `matches`.
    static func tagged(where matches: (Tag) -> Bool) -> [ProcessTable.Entry] {
        let me = getpid()
        return ProcessTable.mine().filter { entry in
            guard entry.pid != me, let value = ProcessTable.environment(variable, of: entry.pid),
                  let tag = Tag(value) else { return false }
            return matches(tag)
        }
    }

    // MARK: Ending a conversation

    /// A conversation ended (its tab or workspace closed): stop everything
    /// it started. Claude Code is given a moment to end by itself first
    /// (`agent` is its bridge process, already told to finish).
    static func reap(conversation: UUID, after agent: pid_t?) {
        let tag = tag(for: conversation)
        DispatchQueue.global(qos: .utility).async {
            if let agent {
                let deadline = Date().addingTimeInterval(3)
                while kill(agent, 0) == 0, Date() < deadline { usleep(50_000) }
            }
            stop(tagged { $0 == tag }, reason: "conversation closed")
        }
    }

    // MARK: Quitting

    /// Toasty is quitting: stop what its conversations started, without
    /// holding up the quit. Claude Code itself (`agents`, the bridges, and
    /// the `claude` each runs) ends on its own when Toasty's pipes close, as
    /// it always has; everything else is told to stop now. Anything still
    /// running two seconds later is killed by a small shell left behind.
    static func reapAtQuit(agents: [pid_t]) {
        let mine = tagged { $0.app == app && $0.owner == getpid() }
        let own = Set(agents)
        let targets = mine.filter { !own.contains($0.pid) && !own.contains($0.parent) }
        guard !targets.isEmpty else { return }
        logger.notice("quit: stopping \(targets.count) processes")
        targets.forEach { kill($0.pid, SIGTERM) }
        let pids = targets.map { String($0.pid) }.joined(separator: " ")
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/bin/sh")
        killer.arguments = ["-c", "sleep 2; kill -9 \(pids) 2>/dev/null"]
        killer.environment = [:]
        killer.standardInput = FileHandle.nullDevice
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
    }

    // MARK: Leftovers

    /// At launch: stop what an earlier run of this app left behind (it
    /// crashed or was force-quit, so nothing was stopped then).
    static func sweepLeftovers() {
        DispatchQueue.global(qos: .utility).async {
            let me = getpid()
            let path = ProcessTable.executable(me)
            var running: [pid_t: Bool] = [:]
            let leftovers = tagged { tag in
                guard tag.app == app, tag.owner != me else { return false }
                // Another copy of this app that's still running keeps its own.
                if running[tag.owner] == nil {
                    running[tag.owner] = path != nil && ProcessTable.executable(tag.owner) == path
                }
                return running[tag.owner] == false
            }
            stop(leftovers, reason: "left by an earlier run")
        }
    }

    // MARK: Stopping

    /// Ask each process to stop; kill what hasn't two seconds later. Blocks
    /// while it waits: call it off the main thread.
    static func stop(_ processes: [ProcessTable.Entry], reason: String) {
        let targets = processes.filter(ProcessTable.isAlive)
        guard !targets.isEmpty else { return }
        logger.notice("\(reason, privacy: .public): stopping \(targets.count) processes")
        targets.forEach { kill($0.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(2)
        var left = targets
        while !left.isEmpty, Date() < deadline {
            usleep(50_000)
            left = left.filter(ProcessTable.isAlive)
        }
        left.forEach { kill($0.pid, SIGKILL) }
    }
}
