import AppKit

/// Finder > Services > "New Toasty Tab Here": a new tab in the folder's
/// workspace, or a new workspace for it (the same as opening the folder
/// with Toasty).
final class ServiceProvider: NSObject {
    @objc func openTab(_ pasteboard: NSPasteboard, userData: String?,
                       error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No folder was selected."
            return
        }
        AppDelegate.shared.openFolders(urls)
    }
}
