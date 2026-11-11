import Darwin
import Foundation
import Testing
@testable import Toasty

struct ProcessTests {
    // MARK: The conversation tag

    @Test func tagsRoundTrip() {
        let id = UUID()
        let tag = ProcessReaper.Tag(app: "com.martyvasquez.toasty.debug", owner: 4242, conversation: id)
        #expect(tag.value == "com.martyvasquez.toasty.debug:4242:\(id.uuidString)")
        #expect(ProcessReaper.Tag(tag.value) == tag)
    }

    @Test func malformedTagsAreIgnored() {
        for bad in ["", "toasty", "app:12", "app:x:\(UUID().uuidString)", "app:12:not-a-uuid",
                    ":12:\(UUID().uuidString)", "app:0:\(UUID().uuidString)", "a:1:\(UUID().uuidString):extra"] {
            #expect(ProcessReaper.Tag(bad) == nil, "\(bad)")
        }
    }

    // MARK: Reading processes

    @Test func argumentsAndEnvironmentParse() {
        // argc, the executable, padding, two arguments (one empty), two variables.
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        for s in ["/usr/bin/node", "", "", "node", "", "server.js", "PATH=/bin", "CLAUDECODE=1", ""] {
            bytes += Array(s.utf8) + [0]
        }
        let parsed = ProcessTable.parse(bytes)
        #expect(parsed?.arguments == ["node", "", "server.js"])
        #expect(parsed?.environment == ["PATH=/bin", "CLAUDECODE=1"])
        #expect(ProcessTable.parse([1, 0]) == nil)
    }

    @Test func readsThisProcess() throws {
        let me = try #require(ProcessTable.entry(getpid()))
        #expect(me.parent == getppid())
        #expect(me.user == getuid())
        #expect(ProcessTable.isAlive(me))
        #expect(ProcessTable.mine().contains { $0.pid == getpid() })
        #expect(ProcessTable.folder(getpid()) == FileManager.default.currentDirectoryPath)
        #expect(ProcessTable.executable(getpid()) == Bundle.main.executablePath)
        #expect(ProcessTable.arguments(getpid())?.arguments.first == CommandLine.arguments.first)
    }

