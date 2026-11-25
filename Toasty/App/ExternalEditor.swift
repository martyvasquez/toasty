import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Opening files in the user's editor
//
// "Open in VS Code" (or PhpStorm, Sublime Text, Zed…) opens a file in the
// editor's window for its project, not as a loose file: the project's
// sidebar, search, language server and git are there. Each editor is
// handed the project folder and the file in one launch, through the
// command-line tool inside its own app bundle (so nothing has to be on
// the user's PATH): an editor reuses the window that has the folder open,
// or opens the folder, and shows the file in it, at a line when given.
//
// Settings ▸ General ▸ Editor picks which, from the editors installed;
// the first one found until the user picks. None installed, the menus
// don't offer it.

@MainActor
final class ExternalEditor: ObservableObject {
    static let shared = ExternalEditor()

    /// How an editor takes a project and a file.
    enum Family {
        /// VS Code and its forks: `<bin> <project> -g <file>:<line>`.
        case vscode(cli: String)
        /// JetBrains IDEs: `open -na <app> --args <project> --line N <file>`.
        case jetbrains
        /// Sublime Text: `subl <project> <file>:<line>`.
        case sublime
        /// Zed: `cli <project> <file>:<line>`.
        case zed
    }

    struct Editor: Identifiable, Equatable {
        let id: String          // the bundle ID
        let name: String
        let family: Family
        var app: URL?

        static func == (a: Editor, b: Editor) -> Bool { a.id == b.id }
    }

    /// Every editor Toasty knows, in the order they're offered (and the
    /// first installed is the default).
    nonisolated static let known: [(id: String, name: String, family: Family)] = [
        ("com.microsoft.VSCode", "VS Code", .vscode(cli: "code")),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders", .vscode(cli: "code-insiders")),
        ("com.todesktop.230313mzl4w4u92", "Cursor", .vscode(cli: "cursor")),
        ("com.exafunction.windsurf", "Windsurf", .vscode(cli: "windsurf")),
        ("com.vscodium", "VSCodium", .vscode(cli: "codium")),
        ("com.jetbrains.PhpStorm", "PhpStorm", .jetbrains),
        ("com.jetbrains.WebStorm", "WebStorm", .jetbrains),
        ("com.jetbrains.intellij", "IntelliJ IDEA", .jetbrains),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE", .jetbrains),
        ("com.jetbrains.pycharm", "PyCharm", .jetbrains),
        ("com.jetbrains.pycharm.ce", "PyCharm CE", .jetbrains),
        ("com.jetbrains.goland", "GoLand", .jetbrains),
        ("com.jetbrains.rubymine", "RubyMine", .jetbrains),
        ("com.jetbrains.rider", "Rider", .jetbrains),
        ("com.jetbrains.CLion", "CLion", .jetbrains),
        ("com.jetbrains.rustrover", "RustRover", .jetbrains),
        ("com.sublimetext.4", "Sublime Text", .sublime),
        ("com.sublimetext.3", "Sublime Text", .sublime),
        ("dev.zed.Zed", "Zed", .zed),
    ]

    /// The known editors on this Mac.
    @Published private(set) var installed: [Editor] = []

    /// The bundle ID picked in Settings; "" for the default app.
    @Published var choiceID: String {
        didSet { UserDefaults.standard.set(choiceID, forKey: Self.key) }
    }

    /// What "none" is stored as: open in each file's default app.
    static let defaultApp = ""
    private static let key = "ToastyExternalEditor"

    private init() {
        choiceID = UserDefaults.standard.string(forKey: Self.key) ?? ""
        refresh()
        if UserDefaults.standard.object(forKey: Self.key) == nil, let first = installed.first {
            choiceID = first.id
        }
    }

