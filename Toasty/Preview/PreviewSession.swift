import AppKit
import Combine
import WebKit

/// The size a page is shown at.
enum PreviewViewport: String, CaseIterable, Identifiable {
    case mobile, desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mobile: "Phone"
        case .desktop: "Desktop"
        }
    }

    var symbol: String {
        switch self {
        case .mobile: "iphone"
        case .desktop: "desktopcomputer"
        }
    }

    /// The page's size when the pane has room (and when it isn't on screen).
    var nominal: CGSize {
        switch self {
        case .mobile: CGSize(width: 390, height: 844)
        case .desktop: CGSize(width: 1280, height: 800)
        }
    }

    /// A phone's Safari, so sites that sniff the user agent serve their
    /// mobile pages; nil for the web view's own (desktop Safari).
    var userAgent: String? {
        switch self {
        case .mobile: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        case .desktop: nil
        }
    }

    /// Where the page sits in a pane, and the size it's laid out at.
    struct Fit: Equatable {
        /// The page as drawn, in the pane.
        let display: CGRect
        /// The page's own size (CSS pixels): what the site sees.
        let page: CGSize
        var scale: CGFloat { page.width > 0 ? display.width / page.width : 1 }
    }

    /// The page is always laid out at its real width and drawn smaller when
    /// the pane is narrower, so a desktop page stays a desktop page in a
    /// narrow sidebar. A phone is centered and at most 844 tall; a desktop
    /// fills the pane once the pane is 1280 wide.
    func fit(in pane: CGSize) -> Fit {
        guard pane.width > 1, pane.height > 1 else { return Fit(display: .zero, page: nominal) }
        let width = nominal.width
        let scale = min(1, pane.width / width)
        switch self {
        case .mobile:
            let height = min(nominal.height, pane.height / scale)
            return Fit(display: CGRect(x: ((pane.width - width * scale) / 2).rounded(), y: 0,
                                       width: width * scale, height: height * scale),
                       page: CGSize(width: width, height: height))
        case .desktop:
            // Drawn smaller, it fills the pane's height but is never taller
            // than it is wide: in a narrow pane it would otherwise be
            // thousands of pixels tall, which no screen is (and `100vh`
            // layouts would show it).
            let height = scale < 1 ? min(width, pane.height / scale) : pane.height
            return Fit(display: CGRect(x: 0, y: 0, width: pane.width, height: height * scale),
                       page: CGSize(width: pane.width / scale, height: height))
        }
    }
}

/// One workspace's preview: its page, console and comments. The web view is
/// made the first time the preview is used and kept while the workspace is
/// open, on screen or not.
@MainActor
final class PreviewSession: NSObject, ObservableObject {
    struct ConsoleEntry: Identifiable {
        let id = UUID()
        let level: String
        let text: String
    }

    struct Failure: Equatable {
        let address: String
        let reason: String
    }

    /// Something picked in the page to comment on.
    struct Pick: Hashable {
        enum Kind: String { case element, area }
        let kind: Kind
        let selector: String
        let text: String
        /// In the page's own coordinates (CSS pixels from its top-left).
        let rect: CGRect
        let viewport: CGSize
        let url: String
    }

    let workspaceID: UUID
    /// The address field's text.
    @Published var address: String
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failure: Failure?
    @Published private(set) var viewport: PreviewViewport
    @Published private(set) var console: [ConsoleEntry] = []
    @Published private(set) var commenting = false
    @Published private(set) var pick: Pick?
    /// A page has been asked for (the start screen is over).
    @Published private(set) var started = false

    private(set) var webView: WKWebView?
    /// The view showing the page, while the pane is on screen.
    weak var stage: PreviewStage?
    private var observers: Set<AnyCancellable> = []
    private var loadWaiters: [(String?) -> Void] = []
    private static let world = WKContentWorld.world(name: "ToastyPreview")
    private static let consoleLimit = 500

    init(workspaceID: UUID, address: String, viewport: PreviewViewport) {
        self.workspaceID = workspaceID
        self.address = address
        self.viewport = viewport
    }

    // MARK: Web view

