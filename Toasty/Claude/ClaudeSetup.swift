import AppKit
import SwiftUI

/// What Claude conversation tabs need on this Mac, checked at every launch.
///
/// Conversation tabs run the installed `claude` through the Claude Agent SDK,
/// which runs on Node. The SDK ships inside Toasty and keeps itself matched
/// to `claude` (`ClaudeSDK`), so what can be wrong is: Claude Code missing or
/// older than Toasty supports, Node missing or too old, or Claude Code not
/// signed in. With everything in place the check is silent. Otherwise a
/// sheet blocks the window until it's fixed: Fix in Terminal runs the missing
/// steps in a terminal inside the sheet, checks again when they finish, and
/// the sheet closes itself once everything passes. There's no way to skip
/// it; Quit Toasty is the other way out. Help ▸ Check Claude Setup… shows the
/// sheet any time.
@MainActor
final class ClaudeSetup: ObservableObject {
    /// The oldest Node the bundled Agent SDK supports (its package.json
    /// `engines.node`, ">=18.14.0").
    static let minimumNode = "18.14.0"
    /// The oldest Claude Code Toasty has been used with: the one the first
    /// bundled Agent SDK (0.3.319) was built for. Newer ones are fine, so a
    /// Claude Code a few releases behind the newest passes; it updates
    /// itself.
    nonisolated static let minimumClaude = "2.1.319"
    static let claudeInstall = "curl -fsSL https://claude.ai/install.sh | bash"
    static let nodeDownload = URL(string: "https://nodejs.org/en/download")!

    enum Status: Equatable {
        case found(path: String, version: String?)
        case tooOld(path: String, version: String)
        case missing

        var isOK: Bool { if case .found = self { true } else { false } }
    }

    /// From `claude auth status`.
    enum SignIn: Equatable {
        /// Signed in; the account's email when it has one.
        case signedIn(email: String?)
        case signedOut
        /// No `claude` to ask, or it didn't answer: not held against setup.
        case unknown
    }

    /// The fix running in the sheet's terminal.
    enum Fix: Equatable {
        case idle
        case running
        /// It ended with this status; nonzero leaves its output up.
        case finished(Int32)
    }

    @Published private(set) var checking = true
    @Published private(set) var claude: Status = .missing
    @Published private(set) var node: Status = .missing
    @Published private(set) var signIn: SignIn = .unknown
    /// When `claude` is too old: a new enough one later on PATH, which
    /// the user may think is the one in use.
    @Published private(set) var newerClaude: (path: String, version: String)?
    /// Homebrew's path, to install Node with.
    @Published private(set) var brew: String?
    @Published private(set) var fix: Fix = .idle
    /// The terminal Fix in Terminal runs in.
    private(set) var fixTerminal: TerminalScrollView?
    /// Shown at launch because something was missing: close by itself once
    /// everything passes.
    var closesWhenReady = false

    var allSet: Bool { !checking && claude.isOK && node.isOK && signIn != .signedOut }

    /// The SDK, for its row: always present.
    var sdkDetail: String {
        let sdk = ClaudeSDK.shared.choice()
        return "Version \(sdk.version), included with Toasty and kept up to date automatically."
    }

    #if DEBUG
    /// Debug only: pretend these are wrong ("claude", "oldclaude", "node",
    /// "oldnode", "signedout"), to see the sheet on a Mac that has everything.
    var simulate: Set<String> = []
    #endif