    /// Look again for installed editors (Settings does, when it shows).
    func refresh() {
        var seen = Set<String>()
        installed = Self.known.compactMap { entry in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id),
                  seen.insert(entry.name).inserted else { return nil }
            return Editor(id: entry.id, name: entry.name, family: entry.family, app: app)
        }
    }

    /// The editor files open in, if one is picked and still installed.
    var editor: Editor? { installed.first { $0.id == choiceID } }

    // MARK: Opening

    /// Open `file` in the editor's window for `project` (a folder), at
    /// `line` when given. Without an editor, the file's default app; with
    /// `textOnly`, also when the file isn't text (an image, a PDF).
    /// `in`: this editor instead of the one picked (Open In's others).
    func open(_ file: URL, project: String?, line: Int? = nil, textOnly: Bool = false, in other: Editor? = nil) {
        guard let editor = other ?? editor, let app = editor.app, !textOnly || Self.isText(file) else {
            NSWorkspace.shared.open(file)
            return
        }
        // Real paths throughout: an editor matches its open windows by path,
        // so /tmp/x and /private/tmp/x would make a second window.
        let file = file.resolvingSymlinksInPath()
        let root = Self.projectRoot(for: file, workspace: project)
        launch(editor, app: app, root: root, file: file.path, line: line)
    }

    /// Open a folder (a workspace) as a project in the editor; without
    /// one, in the Finder.
    func openFolder(_ folder: String) {
        guard let editor, let app = editor.app else {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
            return
        }
        launch(editor, app: app, root: URL(fileURLWithPath: folder).resolvingSymlinksInPath().path, file: nil, line: nil)
    }

    /// A folder inside a project, in the project's window: no editor can
    /// be told to show a folder in its sidebar, so this opens a file from
    /// it (its README, else an index or main file, else the first by name),
    /// which most editors reveal there. An empty folder: just the project.
    func openFolder(_ folder: String, inProject project: String) {
        guard editor != nil else { return openFolder(folder) }
        if let file = Self.representativeFile(in: folder) {
            open(file, project: project)
        } else {
            openFolder(Self.projectRoot(for: URL(fileURLWithPath: folder).appendingPathComponent("x"), workspace: project))
        }
    }

    nonisolated static func representativeFile(in folder: String) -> URL? {
        let url = URL(fileURLWithPath: folder)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        let files = items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        func named(_ stem: String) -> URL? {
            files.first { ($0.lastPathComponent as NSString).deletingPathExtension.lowercased() == stem && isText($0) }
        }
        return named("readme") ?? named("index") ?? named("main") ?? files.first(where: isText) ?? files.first
    }

    /// The project folder, and the file in it at a line when given, in one
    /// launch of the editor's own tool.
    private func launch(_ editor: Editor, app: URL, root: String, file: String?, line: Int?) {
        let target = file.map { f in line.map { "\(f):\($0)" } ?? f }
        let fallback = (app, [root] + (file.map { [$0] } ?? []))
        switch editor.family {
        case .vscode(let cli):
            let bin = app.appendingPathComponent("Contents/Resources/app/bin/\(cli)")
            let projectArg = Self.projectFile(in: root, extension: "code-workspace") ?? root
            run(bin, [projectArg] + (target.map { ["-g", $0] } ?? []), fallback: fallback)
        case .jetbrains:
            var args = ["-na", app.path, "--args", root]
            if let file {
                if let line { args += ["--line", String(line)] }
                args.append(file)
            }
            run(URL(fileURLWithPath: "/usr/bin/open"), args, fallback: fallback)
        case .sublime:
            let bin = app.appendingPathComponent("Contents/SharedSupport/bin/subl")
            let projectArgs = Self.projectFile(in: root, extension: "sublime-project").map { ["--project", $0] } ?? [root]
            run(bin, projectArgs + (target.map { [$0] } ?? []), fallback: fallback)
        case .zed:
            let bin = app.appendingPathComponent("Contents/MacOS/cli")
            run(bin, [root] + (target.map { [$0] } ?? []), fallback: fallback)
        }
    }

    /// Whether a file is for an editor: text and code (and files with no
    /// extension or one macOS doesn't know, like Makefile or .env), not
    /// images, PDFs or documents.
    nonisolated static func isText(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return true }
        return [.text, .sourceCode, .xml, .json, .propertyList, .yaml, .shellScript].contains { type.conforms(to: $0) }
    }

    /// Run an editor's tool; when it's missing or fails, hand the folder
    /// and file to the app itself the ordinary way.
    private func run(_ tool: URL, _ args: [String], fallback: (app: URL, paths: [String])) {
        let (app, paths) = fallback
        let openDirectly: @Sendable () -> Void = {
            NSWorkspace.shared.open(paths.map { URL(fileURLWithPath: $0) },
                                    withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return openDirectly() }
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        // The tools are shell scripts that need the system's basics.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" + (env["PATH"].map { ":" + $0 } ?? "")
        // Not Toasty's own Electron/Node settings, if any leaked in.
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            if p.terminationStatus != 0 { openDirectly() }
        }
        do { try process.run() } catch { openDirectly() }
    }

    /// The project a file belongs to: the workspace's folder when the
    /// file is in it; otherwise the git repository holding it; otherwise
    /// its own folder.
    nonisolated static func projectRoot(for file: URL, workspace: String?) -> String {
        let file = file.resolvingSymlinksInPath()
        let path = file.path
        if let workspace {
            let folder = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
            if path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") { return folder }
        }
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent()
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            dir = dir.deletingLastPathComponent()
        }
        return file.deletingLastPathComponent().path
    }

    /// The project's own file for an editor (a `.code-workspace` or
    /// `.sublime-project` at its top), when there's exactly one.
    nonisolated static func projectFile(in folder: String, extension ext: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let matches = names.filter { ($0 as NSString).pathExtension == ext }
        guard matches.count == 1 else { return nil }
        return (folder as NSString).appendingPathComponent(matches[0])
    }
}