    /// The page's web view, made on first use. Each workspace keeps its own
    /// cookies and storage, so two projects on localhost don't share a login.
    func web() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: workspaceID)
        configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: PreviewScripts.console, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false, in: .page))
        content.addUserScript(WKUserScript(source: PreviewScripts.picker, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: Self.world))
        let relay = MessageRelay(self)
        content.add(relay, contentWorld: .page, name: PreviewScripts.consoleHandler)
        content.add(relay, contentWorld: Self.world, name: PreviewScripts.pickerHandler)

        let web = WKWebView(frame: NSRect(origin: .zero, size: viewport.nominal), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = viewport.userAgent
        // Right-click ▸ Inspect Element opens Safari's Web Inspector.
        web.isInspectable = true
        web.publisher(for: \.estimatedProgress).sink { [weak self] in self?.progress = $0 }.store(in: &observers)
        web.publisher(for: \.isLoading).sink { [weak self] in self?.isLoading = $0 }.store(in: &observers)
        web.publisher(for: \.url).sink { [weak self] url in
            guard let self, let url, url.absoluteString != "about:blank" else { return }
            self.url = url
            self.address = Self.display(url)
            PreviewStore.shared.remember(self)
        }.store(in: &observers)
        webView = web
        PreviewStore.shared.removeOrphanedData()
        return web
    }

    /// Let go of the web view (the feature was turned off, or the workspace closed).
    func close() {
        finishLoad("The preview was closed.")
        observers = []
        if let web = webView {
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            web.removeFromSuperview()
        }
        webView = nil
    }

    /// The page's size as the site sees it (CSS pixels).
    var pageSize: CGSize { webView?.bounds.size ?? viewport.nominal }

    /// "mobile, 390×844" / "desktop, 1280×800": said with every tool result
    /// and comment, so Claude knows which layout it's looking at.
    var viewportDescription: String {
        let size = pageSize
        return "\(viewport.rawValue), \(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    // MARK: Loading

    /// What a typed address means: "3000" and "localhost:3000" are local dev
    /// servers (http); anything else without a scheme is https.
    static func resolve(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.allSatisfy(\.isNumber) { return URL(string: "http://localhost:\(t)") }
        if t.hasPrefix(":"), t.dropFirst().allSatisfy(\.isNumber) { return URL(string: "http://localhost\(t)") }
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(), url.host != nil || scheme == "file" {
            return ["http", "https", "file"].contains(scheme) ? url : nil
        }
        let host = t.split(separator: "/", maxSplits: 1).first.map(String.init) ?? t
        let name = host.split(separator: ":").first.map(String.init) ?? host
        let local = name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".test")
            || name.first == "[" || name.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
        return URL(string: (local ? "http://" : "https://") + t)
    }

    /// An address as the field shows it: no "http://", no trailing slash.
    nonisolated static func display(_ url: URL) -> String {
        var s = url.absoluteString
        if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasSuffix("/"), url.path == "/", url.query == nil, url.fragment == nil { s.removeLast() }
        return s
    }

    /// Open an address (the field, a suggestion, Try Again).
    func open(_ text: String) {
        guard let target = Self.resolve(text) else {
            failure = Failure(address: text, reason: "That doesn't look like an address.")
            started = true
            return
        }
        started = true
        failure = nil
        address = Self.display(target)
        if target.isFileURL {
            web().loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            web().load(URLRequest(url: target))
        }
    }

    /// Open an address and wait until the page loaded (Claude's `navigate`).
    /// Returns what went wrong, or nil.
    func navigate(_ text: String) async -> String? {
        guard Self.resolve(text) != nil else { return "\(text) isn't an address the preview can open." }
        finishLoad("Another page was opened.")
        open(text)
        return await withCheckedContinuation { continuation in
            var done = false
            let finish: (String?) -> Void = { reason in
                guard !done else { return }
                done = true
                continuation.resume(returning: reason)
            }
            loadWaiters.append(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                MainActor.assumeIsolated {
                    guard !done else { return }
                    self?.loadWaiters.removeAll()
                    finish("The page was still loading after 30 seconds.")
                }
            }
        }
    }

    private func finishLoad(_ reason: String?) {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0(reason) }
    }

    func reload() {
        guard let web = webView, web.url != nil, failure == nil else { open(address); return }
        web.reload()
    }

    func stopLoading() { webView?.stopLoading() }

    func setViewport(_ v: PreviewViewport) {
        guard v != viewport else { return }
        viewport = v
        PreviewStore.shared.remember(self)
        guard let web = webView else { return }
        web.customUserAgent = v.userAgent
        if let stage { stage.needsLayout = true } else { web.setFrameSize(v.nominal) }
        // The server and the page's scripts see the new user agent.
        if web.url != nil, failure == nil { web.reload() }
    }

    // MARK: Console

    private func log(_ level: String, _ text: String) {
        console.append(ConsoleEntry(level: level, text: text))
        if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) }
    }

    func clearConsole() { console = [] }

    // MARK: Scripts

    /// Run JavaScript in the page, as the body of an async function.
    func run(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await web().callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func picker(_ call: String) {
        webView?.evaluateJavaScript("window.__toastyPicker && window.__toastyPicker.\(call)()", in: nil, in: Self.world) { _ in }
    }

    #if DEBUG
    /// Debug: run JavaScript in the picker's world.
    func debugPickerWorld(_ body: String) async throws -> Any? {
        try await web().callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: Self.world)
    }
    #endif

    // MARK: Pictures

    /// What the page shows now, at the page's own size: 2 pixels per point
    /// for a phone, 1 for a desktop.
    func snapshot() async throws -> NSBitmapImageRep {
        let web = web()
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        let size = web.bounds.size
        let density: CGFloat = viewport == .mobile ? 2 : 1
        let pixels = NSSize(width: (size.width * density).rounded(), height: (size.height * density).rounded())
        guard pixels.width >= 1, pixels.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: { rep.size = size; return rep }()) else {
            throw PreviewError("Couldn't take a picture of the page.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: Comments

    /// Start or stop picking things in the page to comment on.
    func setCommenting(_ on: Bool) {
        guard on != commenting else { return }
        commenting = on
        pick = nil
        picker(on ? "start" : "stop")
        if on, let web = webView { web.window?.makeFirstResponder(web) }
    }

    /// Drop the current pick and keep picking.
    func cancelPick() {
        pick = nil
        picker("resume")
        if let web = webView { web.window?.makeFirstResponder(web) }
    }

    /// Give the pick, with the user's note, to the conversation that's open
    /// in `workspace`: a picture of the page with the pick outlined, and a
    /// line saying what and where it is.
    ///
    /// Sent at once as its own prompt (Return; whatever is being typed in
    /// the composer stays there), which ends commenting. With `send` false
    /// (⇧Return) it's added to the composer instead and picking goes on, to
    /// gather several comments and send them together.
    func comment(_ note: String, in workspace: Workspace, send: Bool = true) async {
        guard let pick else { return }
        let picture = try? await snapshot()
        let conversation = workspace.selected ?? workspace.newConversation()
        var images: [NSImage] = []
        if let picture {
            let image = NSImage(size: picture.size)
            image.addRepresentation(picture)
            images.append(image)
        }
        let line = Self.commentLine(pick, note: note, viewport: viewport)
        if send {
            conversation.post(line, images: images)
            leaveCommenting()
            return
        }
        conversation.attachments += images
        conversation.draft = conversation.draft.isEmpty ? line : conversation.draft + "\n" + line
        self.pick = nil
        picker("resume")
        // Back in the page, for the next pick (or Esc to finish).
        if let web = webView { web.window?.makeFirstResponder(web) }
    }

    /// "Preview comment on `button.cta` "Start trial" (mobile 390×844,
    /// localhost:3000/pricing, outlined in the screenshot): too close to the edge"
    nonisolated static func commentLine(_ pick: Pick, note: String, viewport: PreviewViewport) -> String {
        var what = pick.kind == .area ? "the area around `\(pick.selector)`" : "`\(pick.selector)`"
        if pick.kind == .element, !pick.text.isEmpty { what += " \"\(pick.text)\"" }
        let size = "\(viewport.rawValue) \(Int(pick.viewport.width.rounded()))×\(Int(pick.viewport.height.rounded()))"
        let page = URL(string: pick.url).map { display($0) } ?? pick.url
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Preview comment on \(what) (\(size), \(page), outlined in the screenshot)" + (trimmed.isEmpty ? "" : ": \(trimmed)")
    }

    fileprivate func received(_ name: String, _ body: Any) {
        guard let m = body as? [String: Any] else { return }
        switch name {
        case PreviewScripts.consoleHandler:
            log(m["level"] as? String ?? "log", m["text"] as? String ?? "")
        case PreviewScripts.pickerHandler:
            guard commenting else { return }
            if m["kind"] as? String == "cancel" {
                if pick != nil { cancelPick() } else { leaveCommenting() }
                return
            }
            func size(_ key: String, _ w: String, _ h: String) -> CGSize {
                let d = m[key] as? [String: Any] ?? [:]
                return CGSize(width: d[w] as? Double ?? 0, height: d[h] as? Double ?? 0)
            }
            let r = m["rect"] as? [String: Any] ?? [:]
            guard let kind = (m["kind"] as? String).flatMap(Pick.Kind.init(rawValue:)) else { return }
            pick = Pick(kind: kind, selector: m["selector"] as? String ?? "", text: m["text"] as? String ?? "",
                        rect: CGRect(x: r["x"] as? Double ?? 0, y: r["y"] as? Double ?? 0,
                                     width: r["width"] as? Double ?? 0, height: r["height"] as? Double ?? 0),
                        viewport: size("viewport", "width", "height"), url: m["url"] as? String ?? "")
        default:
            break
        }
    }

    /// Esc in the page: done commenting, back to the composer.
    func leaveCommenting() {
        setCommenting(false)
        WorkspaceStore.shared.workspaces.first { $0.id == workspaceID }?.selected?.focusComposer()
    }
}

struct PreviewError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// The user content controller keeps its handlers alive; this keeps it from
/// keeping the session alive.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var session: PreviewSession?
    init(_ session: PreviewSession) { self.session = session }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.received(message.name, message.body)
    }
}

