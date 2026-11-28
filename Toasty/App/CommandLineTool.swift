import AppKit
import SwiftUI

// MARK: - The `toasty` command
//
// `toasty` in any terminal opens the folder you're in in Toasty (its
// workspace, or a new one), and `toasty <path>…` opens those: the same as
// `open -a Toasty <path>` (AppDelegate.openFolders). Settings ▸ General ▸
// Command Line installs it: a small script Toasty writes to ~/.local/bin,
// where Claude Code's own installer puts `claude`, so it's usually on PATH
// already and needs no password. The script opens this copy of Toasty by
// its path (by bundle ID, macOS may pick another copy, e.g. a leftover
// download), and Toasty rewrites it at launch when the app has moved.
// Debug builds install `toasty-debug`, which opens the Debug app.

@MainActor
final class CommandLineTool: ObservableObject {
    static let shared = CommandLineTool()

    nonisolated static let name = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "toasty-debug" : "toasty"
    nonisolated static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
    nonisolated static var url: URL { folder.appendingPathComponent(name) }

    /// Installed: the script there is this one (not another program
    /// that happens to be named `toasty`).
    @Published private(set) var installed = false
    /// Another file is at that path; it's left alone.
    @Published private(set) var conflict = false
    /// ~/.local/bin is on the login shell's PATH (nil until known).
    @Published private(set) var onPath: Bool?
    @Published private(set) var error: String?

    private init() { refresh() }

    func refresh() {
        let existing = try? String(contentsOf: Self.url, encoding: .utf8)
        installed = existing == Self.script
        conflict = !installed && FileManager.default.fileExists(atPath: Self.url.path)
            && existing?.contains(Self.marker) != true
        ClaudeEnvironment.lookup { [weak self] found in
            let dirs = (found.variables["PATH"] ?? "").split(separator: ":").map {
                URL(fileURLWithPath: String($0)).standardizedFileURL.path
            }
            self?.onPath = dirs.contains(Self.folder.standardizedFileURL.path)
        }
    }

    /// At launch: an installed script that points at another copy of the
    /// app (moved, or an older script) is rewritten for this one.
    nonisolated static func updateIfInstalled() {
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(marker), existing != script else { return }
        try? script.write(to: url, atomically: true, encoding: .utf8)
    }

    func install() {
        error = nil
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try Self.script.write(to: Self.url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.url.path)
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func uninstall() {
        error = nil
        guard installed || (try? String(contentsOf: Self.url, encoding: .utf8))?.contains(Self.marker) == true else { return }
        do { try FileManager.default.removeItem(at: Self.url) } catch { self.error = error.localizedDescription }
        refresh()
    }

    /// In every version of the script, to tell ours from another program.
    nonisolated private static let marker = "# Installed by Toasty"

    nonisolated static var script: String {
        // Quoted for the shell: the app's path may have spaces.
        let app = "'" + Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # \(name): open folders in Toasty. With no arguments, the folder
        # you're in; otherwise each folder (or a file's folder) given.
        \(marker) (Settings ▸ General ▸ Command Line); delete this file to remove it.
        [ $# -eq 0 ] && set -- .
        for p in "$@"; do
          [ -e "$p" ] || { echo "\(name): $p: No such file or directory" >&2; exit 1; }
        done
        exec /usr/bin/open -a \(app) "$@"

        """
    }
}

/// Settings ▸ General ▸ Command Line.
struct CommandLineSettingsSection: View {
    @ObservedObject private var tool = CommandLineTool.shared

    /// The section's height in the General pane.
    static let height: CGFloat = 136

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(CommandLineTool.name) command")
                    Text(tool.installed ? "Installed in ~/.local/bin" : "Not installed")
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if tool.installed {
                    Button("Uninstall") { tool.uninstall() }
                } else {
                    Button("Install") { tool.install() }.disabled(tool.conflict)
                }
            }
        } header: {
            Text("Command Line")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if tool.conflict {
                    Text("Another program is already at ~/.local/bin/\(CommandLineTool.name), so it's left alone.")
                        .foregroundStyle(.orange)
                } else if let error = tool.error {
                    Text(error).foregroundStyle(.orange)
                } else if tool.installed, tool.onPath == false {
                    Text("~/.local/bin isn't on your shell's PATH yet: add it to use \(CommandLineTool.name) by name.")
                        .foregroundStyle(.orange)
                }
                Text("Type \(CommandLineTool.name) in any terminal to open the folder you're in, or \(CommandLineTool.name) <path> for another: its workspace, or a new one.")
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { tool.refresh() }
    }
}