    /// A child started with a tag is found by it, with a listening port
    /// read from the kernel, and is gone once stopped.
    @Test func findsAndStopsATaggedServer() async throws {
        let tag = ProcessReaper.Tag(app: "com.martyvasquez.toasty.tests", owner: getpid(), conversation: UUID())
        // The kernel reports the real path (/private/var/…, not /var/…).
        let folder = String(cString: realpath(FileManager.default.temporaryDirectory.path, nil))
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "0", "--bind", "127.0.0.1"]
        server.environment = [ProcessReaper.variable: tag.value, "CLAUDECODE": "1", "PATH": "/usr/bin:/bin"]
        server.currentDirectoryURL = URL(fileURLWithPath: folder)
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { kill(server.processIdentifier, SIGKILL) } }

        var ports: [Int] = []
        for _ in 0..<100 where ports.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            ports = ProcessTable.listeningPorts(server.processIdentifier)
        }
        #expect(ports.count == 1)
        #expect(ProcessTable.folder(server.processIdentifier) == folder)
        #expect(ProcessTable.environment("CLAUDECODE", of: server.processIdentifier) == "1")

        let found = ProcessReaper.tagged { $0 == tag }
        #expect(found.map(\.pid) == [server.processIdentifier])
        #expect(ProcessReaper.tagged { $0.conversation == UUID() }.isEmpty)

        ProcessReaper.stop(found, reason: "test")
        #expect(found.allSatisfy { !ProcessTable.isAlive($0) })
    }

    // MARK: The list

    private func entry(_ pid: pid_t, parent: pid_t = 1, group: pid_t? = nil) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, parent: parent, group: group ?? pid, user: 501, started: Date(timeIntervalSince1970: 1000))
    }

    private func candidate(_ pid: pid_t, parent: pid_t = 1, ports: [Int], folder: String,
                           arguments: [String] = ["node", "server.js"]) -> LocalServers.Candidate {
        .init(process: entry(pid, parent: parent), ports: ports, folder: folder, arguments: arguments, startedByClaude: false)
    }

    @Test func onlyServersInTheUsersFoldersAreListed() {
        let home = "/Users/me"
        let servers = LocalServers.servers(from: [
            candidate(1, ports: [7000], folder: "/"),
            candidate(2, ports: [44950], folder: "/Users/me/Library/Application Support/Figma"),
            candidate(3, ports: [4321], folder: "/Users/me/Development/site"),
            candidate(4, ports: [8000], folder: "/Users/me"),
            candidate(5, ports: [9000], folder: "/Users/meredith/app"),
        ], home: home)
        #expect(servers.map(\.process.pid) == [4, 3])
    }

    @Test func aWorkerSharingItsParentsPortIsTheSameServer() {
        let servers = LocalServers.servers(from: [
            candidate(10, ports: [3000], folder: "/Users/me/app"),
            candidate(11, parent: 10, ports: [3000], folder: "/Users/me/app"),
            candidate(12, parent: 10, ports: [3001], folder: "/Users/me/app"),
        ], home: "/Users/me")
        #expect(servers.map(\.process.pid) == [10, 12])
    }

    @Test func serversSortByFolderThenPort() {
        let servers = LocalServers.servers(from: [
            candidate(1, ports: [4399], folder: "/Users/me/PAM-astro"),
            candidate(2, ports: [3000], folder: "/Users/me/zebra"),
            candidate(3, ports: [4321, 4322], folder: "/Users/me/PAM-astro"),
            candidate(4, ports: [4327], folder: "/Users/me/bytelaunch"),
        ], home: "/Users/me")
        #expect(servers.map(\.process.pid) == [4, 3, 1, 2])
        #expect(servers[1].address == "localhost:4321, 4322")
        #expect(servers[1].url?.absoluteString == "http://localhost:4321")
        #expect(servers[0].name == "bytelaunch")
    }

    @Test func commandsAreNamedWithoutPathsOrOptions() {
        #expect(LocalServers.command(["/Users/me/.nvm/versions/node/v24/bin/node", "/Users/me/site/node_modules/astro/bin/astro.mjs",
                                      "dev", "--port", "4327", "--json"]) == "astro dev")
        #expect(LocalServers.command(["node", "/Users/me/site/node_modules/.bin/astro", "preview", "--port", "4399"]) == "astro preview")
        #expect(LocalServers.command(["node", "/Users/me/site/node_modules/@scope/tool/cli.js", "serve"]) == "tool serve")
        #expect(LocalServers.command(["next-server (v16.3.4)", ""]) == "next-server")
        #expect(LocalServers.command(["node", "--inspect", "server.js"]) == "node server.js")
        #expect(LocalServers.command(["/usr/bin/python3", "-m", "http.server", "8000"]) == "python -m http.server")
        #expect(LocalServers.command(["python3.12", "manage.py", "runserver"]) == "python manage.py runserver")
        #expect(LocalServers.command(["/opt/homebrew/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
                                      "-m", "http.server", "8794"]) == "python -m http.server")
        #expect(LocalServers.command(["Python", "supervisor.py"]) == "python supervisor.py")
        #expect(LocalServers.command(["/opt/homebrew/bin/caddy", "run", "--config", "Caddyfile"]) == "caddy run")
        #expect(LocalServers.command(["bun", "run", "dev"]) == "bun run dev")
        #expect(LocalServers.command(["node"]) == "node")
        #expect(LocalServers.command([]) == "")
    }

    // MARK: Stopping

    @Test func stoppingTakesTheCommandsThatRanTheServerAndItsChildren() {
        // npm run dev → next dev → next-server → a worker, all one job;
        // the shell that ran npm is in a group of its own.
        let shell = entry(100, parent: 1)
        let npm = entry(200, parent: 100, group: 200)
        let next = entry(201, parent: 200, group: 200)
        let server = entry(202, parent: 201, group: 200)
        let worker = entry(203, parent: 202, group: 200)
        let other = entry(300, parent: 100, group: 300)
        let all = [shell, npm, next, server, worker, other]
        let family = LocalServers.family(of: server, in: all) { _ in true }
        #expect(Set(family.map(\.pid)) == [200, 201, 202, 203])
    }

    @Test func stoppingEndsAtWhatHostsTheServer() {
        // Claude Code ran `npm exec astro dev` without a group of its own:
        // the walk up takes npm, not Claude Code or what ran it.
        let host = entry(50, parent: 1, group: 50)
        let claude = entry(60, parent: 50, group: 50)
        let npm = entry(70, parent: 60, group: 50)
        let server = entry(71, parent: 70, group: 50)
        let family = LocalServers.family(of: server, in: [host, claude, npm, server]) { $0.pid != 60 }
        #expect(Set(family.map(\.pid)) == [70, 71])
    }

    @Test func anOrphanedServerStopsAlone() {
        let server = entry(500, parent: 1)
        let family = LocalServers.family(of: server, in: [server, entry(501, parent: 1)]) { _ in true }
        #expect(family.map(\.pid) == [500])
    }
}
