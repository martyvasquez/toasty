import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files widget
//
// The workspace's folder, browsed in place. Large only: a list needs the
// room. Everything it needs is here; the rest of the app knows it by
// `WidgetKind.files` (the gallery, its size limits, `WidgetContent`).
//
// - Summary line: where you are, as a path you can click back up, and the
//   hidden-files toggle.
// - The list: folders first, then files, by name. A folder opens in place;
//   a file shows in the conversation column (`FilePage`). Trailing: git's change letter (a dot on a
//   folder that holds changes) and when it last changed, so what Claude
//   just touched stands out. Git-ignored items are quiet.
// - Right-click: Open, Open in <Editor> (Settings ▸ General ▸ Editor; a folder
//   in the project's window, or as its own project), Open in Default App, Show in Finder, Show Diff (changed files), Mention
//   in Conversation, Copy Path. Rows drag out as files (to the composer,
//   the Finder, a terminal).
//
// It never leaves the workspace's folder, and follows the folder live.

struct FilesWidget: View {
    @ObservedObject var workspace: Workspace
    let item: WidgetItem
    @Environment(\.widgetPreview) private var preview

    var body: some View {
        if preview {
            FilesPreview(workspace: workspace)
        } else {
            FilesWidgetBody(workspace: workspace, changes: workspace.changes,
                            browser: FilesBrowsers.shared.browser(for: item.id, in: workspace))
        }
    }
}

/// The gallery's: a browser of its own, at the folder's top.
private struct FilesPreview: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var browser: FilesBrowser

    init(workspace: Workspace) {
        self.workspace = workspace
        _browser = StateObject(wrappedValue: FilesBrowser(root: workspace.folder))
    }

    var body: some View {
        FilesWidgetBody(workspace: workspace, changes: workspace.changes, browser: browser)
    }
}

private struct FilesWidgetBody: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var changes: GitChanges
    @ObservedObject var browser: FilesBrowser
    @AppStorage("filesWidget.showHidden") private var showHidden = false
    /// The list's height as laid out, for Fit.
    @State private var listHeight: CGFloat?
    @Environment(\.widget) private var widget

    /// Fit: header, path line and the folder's rows; a message's two rows.
    private var fit: CGFloat? {
        guard let units = widget?.units else { return nil }
        let size = WidgetSize(span: 2, units: units)
        let path = SummaryLine<EmptyView>.height
        switch browser.state {
        case .loading, .missing: return size.fitHeight(count: 0, above: path)
        case .loaded where browser.entries.isEmpty: return size.fitHeight(count: 0, above: path)
        case .loaded: return size.fitHeight(content: listHeight, above: path)
            ?? size.fitHeight(count: browser.entries.count, above: path)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(kind: .files) {
                if browser.state == .loaded {
                    Text(browser.entries.count == 1 ? "1 item" : "\(browser.entries.count) items")
                        .font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            // The summary line: where you are, and the one control.
            HStack(spacing: Theme.Space.s) {
                FilesPath(browser: browser)
                    // The crumbs' hover pads sit outside the text's edge.
                    .padding(.leading, -CrumbButton.pad)
                Spacer(minLength: Theme.Space.xs)
                InspectorControl(symbol: showHidden ? "eye" : "eye.slash",
                                 tooltip: Tooltip(title: showHidden ? "Hide Hidden Files" : "Show Hidden Files",
                                                  detail: "Files whose names start with a dot.")) {
                    showHidden.toggle()
                }
            }
            .padding(.horizontal, Theme.Widget.edge)
            .frame(height: SummaryLine<EmptyView>.height)
            list
        }
        .reportsFit(fit, workspace: workspace.id)
        .onAppear { browser.showHidden = showHidden }
        .onChange(of: showHidden) { _, on in browser.showHidden = on }
        .onChange(of: workspace.folder) { _, folder in browser.setRoot(folder) }
        // Kept current while it's on screen: a folder's own changes come
        // straight from the file system; edits inside files (their times,
        // git's letters) every few seconds.
        .task(id: workspace.folder) {
            changes.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if NSApp.isActive {
                    browser.reload()
                    changes.refresh()
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        switch browser.state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            EmptyLine(text: "Folder not found")
        case .loaded where browser.entries.isEmpty:
            EmptyLine(text: "Empty folder")
        case .loaded:
            let marks = GitMarks(changes: changes)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(browser.entries) { entry in
                        FileRow(workspace: workspace, browser: browser, entry: entry,
                                change: marks.status(of: entry), holdsChanges: entry.isFolder && marks.holdsChanges(entry))
                    }
                }
                .padding(.bottom, Theme.Space.s)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .id(browser.path)
            .transition(.opacity)
        }
    }
}

/// Where the browser is: the workspace's folder, then each folder in, each
/// a click back up. A deep path keeps its ends: root › … › parent › here.
private struct FilesPath: View {
    @ObservedObject var browser: FilesBrowser

    var body: some View {
        let crumbs = browser.crumbs
        let shown: [FilesBrowser.Crumb?] = crumbs.count > 4
            ? [crumbs[0], nil] + crumbs.suffix(2)
            : crumbs
        HStack(spacing: Theme.Space.xxs) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, crumb in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.toasty(Theme.Glyph.small - 1, .semibold))
                        .foregroundStyle(.tertiary)
                }
                if let crumb {
                    CrumbButton(title: crumb.title, current: crumb.path == browser.path) { browser.open(crumb.path) }
                } else {
                    // The folders left out: one click up past them.
                    CrumbButton(title: "…", current: false) { browser.open(crumbs[crumbs.count - 3].path) }
                        .tooltipText(crumbs[1..<(crumbs.count - 2)].map(\.title).joined(separator: " / "))
                }
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([browser.url]) }
            Button("Copy Path") { FileRow.copy(browser.url.path) }
        }
    }
}