// MARK: - Navigation

extension PreviewSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        return ["http", "https", "file", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: its console starts empty, and a pick is gone.
        console = []
        failure = nil
        pick = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if commenting { picker("start") }
        finishLoad(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = Failure(address: address, reason: "The page stopped unexpectedly.")
        finishLoad("The page's process stopped unexpectedly.")
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        // Stopped by the user, or replaced by another load.
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        let reason: String
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCannotConnectToHost {
            reason = "Nothing is answering there. Is the dev server running?"
        } else {
            reason = e.localizedDescription
        }
        failure = Failure(address: address, reason: reason)
        log("error", "Couldn't load \(address): \(e.localizedDescription)")
        finishLoad(reason)
    }
}

// MARK: - Dialogs and new windows

extension PreviewSession: WKUIDelegate {
    /// Links that ask for a new window open in the preview itself.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    /// The page's alert/confirm/prompt: asked as a sheet while the preview is
    /// on screen; otherwise dismissed (and noted in the console, so Claude
    /// knows it happened) rather than leaving the page waiting unseen.
    private func ask(_ kind: String, _ message: String, cancel: Bool, field: String? = nil,
                     completion: @escaping (_ confirmed: Bool, _ text: String?) -> Void) {
        guard let window = webView?.window, window.isVisible, NSApp.isActive else {
            log("warn", "\(kind)(\"\(message)\") was dismissed: the preview wasn't in front.")
            completion(false, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if cancel { alert.addButton(withTitle: "Cancel") }
        var input: NSTextField?
        if let field {
            let f = NSTextField(string: field)
            f.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
            alert.accessoryView = f
            input = f
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn, input?.stringValue)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { c in ask("alert", message, cancel: false) { _, _ in c.resume() } }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { c in ask("confirm", message, cancel: true) { ok, _ in c.resume(returning: ok) } }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { c in
            ask("prompt", prompt, cancel: true, field: defaultText ?? "") { ok, text in c.resume(returning: ok ? text : nil) }
        }
    }
}

// MARK: - Store

/// The open workspaces' previews, and what each last showed.
@MainActor
final class PreviewStore {
    static let shared = PreviewStore()
    private static let key = "PreviewState"

    private var sessions: [UUID: PreviewSession] = [:]
    private var cleanedData = false

    func session(for workspace: Workspace) -> PreviewSession {
        prune()
        if let s = sessions[workspace.id] { return s }
        let saved = (UserDefaults.standard.dictionary(forKey: Self.key)?[workspace.id.uuidString] as? [String: String]) ?? [:]
        let s = PreviewSession(workspaceID: workspace.id, address: saved["address"] ?? "",
                               viewport: saved["viewport"].flatMap(PreviewViewport.init(rawValue:)) ?? .mobile)
        sessions[workspace.id] = s
        return s
    }

    /// Keep a workspace's address and viewport for next time.
    func remember(_ session: PreviewSession) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        all[session.workspaceID.uuidString] = ["address": session.address, "viewport": session.viewport.rawValue]
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    /// Closed workspaces' previews go with them.
    private func prune() {
        let open = Set(WorkspaceStore.shared.workspaces.map(\.id))
        for (id, session) in sessions where !open.contains(id) {
            session.close()
            sessions[id] = nil
        }
        guard var all = UserDefaults.standard.dictionary(forKey: Self.key) else { return }
        let stale = all.keys.filter { key in !open.contains { $0.uuidString == key } }
        guard !stale.isEmpty else { return }
        stale.forEach { all[$0] = nil }
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    /// Once per launch, after the first web view exists (WebKit crashes if
    /// asked for its data stores before it has started): cookies and storage
    /// kept for workspaces that are gone. Only the preview makes data stores
    /// with an identifier.
    fileprivate func removeOrphanedData() {
        guard !cleanedData else { return }
        cleanedData = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                let open = Set(WorkspaceStore.shared.workspaces.map(\.id))
                guard !open.isEmpty else { return }
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                    for id in ids where !open.contains(id) {
                        WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
                    }
                }
            }
        }
    }

