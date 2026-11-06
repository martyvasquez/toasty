import Darwin
import Foundation

/// A login shell on a pseudo-terminal. Output is read on a background
/// queue and handed to `onOutput` there; writes go through a serial queue
/// so a large paste never blocks the main thread.
nonisolated final class PTYProcess: @unchecked Sendable {
    let pid: pid_t
    let master: Int32
    private let readQueue = DispatchQueue(label: "toasty.pty.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "toasty.pty.write", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    /// Called on the read queue with each chunk of output.
    var onOutput: ((UnsafeRawBufferPointer) -> Void)?
    /// Called on the main queue when the shell exits.
    var onExit: (@MainActor (Int32) -> Void)?

    enum Failure: Error { case forkpty(Int32) }

    /// Starts `shell` as a login shell (argv[0] = "-zsh") in `cwd`.
    init(shell: String, cwd: String, environment: [String: String], cols: UInt16, rows: UInt16,
         cellWidth: UInt16, cellHeight: UInt16) throws {
        // Everything the child needs is prepared before fork: after fork only
        // async-signal-safe calls are allowed.
        let argv0 = "-" + (shell as NSString).lastPathComponent
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(shell)!
        let dir = strdup(cwd)!
        let home = strdup(NSHomeDirectory())!
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(path); free(dir); free(home)
        }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: cols * cellWidth, ws_ypixel: rows * cellHeight)
        var empty = sigset_t()
        sigemptyset(&empty)

        var fd: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                let pid = forkpty(&fd, nil, nil, &size)
                if pid == 0 {
                    // Child.
                    sigprocmask(SIG_SETMASK, &empty, nil)
                    for sig in [SIGCHLD, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGALRM, SIGPIPE] { signal(sig, SIG_DFL) }
                    if chdir(dir) != 0 { _ = chdir(home) }
                    execve(path, a.baseAddress, e.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { throw Failure.forkpty(errno) }
        self.pid = pid
        self.master = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 1)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let n = read(self.master, buffer.baseAddress, buffer.count)
            if n > 0 {
                self.onOutput?(UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { buffer.deallocate() }
        readSource = source
        source.resume()

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, 0)
            self.exitSource?.cancel()
            MainActor.assumeIsolated { self.onExit?(status) }
        }
        exitSource = exit
        exit.resume()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [master] in
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n }
                    else if errno == EINTR || errno == EAGAIN { usleep(1000) }
                    else { return }
                }
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: cols * cellWidth, ws_ypixel: rows * cellHeight)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// The process in the foreground of the terminal (the shell itself when
    /// nothing is running).
    var foregroundPID: pid_t { tcgetpgrp(master) }

    /// True while a program other than the shell runs in the foreground.
    var hasRunningProcess: Bool {
        let fg = foregroundPID
        return fg > 0 && fg != pid
    }

    /// Name of the foreground process ("vim", "npm"…).
    var foregroundName: String? {
        let fg = foregroundPID
        guard fg > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(fg, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Current directory of the foreground process (works without any
    /// shell integration).
    var foregroundDirectory: String? {
        let fg = foregroundPID > 0 ? foregroundPID : pid
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(fg, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    func terminate() {
        readSource?.cancel()
        kill(pid, SIGHUP)
        close(master)
    }

    /// The environment a terminal tab gets: Toasty's own, minus variables
    /// that describe another terminal or a Claude Code session, plus the
    /// terminal identification programs look for.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dropped: Set<String> = [
            "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINFO", "COLORTERM",
            "SHLVL", "_", "OLDPWD", "PWD", "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier",
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "NO_COLOR",
        ]
        env = env.filter { !dropped.contains($0.key) && !$0.key.hasPrefix("GHOSTTY_") && !$0.key.hasPrefix("ITERM_") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Toasty"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if env["LANG"] == nil {
            let id = Locale.current.identifier.split(separator: "@").first.map(String.init)?
                .replacingOccurrences(of: "-", with: "_") ?? ""
            env["LANG"] = (id.contains("_") ? id : "en_US") + ".UTF-8"
        }
        return env
    }

    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, let s = String(validatingCString: sh), !s.isEmpty { return s }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