// MARK: - Menu items and settings

/// "Open in VS Code" for a context menu, when an editor is picked.
struct OpenInEditorButton: View {
    let file: URL
    let project: String?
    var line: Int? = nil
    @ObservedObject private var editors = ExternalEditor.shared

    var body: some View {
        if let editor = editors.editor {
            Button("Open in \(editor.name)") { editors.open(file, project: project, line: line) }
        }
    }
}

/// Settings ▸ General ▸ Editor.
struct EditorSettingsSection: View {
    @ObservedObject private var editors = ExternalEditor.shared

    /// The section's height in the General pane.
    static let height: CGFloat = 140

    var body: some View {
        Section {
            Picker("Open files in", selection: $editors.choiceID) {
                ForEach(editors.installed) { Text($0.name).tag($0.id) }
                if !editors.installed.isEmpty { Divider() }
                Text("Each File's Default App").tag(ExternalEditor.defaultApp)
                // A pick that's since been uninstalled.
                if !editors.choiceID.isEmpty, editors.editor == nil {
                    Text("Default App (editor not found)").tag(editors.choiceID)
                }
            }
        } header: {
            Text("Editor")
        } footer: {
            Text("Files open in the editor's window for their project, with its sidebar, search and language tools, rather than on their own.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { editors.refresh() }
    }
}

/// A page header's open button: in the editor when one is picked, at the
/// line in view (right-click for the default app), else the default app.
/// ⇧⌘O (File ▸ Open in …) does the same. Hovering it slides out the other
/// installed editors, to open this file in one of them instead.
struct OpenExternallyButton: View {
    let file: URL
    let project: String?
    let detail: String
    @ObservedObject private var editors = ExternalEditor.shared

    private static let size = CGSize(width: 32, height: 24)

    var body: some View {
        let others = editors.installed.filter { $0 != editors.editor }
        HoverRevealButtons(count: others.count, size: Self.size) {
            ForEach(others) { editor in
                EditorIconButton(editor: editor, tooltip: Tooltip(title: "Open in \(editor.name)", detail: detail), size: Self.size) {
                    editors.open(file, project: project, line: ShownCode.line(), textOnly: true, in: editor)
                }
            }
        } main: {
            Group {
                if let editor = editors.editor {
                    EditorIconButton(editor: editor, tooltip: Tooltip(title: "Open in \(editor.name)", shortcut: "⇧⌘O", detail: detail),
                                     size: Self.size) {
                        editors.open(file, project: project, line: ShownCode.line(), textOnly: true)
                    }
                } else {
                    BarIconButton(symbol: "arrow.up.forward.app",
                                  tooltip: Tooltip(title: "Open in Default App", shortcut: "⇧⌘O", detail: detail)) {
                        editors.open(file, project: project, line: ShownCode.line(), textOnly: true)
                    }
                }
            }
            .contextMenu {
                OpenInEditorButton(file: file, project: project, line: ShownCode.line())
                Button("Open in Default App") { NSWorkspace.shared.open(file) }
            }
        }
    }
}

/// An editor's own app icon as a bar button: gray at rest so the bar stays
/// quiet, in its colors under the pointer.
private struct EditorIconButton: View {
    let editor: ExternalEditor.Editor
    let tooltip: Tooltip
    let size: CGSize
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Group {
                if let app = editor.app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                }
            }
            .frame(width: 18, height: 18)
            .saturation(hovering && enabled ? 1 : 0)
            .opacity(!enabled ? 0.3 : hovering ? 1 : 0.7)
            .frame(width: size.width, height: size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering && enabled))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip(tooltip)
        .accessibilityLabel(tooltip.title)
    }
}

