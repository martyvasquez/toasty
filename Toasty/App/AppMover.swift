import AppKit

// MARK: - Running from Applications
//
// Sparkle can't update a Toasty that runs where it was downloaded: opened
// from Downloads (or the disk image), macOS runs a read-only copy of it
// somewhere hidden (App Translocation), and an update has nothing it can
// replace. So at launch, before anything else, a Toasty outside an
// Applications folder asks to move there: Move to Applications copies it
// in (replacing an older copy), clears the download flag that sends it to
// the hidden copy, puts the downloaded one in the Trash and opens the moved
// one. Like the setup check there's no skip; Quit is the other way out.
// Debug builds never ask (they run from the build folder).

@MainActor
enum AppMover {
    /// Asks, and moves, when Toasty isn't in Applications. True when this
    /// launch should stop here (Toasty is quitting, to open again from
    /// Applications or because the user chose Quit).
    static func checkAtLaunch() -> Bool {
        #if DEBUG
        // Debug only: TOASTY_MOVER_TEST_DEST=<folder> moves this build there
        // as if it were Applications (TOASTY_MOVER_AUTO=1: without asking).
        let env = ProcessInfo.processInfo.environment
        guard let test = env["TOASTY_MOVER_TEST_DEST"] else { return false }
        let folder = URL(fileURLWithPath: test)
        let ask = env["TOASTY_MOVER_AUTO"] == nil
        #else
        guard !isInApplications(Bundle.main.bundleURL) else { return false }
        let folder = applicationsFolder()
        let ask = true
        #endif
        let source = originalLocation(of: Bundle.main.bundleURL)
        if ask {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Move Toasty to your Applications folder?"
            alert.informativeText = "Toasty can only update itself from the Applications folder. It moves there and opens again."
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Quit Toasty")
            guard alert.runModal() == .alertFirstButtonReturn else {
                NSApp.terminate(nil)
                return true
            }
        }
        do {
            let moved = try move(source, into: folder)
            relaunch(moved)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Toasty couldn't move itself"
            alert.informativeText = "\(error.localizedDescription)\n\nDrag Toasty into your Applications folder in the Finder, then open it from there."
            alert.addButton(withTitle: "Show Toasty in Finder")
            alert.addButton(withTitle: "Quit Toasty")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([source])
            }
            NSApp.terminate(nil)
        }
        return true
    }

    /// In /Applications or ~/Applications (or a folder in them), and not
    /// a translocated copy.
    nonisolated static func isInApplications(_ bundle: URL) -> Bool {
        let path = bundle.resolvingSymlinksInPath().path
        guard !path.contains("/AppTranslocation/") else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// /Applications when it can be written to (an admin user), else the
    /// user's own ~/Applications.
    private static func applicationsFolder() -> URL {
        let system = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let own = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        return own
    }

    /// Where the app really is: a translocated copy's original (the one in
    /// Downloads), else itself.
    private static func originalLocation(of bundle: URL) -> URL {
        guard bundle.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return bundle }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(bundle as CFURL, nil).map { $0.takeRetainedValue() as URL } ?? bundle
    }

    /// Copy into `folder` (an older Toasty there goes to the Trash), clear
    /// the download flag, and trash the downloaded copy when it can be.
    private static func move(_ source: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }) {
                throw NSError(domain: "Toasty", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Another Toasty is open from \(folder.path). Quit it first."])
            }
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", destination.path]
        try? xattr.run()
        xattr.waitUntilExit()
        // Not the disk image's (read-only), only a downloaded copy.
        if !source.path.hasPrefix("/Volumes/") { try? fm.trashItem(at: source, resultingItemURL: nil) }
        return destination
    }

    /// Quit, and open the moved copy once this one has gone (so the two
    /// never run at once).
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }
}
