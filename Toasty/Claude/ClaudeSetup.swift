import AppKit
import SwiftUI

/// What Claude conversation tabs need on this Mac, checked at launch.
///
/// Conversation tabs run the installed `claude` through the Claude Agent SDK,
/// which runs on Node. The SDK ships inside Toasty and keeps itself matched
/// to `claude` (`ClaudeSDK`), so only Claude Code and Node can be missing.
/// The launch check is silent when both are there; otherwise a sheet says
/// what's missing and how to install it. Terminal tabs never need either.
/// Help ▸ Check Claude Setup… shows the sheet any time.
@MainActor
final class ClaudeSetup: ObservableObject {
    /// The oldest Node the bundled Agent SDK supports (its package.json
    /// `engines.node`, ">=18.14.0").
    static let minimumNode = "18.14.0"
    static let claudeInstall = "curl -fsSL https://claude.ai/install.sh | bash"
    static let nodeDownload = URL(string: "https://nodejs.org/en/download")!
    /// "Don't Remind Me": the launch check stays quiet; the Help item still works.
    static let skipKey = "ToastySkipClaudeSetupCheck"

    enum Status: Equatable {
        case found(path: String, version: String?)
        case tooOld(path: String, version: String)
        case missing

        var isOK: Bool { if case .found = self { true } else { false } }
    }

    @Published private(set) var checking = true
    @Published private(set) var claude: Status = .missing
    @Published private(set) var node: Status = .missing
    /// Homebrew's path, to offer `brew install node`.
    @Published private(set) var brew: String?

    var allSet: Bool { !checking && claude.isOK && node.isOK }

    /// The SDK, for its row: always present.
    var sdkDetail: String {
        let sdk = ClaudeSDK.shared.choice()
        return "Version \(sdk.version), included with Toasty and kept up to date automatically."
    }

    #if DEBUG
    /// Debug only: pretend these are missing ("claude", "node") or old
    /// ("oldnode"), to see the sheet on a Mac that has everything.
    var simulate: Set<String> = []
    #endif

    /// Looks for `claude` and `node` (asking the login shell again when
    /// `fresh`) and reads their versions.
    func check(fresh: Bool = false) {
        checking = true
        ClaudeEnvironment.lookup(fresh: fresh) { [weak self] found in
            Task.detached(priority: .userInitiated) {
                let claudeVersion = found.claude.flatMap { Self.version(of: $0, environment: found.variables) }
                let nodeVersion = found.node.flatMap { Self.version(of: $0, environment: found.variables) }
                let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                    .first { FileManager.default.isExecutableFile(atPath: $0) }
                await MainActor.run {
                    self?.finish(found: found, claudeVersion: claudeVersion, nodeVersion: nodeVersion, brew: brew)
                }
            }
        }
    }

    private func finish(found: ClaudeEnvironment.Lookup, claudeVersion: String?, nodeVersion: String?, brew: String?) {
        claude = found.claude.map { .found(path: $0, version: claudeVersion) } ?? .missing
        if let path = found.node {
            if let v = nodeVersion, Self.isOlder(v, than: Self.minimumNode) {
                node = .tooOld(path: path, version: v)
            } else {
                node = .found(path: path, version: nodeVersion)
            }
        } else {
            node = .missing
        }
        self.brew = brew
        #if DEBUG
        if simulate.contains("claude") { claude = .missing }
        if simulate.contains("node") { node = .missing }
        if simulate.contains("oldnode") { node = .tooOld(path: "/usr/local/bin/node", version: "16.20.2") }
        #endif
        checking = false
    }

    /// `<tool> --version`, reduced to its version number ("v22.19.0" →
    /// "22.19.0", "2.1.321 (Claude Code)" → "2.1.321"). Nil if it doesn't
    /// answer within a few seconds.
    nonisolated private static func version(of tool: String, environment: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["--version"]
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
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    nonisolated static func isOlder(_ version: String, than minimum: String) -> Bool {
        version.compare(minimum, options: .numeric) == .orderedAscending
    }

    // MARK: Presenting

    private static var sheetWindow: NSWindow?

    /// At launch: quiet unless something is missing (and the user hasn't
    /// said not to remind them).
    static func checkAtLaunch() {
        guard !UserDefaults.standard.bool(forKey: skipKey) else { return }
        let model = ClaudeSetup()
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
        window.beginSheet(sheet)
    }

    static func dismiss() {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.allSet ? "Claude Is Ready" : "Set Up Claude Conversations")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.allSet
                     ? "Everything Claude conversation tabs need is on this Mac."
                     : "Terminal tabs are ready to use. Claude conversation tabs also need these on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                claudeRow
                nodeRow
                Row(state: .ok, title: "Claude Agent SDK", detail: model.sdkDetail, checking: false) { EmptyView() }
            }
            .padding(20)

            if !model.allSet && !model.checking {
                Text("Already installed? Toasty looks on your login shell's PATH. After installing, click Check Again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }

            Divider()

            HStack {
                if !model.allSet {
                    Button("Don't Remind Me") {
                        UserDefaults.standard.set(true, forKey: ClaudeSetup.skipKey)
                        dismiss()
                    }
                }
                Spacer()
                Button("Check Again") { model.check(fresh: true) }
                    .disabled(model.checking)
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var claudeRow: some View {
        switch model.claude {
        case .found(let path, let version):
            Row(state: .ok, title: "Claude Code", detail: found(path, version), checking: model.checking) { EmptyView() }
        case .tooOld, .missing:
            Row(state: .missing, title: "Claude Code", detail: "Not found. Install it in a terminal tab:", checking: model.checking) {
                CommandLine(command: ClaudeSetup.claudeInstall)
            }
        }
    }

    @ViewBuilder private var nodeRow: some View {
        switch model.node {
        case .found(let path, let version):
            Row(state: .ok, title: "Node.js", detail: found(path, version), checking: model.checking) { EmptyView() }
        case .tooOld(let path, let version):
            Row(state: .warning, title: "Node.js",
                detail: "Version \(version) at \(abbreviate(path)) is too old. The Claude Agent SDK needs \(ClaudeSetup.minimumNode) or later.",
                checking: model.checking) { nodeInstall }
        case .missing:
            Row(state: .missing, title: "Node.js", detail: "Not found. The Claude Agent SDK runs on Node.", checking: model.checking) {
                nodeInstall
            }
        }
    }

    @ViewBuilder private var nodeInstall: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.brew != nil { CommandLine(command: "brew install node") }
            Link(model.brew != nil ? "Or download it from nodejs.org" : "Download Node.js from nodejs.org",
                 destination: ClaudeSetup.nodeDownload)
                .font(.system(size: 11.5))
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
                .font(.system(size: 14))
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(checking ? "Checking…" : detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !checking { extra().padding(.top, 3) }
                }
            }
        }
    }

    /// A command to paste into a terminal, with a Copy button.
    private struct CommandLine: View {
        let command: String
        @State private var copied = false

        var body: some View {
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
    }
}

#if DEBUG
extension ClaudeSetup {
    /// `{"cmd":"setupCheck","simulate":"claude,node"}` shows the sheet as if
    /// those were missing ("oldnode": an old Node); `{"cmd":"setupCheck","close":true}` closes it.
    static func installDebug() {
        DebugControl.registerAsync("setupCheck") { cmd in
            if cmd["close"] as? Bool == true { dismiss(); return nil }
            dismiss()
            let model = ClaudeSetup()
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
            return ["claude": describe(model.claude), "node": describe(model.node), "allSet": model.allSet]
        }
    }
}
#endif