    /// Looks for `claude` and `node` (asking the login shell again when
    /// `fresh`), reads their versions and whether Claude Code is signed in.
    func check(fresh: Bool = false) {
        checking = true
        ClaudeEnvironment.lookup(fresh: fresh) { [weak self] found in
            Task.detached(priority: .userInitiated) {
                let claudeVersion = found.claude.flatMap { Self.version(of: $0, environment: found.variables) }
                var newer: (path: String, version: String)?
                if let v = claudeVersion, Self.isOlder(v, than: Self.minimumClaude) {
                    for path in found.otherClaudes {
                        if let v = Self.version(of: path, environment: found.variables),
                           !Self.isOlder(v, than: Self.minimumClaude) { newer = (path, v); break }
                    }
                }
                let nodeVersion = found.node.flatMap { Self.version(of: $0, environment: found.variables) }
                let signIn = found.claude.map { Self.signIn(claude: $0, environment: found.variables) } ?? .unknown
                let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                    .first { FileManager.default.isExecutableFile(atPath: $0) }
                await MainActor.run {
                    self?.newerClaude = newer
                    self?.finish(found: found, claudeVersion: claudeVersion, nodeVersion: nodeVersion,
                                 signIn: signIn, brew: brew)
                }
            }
        }
    }

    private func finish(found: ClaudeEnvironment.Lookup, claudeVersion: String?, nodeVersion: String?,
                        signIn: SignIn, brew: String?) {
        if let path = found.claude {
            if let v = claudeVersion, Self.isOlder(v, than: Self.minimumClaude) {
                claude = .tooOld(path: path, version: v)
            } else {
                claude = .found(path: path, version: claudeVersion)
            }
        } else {
            claude = .missing
        }
        if let path = found.node {
            if let v = nodeVersion, Self.isOlder(v, than: Self.minimumNode) {
                node = .tooOld(path: path, version: v)
            } else {
                node = .found(path: path, version: nodeVersion)
            }
        } else {
            node = .missing
        }
        self.signIn = claude == .missing ? .unknown : signIn
        self.brew = brew
        #if DEBUG
        if simulate.contains("claude") { claude = .missing; self.signIn = .unknown }
        if simulate.contains("oldclaude") { claude = .tooOld(path: "~/.local/bin/claude", version: "2.1.200") }
        if simulate.contains("node") { node = .missing }
        if simulate.contains("oldnode") { node = .tooOld(path: "/usr/local/bin/node", version: "16.20.2") }
        if simulate.contains("signedout") { self.signIn = .signedOut }
        #endif
        checking = false
        if allSet, closesWhenReady {
            // A beat to see it all turn green.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.allSet else { return }
                Self.dismiss()
            }
        }
    }

    /// `<tool> --version`, reduced to its version number ("v22.19.0" →
    /// "22.19.0", "2.1.321 (Claude Code)" → "2.1.321"). Nil if it doesn't
    /// answer within a few seconds.
    nonisolated private static func version(of tool: String, environment: [String: String]) -> String? {
        guard let text = run(tool, ["--version"], environment: environment),
              let r = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// `claude auth status --json`: local, no network. `.unknown` when it
    /// doesn't answer or the answer can't be read (an older `claude`).
    nonisolated private static func signIn(claude: String, environment: [String: String]) -> SignIn {
        guard let text = run(claude, ["auth", "status", "--json"], environment: environment) else { return .unknown }
        return parseSignIn(text)
    }

    nonisolated static func parseSignIn(_ text: String) -> SignIn {
        guard let start = text.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool else { return .unknown }
        return loggedIn ? .signedIn(email: json["email"] as? String) : .signedOut
    }

    /// Runs `tool` and returns its standard output; nil if it can't start
    /// or doesn't finish within a few seconds.
    nonisolated private static func run(_ tool: String, _ arguments: [String], environment: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func isOlder(_ version: String, than minimum: String) -> Bool {
        version.compare(minimum, options: .numeric) == .orderedAscending
    }

    // MARK: Fixing

    /// The shell command that fixes what's wrong, nil when Toasty can't
    /// (only Node is missing and there's no Homebrew to install it with).
    var fixCommand: String? {
        var steps: [(String, String)] = []
        switch claude {
        case .missing: steps.append(("Installing Claude Code", Self.claudeInstall))
        // The `claude` the check found, by path: another one earlier on
        // the fix terminal's PATH would be updated instead. Homebrew's is
        // updated by Homebrew.
        case .tooOld(let path, _):
            let update = Self.homebrewPackage(path).flatMap { package in brew.map { "\($0) upgrade \(package)" } }
            steps.append(("Updating Claude Code", update ?? "\(Self.shellQuoted(path)) update"))
        case .found: break
        }
        if !node.isOK, let brew { steps.append(("Installing Node.js", "\(brew) install node")) }
        if claude == .missing || signIn == .signedOut {
            steps.append(("Signing in to Claude", "claude auth login"))
        }
        return Self.script(steps)
    }

    /// zsh: each step under a bold heading, stopping at the first failure.
    /// `~/.local/bin` first, where the installer puts `claude`, so the
    /// steps after the install find it.
    nonisolated static func script(_ steps: [(title: String, command: String)]) -> String? {
        guard !steps.isEmpty else { return nil }
        let parts = steps.map { "printf '\\033[1m%s…\\033[0m\\n\\n' '\($0.title)' && \($0.command) && echo" }
        return (["export PATH=\"$HOME/.local/bin:$PATH\""] + parts).joined(separator: " && ")
    }

    /// The Homebrew formula or cask `path` comes from ("claude-code"), nil
    /// when it isn't Homebrew's.
    nonisolated static func homebrewPackage(_ path: String, resolve: Bool = true) -> String? {
        let real = resolve ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        let parts = real.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0 == "Caskroom" || $0 == "Cellar" }), i + 1 < parts.count,
              parts[i + 1].range(of: #"^[a-z0-9@._+-]+$"#, options: .regularExpression) != nil else { return nil }
        return parts[i + 1]
    }

    nonisolated static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var fixCanRun: Bool { fixCommand != nil && fix != .running }

    /// Fix in Terminal: runs `fixCommand` in a terminal in the sheet, then
    /// checks again.
    func runFix(command override: String? = nil) {
        guard let command = override ?? fixCommand, fix != .running else { return }
        fixTerminal?.terminal.terminate()
        let view = TerminalScrollView(cwd: NSHomeDirectory(), command: command, shell: "/bin/zsh")
        view.terminal.onExit = { [weak self] status in
            guard let self else { return }
            self.fix = .finished(status)
            self.check(fresh: true)
        }
        fixTerminal = view
        fix = .running
        DispatchQueue.main.async { view.window?.makeFirstResponder(view.terminal) }
    }

    func stopFix() {
        fixTerminal?.terminal.terminate()
    }

    // MARK: Presenting

    private static var sheetWindow: NSWindow?
    private static var sheetModel: ClaudeSetup?

    /// Every launch: quiet when everything's there; otherwise the sheet,
    /// until it's fixed.
    static func checkAtLaunch() {
        UserDefaults.standard.removeObject(forKey: "ToastySkipClaudeSetupCheck")
        let model = ClaudeSetup()
        model.closesWhenReady = true
        model.check()
        Task {
            while model.checking { try? await Task.sleep(for: .milliseconds(100)) }
            if !model.allSet { present(model) }
        }
    }

    /// Help ▸ Check Claude Setup…: always shows, checking afresh.
    static func show() {
        let model = ClaudeSetup()
        model.check(fresh: true)
        present(model)
    }

    static func present(_ model: ClaudeSetup) {
        guard sheetWindow == nil, let window = AppDelegate.shared.windowController?.window else { return }
        let host = NSHostingController(rootView: ClaudeSetupView(model: model) { dismiss() })
        host.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: host)
        sheetWindow = sheet
        sheetModel = model
        window.beginSheet(sheet)
    }

    /// The sheet Quit Toasty closed, until the quit goes through.
    private static var quitModel: ClaudeSetup?

    /// Quit Toasty. AppKit ignores a quit while the window has a sheet, so
    /// close it first and quit once it's gone; it comes back if the quit
    /// confirmation is cancelled.
    static func quit() {
        let window = AppDelegate.shared.windowController?.window
        quitModel = sheetModel
        dismiss()
        func whenClosed(_ tries: Int) {
            if window?.attachedSheet == nil || tries == 0 { NSApp.terminate(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { whenClosed(tries - 1) }
        }
        whenClosed(40)
    }

    static func quitCancelled() {
        guard let model = quitModel else { return }
        quitModel = nil
        present(model)
    }

    static func dismiss() {
        sheetModel?.stopFix()
        sheetModel = nil
        if let sheet = sheetWindow { sheet.sheetParent?.endSheet(sheet) }
        sheetWindow = nil
    }
}

/// Help ▸ Check Claude Setup…
final class ClaudeSetupMenu: NSObject {
    static let shared = ClaudeSetupMenu()
    @objc func show(_ sender: Any?) { ClaudeSetup.show() }
}

struct ClaudeSetupView: View {
    @ObservedObject var model: ClaudeSetup
    let dismiss: () -> Void

    private var ready: Bool { model.allSet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ready ? "Claude Is Ready" : "Set Up Claude")
                    .font(.toasty(Theme.Size.title, .semibold))
                Text(ready
                     ? "Everything Toasty needs is on this Mac."
                     : "Toasty runs Claude Code on this Mac. Fix the items below to continue.")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                claudeRow
                signInRow
                nodeRow
                Row(state: .ok, title: "Claude Agent SDK", detail: model.sdkDetail, checking: false) { EmptyView() }
            }
            .padding(20)

            if let terminal = model.fixTerminal, !ready {
                TerminalBox(view: terminal)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(.separator))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }

            if let note {
                Text(note)
                    .font(.toasty(Theme.Size.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }

            Divider()

            HStack {
                if ready {
                    Spacer()
                    Button("Done", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Quit Toasty") { ClaudeSetup.quit() }
                    Spacer()
                    if model.fix == .running {
                        Button("Stop") { model.stopFix() }
                    } else {
                        Button("Check Again") { model.check(fresh: true) }
                            .disabled(model.checking)
                        if model.fixCommand != nil {
                            Button(model.fix == .idle ? "Fix in Terminal" : "Try Again") { model.runFix() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(model.checking)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The line above the buttons, when something needs saying.
    private var note: String? {
        guard !ready, !model.checking else { return nil }
        switch model.fix {
        case .running: return "Follow the steps in the terminal. Signing in opens your browser."
        case .finished(let status) where status != 0:
            return "That didn't finish. Check the terminal above, then try again."
        default:
            if model.fixCommand == nil {
                return "Install Node.js, then click Check Again."
            }
            return "Already installed? Toasty looks on your login shell's PATH."
        }
    }

    @ViewBuilder private var claudeRow: some View {
        switch model.claude {
        case .found(let path, let version):
            Row(state: .ok, title: "Claude Code", detail: found(path, version), checking: model.checking) { EmptyView() }
        case .tooOld(let path, let version):
            Row(state: .warning, title: "Claude Code",
                detail: "Version \(version) at \(abbreviate(path)) is too old. Toasty needs \(ClaudeSetup.minimumClaude) or later."
                    + (model.newerClaude.map { " Version \($0.version) at \(abbreviate($0.path)) is new enough, but comes later on your PATH." } ?? ""),
                checking: model.checking) { EmptyView() }
        case .missing:
            Row(state: .missing, title: "Claude Code", detail: "Not installed.", checking: model.checking) { EmptyView() }
        }
    }

    @ViewBuilder private var signInRow: some View {
        switch model.signIn {
        case .signedIn(let email):
            Row(state: .ok, title: "Claude Account", detail: email.map { "Signed in as \($0)" } ?? "Signed in.",
                checking: model.checking) { EmptyView() }
        case .signedOut:
            Row(state: .missing, title: "Claude Account", detail: "Not signed in.", checking: model.checking) { EmptyView() }
        case .unknown:
            Row(state: model.claude == .missing ? .missing : .ok, title: "Claude Account",
                detail: model.claude == .missing ? "Sign in after installing Claude Code." : "Signed in.",
                checking: model.checking) { EmptyView() }
        }
    }

    @ViewBuilder private var nodeRow: some View {
        switch model.node {
        case .found(let path, let version):
            Row(state: .ok, title: "Node.js", detail: found(path, version), checking: model.checking) { EmptyView() }
        case .tooOld(let path, let version):
            Row(state: .warning, title: "Node.js",
                detail: "Version \(version) at \(abbreviate(path)) is too old. The Claude Agent SDK needs \(ClaudeSetup.minimumNode) or later.",
                checking: model.checking) { nodeDownload }
        case .missing:
            Row(state: .missing, title: "Node.js", detail: "Not installed. The Claude Agent SDK runs on Node.",
                checking: model.checking) { nodeDownload }
        }
    }

    /// Without Homebrew, Fix in Terminal can't install Node.
    @ViewBuilder private var nodeDownload: some View {
        if model.brew == nil {
            Link("Download Node.js from nodejs.org", destination: ClaudeSetup.nodeDownload)
                .font(.toasty(Theme.Size.meta))
        }
    }

    private func found(_ path: String, _ version: String?) -> String {
        (version.map { "Version \($0) at " } ?? "At ") + abbreviate(path)
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private enum RowState { case ok, warning, missing }

    private struct Row<Extra: View>: View {
        let state: RowState
        let title: String
        let detail: String
        let checking: Bool
        @ViewBuilder let extra: () -> Extra

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if checking {
                        ProgressView().controlSize(.mini)
                    } else {
                        switch state {
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .font(.toasty(Theme.Size.body))
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.toasty(Theme.Size.control, .medium))
                    Text(checking ? "Checking…" : detail)
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !checking { extra().padding(.top, 3) }
                }
            }
        }
    }

    /// The fix's terminal.
    private struct TerminalBox: NSViewRepresentable {
        let view: TerminalScrollView
        func makeNSView(context: Context) -> TerminalScrollView { view }
        func updateNSView(_ nsView: TerminalScrollView, context: Context) {}
    }
}

#if DEBUG
extension ClaudeSetup {
    /// `{"cmd":"setupCheck","simulate":"claude,node"}` shows the sheet as if
    /// those were wrong (see `simulate`); `{"cmd":"setupCheck","close":true}`
    /// closes it; `{"cmd":"setupCheck","fix":true,"command":"…"}` runs Fix in Terminal
    /// with that command instead of the real steps.
    static func installDebug() {
        DebugControl.registerAsync("setupCheck") { cmd in
            if cmd["close"] as? Bool == true { dismiss(); return nil }
            // What Quit Toasty does.
            if cmd["quit"] as? Bool == true { DispatchQueue.main.async { quit() }; return nil }
            if cmd["fix"] as? Bool == true {
                guard let model = sheetModel else { return ["error": "no sheet"] }
                // A test command instead of the real fix, which would
                // install software or sign in.
                let command = cmd["command"] as? String ?? "echo test"
                // "succeed": the next check sees the real setup.
                if cmd["succeed"] as? Bool == true { model.simulate = [] }
                model.runFix(command: command)
                return ["command": command]
            }
            dismiss()
            let model = ClaudeSetup()
            model.closesWhenReady = true
            model.simulate = Set((cmd["simulate"] as? String ?? "").split(separator: ",").map(String.init))
            model.check(fresh: cmd["fresh"] as? Bool == true)
            present(model)
            while model.checking { try? await Task.sleep(for: .milliseconds(50)) }
            func describe(_ s: Status) -> String {
                switch s {
                case .found(let p, let v): "found \(v ?? "?") \(p)"
                case .tooOld(let p, let v): "too old \(v) \(p)"
                case .missing: "missing"
                }
            }
            return ["claude": describe(model.claude), "node": describe(model.node),
                    "signIn": "\(model.signIn)", "allSet": model.allSet, "fixCommand": model.fixCommand ?? NSNull()]
        }
    }
}
#endif
