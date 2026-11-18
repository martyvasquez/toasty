import AppKit

/// A prompt written ahead of time, with its pictures and files: one row of
/// a workspace's Tee-Up list (the inspector's Tee-Up tab). Sending it posts
/// it to the open tab and takes it off the list.
struct TeeUp: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    /// Pictures, by file name in `TeeUpImages.folder`.
    var images: [String] = []
    /// Other files, by path: Claude reads them itself.
    var files: [String] = []
    /// Skipped by Auto-Send: it waits to be sent by hand. (Optional, so
    /// lists saved before it existed still load.)
    var held: Bool?

    var isHeld: Bool { held == true }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && files.isEmpty
    }

    /// Attach files from the picker, a drop or a paste: images are kept as
    /// pictures, anything else by path (like the composer).
    mutating func attach(_ urls: [URL]) {
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url),
               let name = TeeUpImages.store(image) {
                images.append(name)
            } else if !files.contains(url.path) {
                files.append(url.path)
            }
        }
    }

    mutating func attach(_ image: NSImage) {
        if let name = TeeUpImages.store(image) { images.append(name) }
    }
}

/// The pictures of teed-up prompts: PNG files beside state.json, so a
/// pasted screenshot is still there after a relaunch.
enum TeeUpImages {
    static var folder: URL {
        WorkspaceStore.stateURL.deletingLastPathComponent().appendingPathComponent("TeeUps", isDirectory: true)
    }

    private static var cache: [String: NSImage] = [:]

    /// Save a picture; returns its file name.
    static func store(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            NSLog("Toasty: couldn't save a teed-up picture: \(error)")
            return nil
        }
        cache[name] = image
        return name
    }

    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        let image = NSImage(contentsOf: folder.appendingPathComponent(name))
        cache[name] = image
        return image
    }

    static func delete(_ names: [String]) {
        for name in names {
            cache[name] = nil
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Delete pictures no list has any more (an edit abandoned by quitting,
    /// a closed workspace).
    static func sweep(keeping names: Set<String>) {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        delete(found.filter { !names.contains($0) })
    }
}