/// "Open in VS Code" for a workspace's context menu, when an editor is
/// picked: its folder as a project.
struct OpenFolderInEditorButton: View {
    let folder: String
    @ObservedObject private var editors = ExternalEditor.shared

    var body: some View {
        if let editor = editors.editor {
            Button("Open in \(editor.name)") { editors.openFolder(folder) }
        }
    }
}

/// A folder's two "Open in …" items, when an editor is picked: in the
/// workspace's project window (showing a file from it), or as a project of
/// its own (a package in a monorepo).
struct OpenSubfolderInEditorButtons: View {
    let folder: String
    let project: String
    @ObservedObject private var editors = ExternalEditor.shared

    var body: some View {
        if let editor = editors.editor {
            Button("Open in \(editor.name)") { editors.openFolder(folder, inProject: project) }
            Button("Open Folder as Project in \(editor.name)") { editors.openFolder(folder) }
        }
    }
}

// MARK: - The line in view

/// The code page on screen (a file's lines or a diff), so "Open in …"
/// can open the editor at the same place: the first selected line; or,
/// with nothing selected, the first change at or below the top of the
/// page (a diff), else the top line.
@MainActor
enum ShownCode {
    private static weak var text: NSTextView?

    /// A code page's text view, as it's made (the newest is the one shown).
    static func register(_ view: NSTextView) { text = view }

    /// The line in the file (its new numbering) to open at, when a code
    /// page is on screen.
    static func line() -> Int? {
        guard let text, text.window != nil, let storage = text.textStorage, storage.length > 0,
              let layout = text.layoutManager, let container = text.textContainer else { return nil }
        let selected = text.selectedRange()
        let start: Int
        if selected.length > 0 {
            start = selected.location
        } else {
            let top = NSPoint(x: 0, y: max(0, text.visibleRect.minY - text.textContainerOrigin.y) + 1)
            start = layout.characterIndexForGlyph(at: layout.glyphIndex(for: top, in: container))
        }
        // Each line carries its numbers (`DiffLineInfo`); walk down from
        // the start.
        var firstNumbered: Int?
        var pendingRemoved = false
        var i = min(start, storage.length - 1)
        while i < storage.length {
            var range = NSRange()
            let info = storage.attribute(.diffLine, at: i, effectiveRange: &range) as? DiffLineInfo
            i = max(NSMaxRange(range), i + 1)
            guard let info else { continue }
            if selected.length > 0, let n = info.new { return n }
            if firstNumbered == nil { firstNumbered = info.new }
            switch info.kind {
            case .added: return info.new
            case .removed: pendingRemoved = true  // the line after it is where it was
            case .context where pendingRemoved: return info.new
            default: break
            }
        }
        return firstNumbered
    }
}
