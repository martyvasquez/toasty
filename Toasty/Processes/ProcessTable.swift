import Darwin
import Foundation

/// What's running on this Mac, read straight from the kernel (libproc and
/// `sysctl`; no `ps` or `lsof`). Toasty isn't sandboxed, so it can read the
/// user's own processes: their parent, folder, arguments, environment and
/// listening ports. A whole pass over every process takes about 20 ms.
nonisolated enum ProcessTable {
    struct Entry: Sendable, Equatable {
        let pid: pid_t
        let parent: pid_t
        let group: pid_t
        let user: uid_t
        /// When it started: with the pid, the identity of a process (a pid
        /// alone is reused once its process is gone).
        let started: Date
    }

    /// Every process the kernel lists.
    static func pids() -> [pid_t] {
        let count = Int(proc_listallpids(nil, 0))
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: count + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, got)).filter { $0 > 0 }
    }

    static func entry(_ pid: pid_t) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return Entry(pid: pid, parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid), user: info.pbi_uid, started: started)
    }

    /// The user's own processes.
    static func mine() -> [Entry] {
        let me = getuid()
        return pids().compactMap(entry).filter { $0.user == me }
    }

    /// True while `entry` is still that process (not gone, and its pid not
    /// handed to another).
    static func isAlive(_ entry: Entry) -> Bool {
        self.entry(entry.pid)?.started == entry.started
    }

    /// The folder a process is running in.
    static func folder(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The executable a process is running.
    static func executable(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// The TCP ports a process is listening on, lowest first.
    static func listeningPorts(_ pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP),
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            // The port is in network byte order, in the low 16 bits.
            let port = Int(UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).bigEndian)
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// A process's arguments and environment (`NAME=value` strings), as
    /// they were when it started. Nil for a process that can't be read.
    static func arguments(_ pid: pid_t) -> (arguments: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`: the argument count, the executable's path, padding,
    /// then the arguments and the environment, each ending in a zero byte.
    static func parse(_ buffer: [UInt8]) -> (arguments: [String], environment: [String])? {
        guard buffer.count > 4 else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard count >= 0 else { return nil }
        var i = 4
        while i < buffer.count, buffer[i] != 0 { i += 1 }
        while i < buffer.count, buffer[i] == 0 { i += 1 }
        var strings: [String] = []
        var start = i
        while i < buffer.count {
            if buffer[i] == 0 {
                // An argument may be empty; the environment ends at the
                // first empty string.
                if i == start, strings.count >= count { break }
                strings.append(String(decoding: buffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        guard strings.count >= count else { return nil }
        return (Array(strings.prefix(count)), Array(strings.dropFirst(count)))
    }

    /// The value of one environment variable of a process.
    static func environment(_ name: String, of pid: pid_t) -> String? {
        guard let environment = arguments(pid)?.environment else { return nil }
        let prefix = name + "="
        return environment.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
