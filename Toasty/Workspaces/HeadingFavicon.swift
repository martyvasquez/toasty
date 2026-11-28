import AppKit

// MARK: - A heading's website icon
//
// A heading can show a website's icon in place of its symbol: in its style
// picker, type the site ("example.com" or a full URL) and Toasty fetches the
// site's icon once, keeps it as a 64px PNG in Application Support/<app>/
// HeadingIcons/<heading id>.png, and draws it from there (the sidebar never
// waits on the network). The heading remembers the site (`site`); choosing
// a symbol again goes back to the symbol.

enum HeadingFavicon {
    enum Failure: LocalizedError {
        case badAddress, noIcon
        var errorDescription: String? {
            switch self {
            case .badAddress: "That doesn't look like a web address."
            case .noIcon: "Couldn't find an icon for that site."
            }
        }
    }

    /// The site as typed, as a URL ("example.com" → https://example.com).
    static func siteURL(_ input: String) -> URL? {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t), let host = url.host, host.contains("."),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// The site's icon as a 64px PNG: the largest icon its page declares
    /// (apple-touch-icon, then icon links by size), else /favicon.ico.
    static func fetch(_ site: URL) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        var candidates: [URL] = []
        var base = site
        if let (html, final) = try? await page(site, session: session) {
            base = final
            candidates = links(in: html, base: final)
        }
        if let root = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL { candidates.append(root) }
        for url in candidates {
            guard let data = try? await get(url, session: session).0, let png = png(from: data) else { continue }
            return png
        }
        throw Failure.noIcon
    }

    private static func get(_ url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        // Some sites turn away requests that don't look like a browser's.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    /// The page's HTML (its head is enough) and where it ended up after
    /// redirects.
    private static func page(_ url: URL, session: URLSession) async throws -> (String, URL) {
        let (data, response) = try await get(url, session: session)
        let html = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
        return (html, response.url ?? url)
    }

    /// The icons a page's <link> tags declare, best first.
    static func links(in html: String, base: URL) -> [URL] {
        let tag = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
        func attribute(_ name: String, in s: String) -> String? {
            let re = try! NSRegularExpression(pattern: #"\b"# + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                                              options: [.caseInsensitive])
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            for i in 1...3 { if let r = Range(m.range(at: i), in: s) { return String(s[r]) } }
            return nil
        }
        var found: [(url: URL, score: Int)] = []
        let ns = html as NSString
        for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let link = ns.substring(with: m.range)
            guard let rel = attribute("rel", in: link)?.lowercased(),
                  rel.split(separator: " ").contains(where: { $0 == "icon" || $0.hasPrefix("apple-touch-icon") }),
                  let href = attribute("href", in: link)?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            // Bigger is crisper; an apple-touch-icon is 180 unless it says.
            let sizes = attribute("sizes", in: link)?.lowercased() ?? ""
            var size = sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 0
            if size == 0 { size = rel.contains("apple-touch-icon") ? 180 : 32 }
            if sizes == "any" || url.pathExtension.lowercased() == "svg" { size = 256 }
            found.append((url, size))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    /// Any image data (PNG, ICO, SVG…) as a 64px square PNG, or nil if it
    /// isn't an image.
    static func png(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              image.representations.contains(where: { $0.pixelsWide > 0 || $0 is NSPDFImageRep || $0.className.contains("SVG") })
        else { return nil }
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let s = image.size, scale = CGFloat(side) / max(s.width, s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// An icon drawn on a see-through background, by how its own ink reads:
/// a black logo vanishes on the dark sidebar, a white one on the light.
enum IconTone { case dark, light, other }

/// The headings' fetched icons, from disk.
@MainActor
final class HeadingIcons: ObservableObject {
    static let shared = HeadingIcons()

    @Published private var images: [UUID: NSImage] = [:]
    private var tones: [UUID: IconTone] = [:]
    private var missing: Set<UUID> = []

    /// Whether the icon needs a tile behind it to show (see `IconTone`).
    func tone(for id: UUID) -> IconTone {
        if let t = tones[id] { return t }
        guard let image = image(for: id) else { return .other }
        let t = Self.tone(of: image)
        tones[id] = t
        return t
    }

    /// Mostly see-through (a logo, not a filled square) and its ink all
    /// dark or all light.
    nonisolated static func tone(of image: NSImage) -> IconTone {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .other }
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .other }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var clear = 0, ink = 0, lum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            if a < 0.5 { clear += 1; continue }
            ink += 1
            lum += (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255 / a
        }
        guard ink > 0, Double(clear) / Double(side * side) > 0.25 else { return .other }
        let mean = lum / Double(ink)
        return mean < 0.3 ? .dark : mean > 0.85 ? .light : .other
    }

    static var folder: URL {
        WorkspaceStore.stateURL.deletingLastPathComponent().appendingPathComponent("HeadingIcons", isDirectory: true)
    }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    func image(for id: UUID) -> NSImage? {
        if let image = images[id] { return image }
        guard !missing.contains(id) else { return nil }
        if let image = NSImage(contentsOf: Self.file(id)) {
            images[id] = image
            return image
        }
        missing.insert(id)
        return nil
    }

    func set(_ png: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try png.write(to: Self.file(id), options: .atomic)
        missing.remove(id)
        tones[id] = nil
        images[id] = NSImage(data: png)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.file(id))
        images[id] = nil
        tones[id] = nil
        missing.remove(id)
    }
}