    /// Claude finished a turn in `workspace`: reload its page, so the
    /// preview shows what was just changed without relying on the dev
    /// server's hot reload. Not while the user is in the middle of a comment
    /// (the pick would be lost), and never makes a preview that isn't open.
    func turnEnded(in workspace: Workspace) {
        guard PreviewSettings.shared.enabled, let session = sessions[workspace.id],
              session.url != nil, session.failure == nil, session.pick == nil, !session.isLoading else { return }
        session.reload()
    }

    /// The setting was turned off: every web view goes, and the right column
    /// goes back to the inspector and terminal.
    func turnedOff() {
        sessions.values.forEach { $0.close() }
        sessions = [:]
        for w in WorkspaceStore.shared.workspaces { w.hidePreview() }
    }

    /// A web address on this Mac or by IP address (a dev server), not a site
    /// with a name: `localhost`, `*.localhost`, `*.local`, `127.0.0.1`,
    /// `192.168.1.20`, `[::1]`.
    nonisolated static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host.contains(":") { return true }  // an IPv6 address
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// A link clicked in a terminal: a local address opens in that
    /// workspace's preview (which takes the right column). False when the
    /// preview is off or the link isn't local: the browser gets it.
    func open(_ url: URL, fromTerminal view: TerminalView) -> Bool {
        guard PreviewSettings.shared.enabled, Self.isLocal(url),
              let workspace = WorkspaceStore.shared.workspaces.first(where: { w in
                  w.terminals.contains { $0.terminalView === view }
              }) else { return false }
        // "Listening on 0.0.0.0" means every interface; this Mac is one.
        let address = url.absoluteString.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
        workspace.showPreview()
        session(for: workspace).open(address)
        return true
    }

    /// Local addresses the workspace's terminals have printed (a dev server
    /// saying where it listens), newest first. Read when the start screen
    /// appears; nothing watches the terminals.
    func localAddresses(in workspace: Workspace) -> [String] {
        var found: [String] = []
        for terminal in workspace.terminals {
            guard let text = terminal.terminalView?.vt.plainText else { continue }
            for match in String(text.suffix(20_000)).matches(of: #/https?:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d+)?/#) {
                var address = String(match.0)
                for other in ["127.0.0.1", "0.0.0.0", "[::1]", "[::]"] {
                    address = address.replacingOccurrences(of: other, with: "localhost")
                }
                if address.hasPrefix("http://") { address.removeFirst(7) }
                found.removeAll { $0 == address }
                found.append(address)
            }
        }
        return Array(found.reversed().prefix(3))
    }
}