private struct CrumbButton: View {
    let title: String
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    static let pad = Theme.Space.xxs + 1

    var body: some View {
        Button { if !current { action() } } label: {
            Text(title)
                .font(.toasty(Theme.Size.meta, current ? .medium : .regular))
                .foregroundStyle(current ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Self.pad)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(hovering && !current ? Theme.Fill.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .layoutPriority(current ? 1 : 0)
    }
}

/// A file or folder: its glyph and name; git's letter (or, on a folder, a
/// dot for changes inside) and when it last changed.
private struct FileRow: View {
    @ObservedObject var workspace: Workspace
    let browser: FilesBrowser
    let entry: FilesBrowser.Entry
    let change: GitChanges.File?
    let holdsChanges: Bool

    var body: some View {
        let viewing = !entry.isFolder && workspace.viewedFile?.standardizedFileURL == entry.url
        WidgetRow(label: entry.name, quiet: entry.ignored, truncation: .middle, action: { open(toggle: true) }) {
            RowGlyph(symbol: entry.isFolder ? "folder" : "doc")
        } trailing: {
            HStack(spacing: Theme.Space.s) {
                if let change {
                    ChangeLetter(status: change.status)
                } else if holdsChanges {
                    Circle().fill(Color.secondary).frame(width: 5, height: 5)
                        .accessibilityLabel("Has changes")
                }
                if let modified = entry.modified {
                    RowValue(text: Self.age(modified))
                        .frame(minWidth: 28, alignment: .trailing)
                }
                if entry.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.toasty(Theme.Glyph.small, .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(viewing ? Theme.Fill.selected : Color.clear)
            .padding(.horizontal, Theme.Widget.rowInset))
        .tooltipText(tooltip)
        .onDrag { NSItemProvider(object: entry.url as NSURL) }
        .contextMenu { menu }
    }

    /// A folder opens in place; a file shows in the conversation column
    /// (a second click puts the conversation back).
    private func open(toggle: Bool = false) {
        if entry.isFolder {
            browser.open(entry.url.path)
        } else if toggle, workspace.viewedFile?.standardizedFileURL == entry.url {
            workspace.viewedFile = nil
        } else {
            workspace.viewedFile = entry.url
        }
    }

    private var tooltip: String {
        var lines = [browser.relative(entry.url.path)]
        if let change { lines.append(change.status.label) }
        if entry.ignored { lines.append("Ignored by git") }
        if let modified = entry.modified {
            lines.append("Modified " + modified.formatted(date: .abbreviated, time: .shortened))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { open() }
        if entry.isFolder {
            OpenSubfolderInEditorButtons(folder: entry.url.path, project: workspace.folder)
        } else {
            OpenInEditorButton(file: entry.url, project: workspace.folder)
            Button("Open in Default App") { NSWorkspace.shared.open(entry.url) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        if let change, change.status != .deleted {
            let shown = workspace.diffFile?.id == change.id
            Button(shown ? "Hide Diff" : "Show Diff") { workspace.diffFile = shown ? nil : change }
        }
        Divider()
        Button("Mention in Conversation") { mention() }
            .disabled(workspace.selected == nil)
        Button("Copy Path") { Self.copy(entry.url.path) }
        Button("Copy Relative Path") { Self.copy(browser.relative(entry.url.path)) }
    }

    private func mention() { workspace.mention(entry.url, isFolder: entry.isFolder) }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// How long ago, in the fewest characters: "now", "4m", "2h", "3d",
    /// then the date ("Oct 4"; with the year when it isn't this one).
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(7 * 86_400): return "\(Int(s / 86_400))d"
        default:
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            return sameYear ? date.formatted(.dateTime.month(.abbreviated).day())
                : date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }
}

/// Git's uncommitted files, by absolute path, for the rows' letters.
private struct GitMarks {
    private let files: [String: GitChanges.File]
    private let paths: [String]

    init(changes: GitChanges) {
        let live = changes.state == .loaded ? changes.files.filter { $0.status != .deleted } : []
        files = Dictionary(live.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        paths = changes.state == .loaded ? changes.files.map(\.url.path) : []
    }

    func status(of entry: FilesBrowser.Entry) -> GitChanges.File? {
        entry.isFolder ? nil : files[entry.url.path]
    }

    func holdsChanges(_ entry: FilesBrowser.Entry) -> Bool {
        let prefix = entry.url.path + "/"
        return paths.contains { $0.hasPrefix(prefix) }
    }
}

// MARK: - Model

/// One folder at a time, inside `root`: its entries, kept current by
/// watching the folder (and `reload()` for times inside files).
@MainActor
final class FilesBrowser: ObservableObject {
    nonisolated struct Entry: Identifiable, Equatable {
        let url: URL
        let name: String
        let isFolder: Bool
        let modified: Date?
        var ignored = false
        var id: String { url.path }
    }

    struct Crumb {
        let title: String
        let path: String
    }

    enum State { case loading, loaded, missing }

    @Published private(set) var root: String
    @Published private(set) var path: String
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var state = State.loading
    var showHidden = false {
        didSet { if showHidden != oldValue { reload() } }
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var generation = 0

    init(root: String) {
        self.root = root
        path = root
        open(root)
    }

    deinit { watcher?.cancel() }

    var url: URL { URL(fileURLWithPath: path) }

    /// The workspace's folder, then each folder down to here.
    var crumbs: [Crumb] {
        var out = [Crumb(title: (root as NSString).lastPathComponent, path: root)]
        var p = root
        for part in relative(path).split(separator: "/") where !relative(path).isEmpty {
            p = (p as NSString).appendingPathComponent(String(part))
            out.append(Crumb(title: String(part), path: p))
        }
        return out
    }

    /// `p` from the workspace's folder ("" for the folder itself).
    func relative(_ p: String) -> String {
        if p == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
    }

    func setRoot(_ folder: String) {
        guard folder != root else { return }
        root = folder
        open(folder)
    }

    /// Go to a folder inside the root (anything else goes to the root).
    func open(_ folder: String) {
        let inside = folder == root || folder.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        let target = inside ? folder : root
        if target != path {
            path = target
            entries = []
            state = .loading
        }
        watch(target)
        reload()
    }

    /// Read the folder again. A folder that's gone sends the browser up to
    /// the nearest one that's still there.
    func reload() {
        generation += 1
        let gen = generation, folder = path, hidden = showHidden
        Task.detached(priority: .userInitiated) {
            let listed = Self.list(folder, hidden: hidden)
            await MainActor.run {
                guard gen == self.generation, folder == self.path else { return }
                guard let listed else {
                    if folder != self.root {
                        self.open((folder as NSString).deletingLastPathComponent)
                    } else {
                        self.entries = []
                        self.state = .missing
                    }
                    return
                }
                // Keep the ignored marks from the last read until git answers.
                let ignored = Set(self.entries.filter(\.ignored).map(\.id))
                let merged = listed.map { e in var e = e; e.ignored = ignored.contains(e.id); return e }
                if merged != self.entries { self.entries = merged }
                if self.state != .loaded { self.state = .loaded }
                self.markIgnored(gen: gen, folder: folder, entries: listed)
            }
        }
    }

    /// Which entries git ignores (quiet rows); none outside a repository.
    private func markIgnored(gen: Int, folder: String, entries: [Entry]) {
        guard !entries.isEmpty else { return }
        let names = entries.prefix(2000).map(\.name)
        Task.detached(priority: .utility) {
            let r = GitChanges.git(["check-ignore", "--"] + names, in: folder, timeout: 10)
            let ignored = Set(r.text.split(separator: "\n").map { ((folder as NSString).appendingPathComponent(String($0))) })
            await MainActor.run {
                guard gen == self.generation, folder == self.path else { return }
                let marked = self.entries.map { e in var e = e; e.ignored = ignored.contains(e.id); return e }
                if marked != self.entries { self.entries = marked }
            }
        }
    }

    /// Folders first, then files, each by name as the Finder sorts them.
    /// nil when the folder can't be read.
    nonisolated private static func list(_ folder: String, hidden: Bool) -> [Entry]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
            options: hidden ? [] : [.skipsHiddenFiles]) else { return nil }
        let entries = urls.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            if name == ".git" || name == ".DS_Store" { return nil }
            let v = try? url.resourceValues(forKeys: Set(keys))
            // A package (an app, a bundle) opens as a file.
            let folder = v?.isDirectory == true && v?.isPackage != true
            return Entry(url: url.standardizedFileURL, name: name, isFolder: folder, modified: v?.contentModificationDate)
        }
        return entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Entries added, removed or renamed in the folder show at once.
    private func watch(_ folder: String) {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(folder, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Stop watching (the widget was removed, or its workspace closed).
    func stop() {
        watcher?.cancel()
        watcher = nil
    }
}

/// Every files widget's browser, by workspace and widget, so a widget keeps
/// its place across spaces. A removed widget's (or a closed workspace's)
/// browser stops watching.
@MainActor
final class FilesBrowsers {
    static let shared = FilesBrowsers()

    private struct Key: Hashable {
        let workspace: UUID
        let widget: UUID
    }

    private var all: [Key: FilesBrowser] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let store = WorkspaceStore.shared
        store.$spaces
            .combineLatest(store.$workspaces)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces, workspaces in self?.prune(spaces: spaces, workspaces: workspaces) }
            .store(in: &cancellables)
    }

    func browser(for widget: UUID, in workspace: Workspace) -> FilesBrowser {
        let key = Key(workspace: workspace.id, widget: widget)
        if let b = all[key] { return b }
        let b = FilesBrowser(root: workspace.folder)
        all[key] = b
        return b
    }

    private func prune(spaces: [WidgetSpace], workspaces: [Workspace]) {
        let widgets = Set(spaces.flatMap(\.widgets).filter { $0.kind == .files }.map(\.id))
        let open = Set(workspaces.map(\.id))
        for (key, b) in all where !widgets.contains(key.widget) || !open.contains(key.workspace) {
            all[key] = nil
            b.stop()
        }
    }
}
