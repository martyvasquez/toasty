import AppKit

// MARK: - Handing a file to a JetBrains IDE that's already running
//
// WHY: Toasty opens files in a JetBrains IDE (PhpStorm, WebStorm, IntelliJ…)
// with `open -na <app> --args <project> --line N <file>` (ExternalEditor's
// `launch`). `-n` starts a second copy of the IDE, which is meant to pass
// the request to the running one and quit. When the running one doesn't
// answer in time (busy indexing, a dialog open, stuck), the second copy
// shows "Start Failed: CannotActivateException … is still running and does
// not respond" (reported with PhpStorm, 2026-11-28).
//
// WHAT: when the IDE is already running AND the file's project is already
// open in it, Toasty skips the second copy and sends the running IDE a URL,
// `<scheme>://open?file=<path>&line=N`, through macOS (as a link click
// would). Every JetBrains IDE on macOS declares a URL scheme in its
// Info.plist and handles `open?file=` itself: the file opens in the project
// window that holds it, at the line (intellij-community:
// MacOSApplicationProvider.kt `protocolCommand` → CommandLineProcessor.kt
// `processInternalProtocol`). A busy IDE just handles it late; there's no
// second copy to fail.
//
// Only when the project is open: for a file outside the open projects the
// IDE doesn't open its project, it puts the file in the last window used
// (CommandLineProcessor `findBestProject`). So the IDE's list of open
// projects is read from its recentProjects.xml (`opened="true"` entries,
// written when the IDE saves its settings, e.g. when you switch away from
// it). Anything not found or not certain (IDE not running, no URL scheme,
// settings elsewhere, project not open) returns false, and Toasty does
// what it did before: `open -na`.
//
// TO UNDO: delete this file and the one call to `JetBrainsHandoff.open` in
// ExternalEditor.swift's `launch` (the `.jetbrains` case).

enum JetBrainsHandoff {
    /// Send `file` (at `line`), or the project folder `root` itself when
    /// `file` is nil, to the running IDE with this bundle ID, if its project
    /// is open there. False: nothing was sent; launch it the usual way.
    @MainActor
    static func open(bundleID: String, root: String, file: String?, line: Int?) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }),
              let app = running.bundleURL,
              let scheme = urlScheme(of: app),
              let open = openProjects(of: app)
        else { return false }
        let target = file ?? root
        guard open.contains(where: { contains($0, target) }) else { return false }

        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "open"
        // The IDE decodes the query as a form: "+" would read as a space.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        var query = "file=" + (target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target)
        if file != nil, let line { query += "&line=\(line)" }
        parts.percentEncodedQuery = query
        guard let url = parts.url else { return false }

        // To this copy of the IDE, not whichever app macOS picks for the scheme.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        return true
    }

    /// The IDE's URL scheme (e.g. "phpstorm"), from its Info.plist.
    private static func urlScheme(of app: URL) -> String? {
        let types = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return types?.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
    }

    /// The folders of the projects open in the IDE, from
    /// ~/Library/Application Support/JetBrains/<dataDirectoryName>/options/recentProjects.xml
    /// (the directory name is in the app's product-info.json). Nil when
    /// either can't be read.
    private static func openProjects(of app: URL) -> [String]? {
        let info = app.appendingPathComponent("Contents/Resources/product-info.json")
        guard let data = try? Data(contentsOf: info),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dir = json["dataDirectoryName"] as? String,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let file = support.appendingPathComponent("JetBrains/\(dir)/options/recentProjects.xml")
        guard let xml = try? XMLDocument(contentsOf: file),
              let keys = try? xml.nodes(forXPath: "//entry[value/RecentProjectMetaInfo[@opened='true']]/@key")
        else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return keys.compactMap { $0.stringValue?.replacingOccurrences(of: "$USER_HOME$", with: home) }
    }

    /// Whether `path` is the folder `project` or inside it (by real path).
    private static func contains(_ project: String, _ path: String) -> Bool {
        let p = URL(fileURLWithPath: project).resolvingSymlinksInPath().path
        let t = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return t == p || t.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }
}
