import AppKit
import Combine
import WebKit

/// The size a page is shown at: an iPhone, the largest iPhone, or a
/// desktop page (the user, 2026-11-20: those phones are the ones that
/// matter; no iPads or particular Macs). "mobile" is the iPhone, the name
/// it had when it was the only phone (saved choices and Claude's calls).
enum PreviewViewport: String, CaseIterable, Identifiable {
    case mobile
    case mobileMax = "mobile-max"
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mobile: "iPhone"
        case .mobileMax: "iPhone Pro Max"
        case .desktop: "Desktop"
        }
    }

    var symbol: String {
        switch self {
        case .mobile, .mobileMax: "iphone"
        case .desktop: "desktopcomputer"
        }
    }

    var isPhone: Bool { self != .desktop }

    /// The page's size when the window has room (and when it isn't open):
    /// iPhone 17 and iPhone 17 Pro Max in Safari, portrait.
    var nominal: CGSize {
        switch self {
        case .mobile: CGSize(width: 402, height: 874)
        case .mobileMax: CGSize(width: 440, height: 956)
        case .desktop: CGSize(width: 1280, height: 800)
        }
    }

    /// A phone's Safari, so sites that sniff the user agent serve their
    /// mobile pages; nil for the web view's own (desktop Safari).
    var userAgent: String? {
        switch self {
        case .mobile, .mobileMax: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
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

    /// A phone is laid out at its real width and drawn smaller when the
    /// pane is narrower, centered, and at most its own height. A desktop page
    /// is the window's page area, as in any browser: the user sizes it by
    /// sizing the window (or with a preset, `PreviewWindowController`). Its
    /// `nominal` size is for when no window shows it.
    func fit(in pane: CGSize) -> Fit {
        guard pane.width > 1, pane.height > 1 else { return Fit(display: .zero, page: nominal) }
        let width = nominal.width
        let scale = min(1, pane.width / width)
        switch self {
        case .mobile, .mobileMax:
            let height = min(nominal.height, pane.height / scale)
            return Fit(display: CGRect(x: ((pane.width - width * scale) / 2).rounded(), y: 0,
                                       width: width * scale, height: height * scale),
                       page: CGSize(width: width, height: height))
        case .desktop:
            return Fit(display: CGRect(origin: .zero, size: pane), page: pane)
        }
    }
}

/// One workspace's browser: its page, console and comments. The web view is
/// made the first time the browser is used (by the user or by Claude) and
/// kept while the workspace is open, whether its window is open or not.
/// The window (`PreviewWindowController`) only shows it.
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
        /// Picked in side by side's iPhone page, not the main one.
        var inTwin = false
        /// Where an element was clicked, in the page's coordinates (nil for
        /// an area, which is placed by its middle).
        var point: CGPoint?
    }

    let workspaceID: UUID
    /// The address field's text.
    @Published var address: String
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    /// There's a page before this one to go back to.
    @Published private(set) var canGoBack = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failure: Failure?
    @Published private(set) var viewport: PreviewViewport
    /// The phone ⇧⌘M goes back to from desktop: the one last shown.
    @Published private(set) var lastPhone: PreviewViewport = .mobile
    @Published private(set) var console: [ConsoleEntry] = []
    @Published private(set) var commenting = false
    /// The tab comments go to, when the user pinned one in the comment
    /// field; nil follows the workspace's last active tab (`commentTab`).
    /// It stays for later comments until the user picks Last Active Tab
    /// (or the tab closes).
    @Published var commentTabID: UUID?
    @Published private(set) var pick: Pick?
    /// Where the last comment went ("Added to Tee-Up", "Sent to “Fix the
    /// header”"): the pane says so for a moment, since neither the list
    /// nor the conversation is in view. A new id each time.
    @Published private(set) var commentConfirmation: (id: UUID, text: String)?
    /// A page has been asked for (the start screen is over).
    @Published private(set) var started = false
    /// The browser window is open (shown, or minimized): the page is in it.
    @Published private(set) var windowOpen = false
    /// Claude is using the browser: a tool call is running, or one ended a
    /// moment ago (so a run of calls reads as one stretch of use).
    @Published private(set) var agentActive = false
    /// The conversation whose Claude last used this browser: the footer's
    /// "Show Conversation" goes to it.
    private(set) var lastAgentConversationID: UUID?
    private var agentCalls = 0
    private var agentIdle: Task<Void, Never>?
    /// When the page last went into the backstage.
    private var backstagedAt: Date?

    private(set) var webView: WKWebView?
    /// Side by side (experiment): the desktop page and, beside it, the same
    /// page as an iPhone shows it, in a second web view (`twin`) on the same
    /// data store (one login). The address, back and reload drive both, and
    /// a page either one goes to, the other follows. Claude's tools, the
    /// console and comments stay with the desktop page (`webView`).
    @Published private(set) var sideBySide = UserDefaults.standard.bool(forKey: PreviewSession.sideBySideKey)
    nonisolated static let sideBySideKey = "PreviewSideBySide"
    private(set) var twin: WKWebView?
    private var twinDelegate: TwinDelegate?
    private var twinObservers: Set<AnyCancellable> = []
    /// The address both pages were last put on: a page reaching it again
    /// isn't news for the other one.
    private var synced: String?
    /// A web view loading because the other one went somewhere: its own
    /// address changes (server redirects, a phone site's m. address) until
    /// that load ends aren't followed back, which could go back and forth.
    private var mainFollowing = false
    private var twinFollowing = false
    /// Scroll sync (experiment, `PreviewScrollSync`): in side by side,
    /// scrolling either page scrolls the other to the same place.
    @Published private(set) var scrollSync = UserDefaults.standard.bool(forKey: PreviewScrollSync.enabledKey)
    private let scrollSyncer = PreviewScrollSync()
    /// The view showing the page, while the window is open.
    weak var stage: PreviewStage?
    private var observers: Set<AnyCancellable> = []
    private var loadWaiters: [(String?) -> Void] = []
    private static let world = WKContentWorld.world(name: "ToastyPreview")
    private static let consoleLimit = 500

    init(workspaceID: UUID, address: String, viewport: PreviewViewport, phone: PreviewViewport? = nil) {
        self.workspaceID = workspaceID
        self.address = address
        self.viewport = viewport
        if let phone, phone.isPhone { lastPhone = phone }
        if viewport.isPhone { lastPhone = viewport }
        if viewport.isPhone { sideBySide = false }
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
        PreviewScrollSync.install(on: configuration, relay: relay)

        let web = WKWebView(frame: NSRect(origin: .zero, size: viewport.nominal), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = viewport.userAgent
        // Right-click ▸ Inspect Element opens Safari's Web Inspector.
        web.isInspectable = true
        web.publisher(for: \.estimatedProgress).sink { [weak self] in self?.progress = $0 }.store(in: &observers)
        web.publisher(for: \.isLoading).sink { [weak self] in self?.isLoading = $0 }.store(in: &observers)
        web.publisher(for: \.canGoBack).sink { [weak self] in self?.canGoBack = $0 }.store(in: &observers)
        web.publisher(for: \.url).sink { [weak self] url in
            guard let self, let url, url.absoluteString != "about:blank" else { return }
            self.url = url
            self.address = Self.display(url)
            PreviewStore.shared.remember(self)
            self.mirror(url, fromTwin: false)
        }.store(in: &observers)
        webView = web
        scrollSyncer.main = web
        PreviewStore.shared.removeOrphanedData()
        updateBackstage()
        return web
    }

    func setWindowOpen(_ open: Bool) {
        if windowOpen != open { windowOpen = open }
        // After the window has taken the page, or let go of it.
        DispatchQueue.main.async { [weak self] in self?.updateBackstage() }
    }

    /// While Claude is using the page and its window is closed, the page
    /// waits in `PreviewBackstage`, so WebKit runs it as a visible page:
    /// animation frames, timers at full rate. Out of any window it would be
    /// a hidden page, with no animation frames at all (an animated UI
    /// would never settle before a screenshot). When Claude is done, the
    /// page leaves it and is throttled again, so a page nobody is using
    /// doesn't use the Mac.
    func updateBackstage() {
        guard let web = webView, stage == nil else { return }
        if agentActive, !windowOpen {
            if PreviewBackstage.shared.hold(web, size: viewport.nominal) { backstagedAt = Date() }
        } else {
            PreviewBackstage.shared.release(web)
        }
    }

    // MARK: Claude

    /// A tool call from Claude, in `conversation`, started.
    func agentBegan(from conversation: UUID? = nil) {
        if let conversation { lastAgentConversationID = conversation }
        agentCalls += 1
        agentIdle?.cancel()
        agentIdle = nil
        if !agentActive { agentActive = true }
        updateBackstage()
    }

    /// Just put in the backstage, WebKit takes a moment to run the page as
    /// visible: a call that ran at once would still see a hidden page (no
    /// animation frames). Wait for it, briefly.
    func readyForAgent() async {
        guard let since = backstagedAt, Date().timeIntervalSince(since) < 1, let web = webView, web.url != nil else { return }
        for _ in 0..<12 {
            if (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible" { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// A tool call from Claude ended.
    func agentEnded() {
        agentCalls = max(0, agentCalls - 1)
        guard agentCalls == 0 else { return }
        agentIdle?.cancel()
        agentIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.agentActive = false
            self?.updateBackstage()
        }
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
            PreviewBackstage.shared.release(web)
            web.removeFromSuperview()
        }
        webView = nil
        dropTwin()
    }

    // MARK: Side by side

    /// Show the iPhone page beside the desktop one, or stop.
    func setSideBySide(_ on: Bool) {
        guard on != sideBySide else { return }
        sideBySide = on
        UserDefaults.standard.set(on, forKey: Self.sideBySideKey)
        if on {
            if viewport.isPhone { setViewport(.desktop, byUser: true) }
            if let url = webView?.url, failure == nil { synced = url.absoluteString; loadTwin(url) }
        } else {
            dropTwin()
        }
    }

    /// The iPhone page, made when side by side is first shown.
    func twinWeb() -> WKWebView {
        if let twin { return twin }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: workspaceID)
        configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        // Commenting works in the iPhone page too.
        let relay = MessageRelay(self)
        configuration.userContentController.addUserScript(WKUserScript(source: PreviewScripts.picker, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: Self.world))
        configuration.userContentController.add(relay, contentWorld: Self.world, name: PreviewScripts.pickerHandler)
        PreviewScrollSync.install(on: configuration, relay: relay)
        let web = WKWebView(frame: NSRect(origin: .zero, size: lastPhone.nominal), configuration: configuration)
        let delegate = TwinDelegate(self)
        twinDelegate = delegate
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = lastPhone.userAgent
        web.isInspectable = true
        web.publisher(for: \.url).sink { [weak self] url in
            guard let self, let url, url.absoluteString != "about:blank" else { return }
            self.mirror(url, fromTwin: true)
        }.store(in: &twinObservers)
        twin = web
        scrollSyncer.twin = web
        if let url = webView?.url, failure == nil { synced = url.absoluteString; loadTwin(url) }
        return web
    }

    /// Which iPhone the page beside the desktop one is (side by side's
    /// own size menu). Also the phone ⇧⌘M goes to.
    func setTwinPhone(_ v: PreviewViewport) {
        guard v.isPhone, v != lastPhone else { return }
        let old = lastPhone
        lastPhone = v
        PreviewStore.shared.remember(self)
        PreviewStore.shared.presenter?.fitTwinPhone(of: self, from: old)
        guard let twin else { return }
        twin.customUserAgent = v.userAgent
        if twin.url != nil { twinFollowing = true; twin.reload() }
    }

    fileprivate func twinPickGone() {
        if pick?.inTwin == true { pick = nil }
    }

    private func dropTwin() {
        twinPickGone()
        twinObservers = []
        if let twin {
            twin.stopLoading()
            twin.navigationDelegate = nil
            twin.uiDelegate = nil
            twin.configuration.userContentController.removeAllScriptMessageHandlers()
            twin.removeFromSuperview()
        }
        twin = nil
        twinDelegate = nil
        twinFollowing = false
        mainFollowing = false
    }

    private func loadTwin(_ url: URL) {
        guard let twin else { return }
        twinFollowing = true
        if url.isFileURL { twin.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { twin.load(URLRequest(url: url)) }
    }

    /// One page went to `url` (a link, a form, a script changing the
    /// address): the other goes there too.
    private func mirror(_ url: URL, fromTwin: Bool) {
        guard sideBySide, twin != nil else { return }
        let key = url.absoluteString
        guard key != synced else { return }
        if fromTwin {
            guard !twinFollowing, let web = webView else { return }
            synced = key
            mainFollowing = true
            if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { web.load(URLRequest(url: url)) }
        } else {
            guard !mainFollowing else { synced = key; return }
            synced = key
            loadTwin(url)
        }
    }

    fileprivate func twinLoadEnded() {
        twinFollowing = false
        if commenting { picker("start", in: twin) }
        if scrollSync { scrollSyncer.syncTwinToMain() }
    }

    /// Turn scroll sync on or off (side by side's footer button).
    func setScrollSync(_ on: Bool) {
        guard on != scrollSync else { return }
        scrollSync = on
        UserDefaults.standard.set(on, forKey: PreviewScrollSync.enabledKey)
        if on { scrollSyncer.syncTwinToMain() }
    }

    fileprivate func scrolled(in web: WKWebView?, _ body: Any) {
        guard sideBySide, let web else { return }
        scrollSyncer.scrolled(in: web, body, syncOn: scrollSync)
    }
    fileprivate func twinFailed(_ error: Error) {
        twinFollowing = false
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        log("warn", "The iPhone page couldn't load: \(e.localizedDescription)")
    }

    /// The page's size as the site sees it (CSS pixels).
    var pageSize: CGSize { webView?.bounds.size ?? viewport.nominal }

    /// The page's size as last laid out in the window (the footer shows it).
    @Published private(set) var shownPageSize: CGSize = .zero

    func notePageSize(_ size: CGSize) {
        if abs(size.width - shownPageSize.width) > 0.5 || abs(size.height - shownPageSize.height) > 0.5 { shownPageSize = size }
    }

    /// "mobile, 402×874" / "desktop, 1280×800": said with every tool result
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
        synced = target.absoluteString
        if sideBySide, twin != nil { loadTwin(target) }
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
        if sideBySide, let twin {
            if twin.url != nil { twinFollowing = true; twin.reload() } else if let url = web.url { loadTwin(url) }
        }
    }

    func stopLoading() { webView?.stopLoading() }

    /// The page before this one (the toolbar's back button, ⌘[).
    func goBack() {
        guard let web = webView, web.canGoBack else { return }
        failure = nil
        if sideBySide, twin != nil, let back = web.backForwardList.backItem?.url {
            // Both to the page before, whatever the iPhone page's own history.
            synced = back.absoluteString
            mainFollowing = true
            web.goBack()
            loadTwin(back)
            return
        }
        web.goBack()
    }

    /// The other size, phone or desktop (⇧⌘M: the user's).
    func toggleViewport() {
        setViewport(viewport.isPhone ? .desktop : lastPhone, byUser: true)
    }

    /// Show the page at `v`. The user's change (`byUser`) also sizes the
    /// window for it; Claude's never moves the window.
    func setViewport(_ v: PreviewViewport, byUser: Bool = false) {
        guard v != viewport else { return }
        if v.isPhone, sideBySide { setSideBySide(false) }
        viewport = v
        if v.isPhone { lastPhone = v }
        PreviewStore.shared.remember(self)
        if byUser { PreviewStore.shared.presenter?.fitViewport(of: self) }
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

    /// Calls the picker in both pages (side by side's iPhone one too), or
    /// in `web` alone.
    private func picker(_ call: String, in web: WKWebView? = nil) {
        let pages = web.map { [$0] } ?? [webView, twin].compactMap { $0 }
        for page in pages {
            page.evaluateJavaScript("window.__toastyPicker && window.__toastyPicker.\(call)()", in: nil, in: Self.world) { _ in }
        }
    }

    #if DEBUG
    /// Debug: run JavaScript in the picker's world.
    func debugPickerWorld(_ body: String, inTwin: Bool = false) async throws -> Any? {
        try await (inTwin ? (twin ?? web()) : web()).callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: Self.world)
    }
    #endif

    // MARK: Pictures

    /// What the page shows now, at the page's own size: 2 pixels per point
    /// for a phone, 1 for a desktop.
    func snapshot(twin inTwin: Bool = false) async throws -> NSBitmapImageRep {
        let web = inTwin ? (twin ?? web()) : web()
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        let size = web.bounds.size
        let density: CGFloat = inTwin || viewport.isPhone ? 2 : 1
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

    /// Drop the current pick (or the one just commented on) and keep picking.
    func cancelPick() {
        let page = pick?.inTwin == true ? twin : webView
        pick = nil
        picker("resume")
        if let page { page.window?.makeFirstResponder(page) }
    }

    /// Give the pick, with the user's note, to `workspace`: a picture of the
    /// page with the pick outlined, and a line saying what and where it is.
    ///
    /// Return sends it where Settings ▸ Preview says, ⇧Return to the other
    /// place (`to`). To the conversation: posted at once as its own prompt
    /// (whatever is being typed in the composer stays there), which ends
    /// commenting. To Tee-Up: a card on the workspace's list, and picking
    /// goes on, to gather several.
    /// Where a comment to the conversation goes: the tab pinned in the
    /// comment field, else the one last selected in the workspace (which
    /// isn't necessarily the one on screen: the browser window shows a
    /// workspace of its own). Picking one never selects it in Toasty.
    func commentTab(in workspace: Workspace) -> ClaudeConversation? {
        pinnedCommentTab(in: workspace) ?? workspace.selected
    }

    /// The pinned tab, while it's still open.
    func pinnedCommentTab(in workspace: Workspace) -> ClaudeConversation? {
        commentTabID.flatMap { id in workspace.conversations.first { $0.id == id } }
    }

    /// `attached`, `files`: what the user added to the comment (pasted,
    /// dropped, picked, or a ⇧⌘0 screenshot), after the page's own picture.
    func comment(_ note: String, images attached: [NSImage] = [], files: [URL] = [],
                 in workspace: Workspace, to destination: PreviewSettings.CommentDestination) async {
        guard let pick else { return }
        let picture = try? await snapshot(twin: pick.inTwin)
        var images: [NSImage] = []
        if let picture {
            let image = NSImage(size: picture.size)
            image.addRepresentation(picture)
            images.append(image)
        }
        images += attached
        let line = Self.commentLine(pick, note: note, viewport: pick.inTwin ? lastPhone : viewport)
        switch destination {
        case .teeUp:
            var item = TeeUp(text: line)
            images.forEach { item.attach($0) }
            if !files.isEmpty { item.attach(files) }
            workspace.addTeeUp(item)
            commentConfirmation = (UUID(), "Added to Tee-Up")
            cancelPick()  // back in the page, for the next pick (or Esc to finish)
        case .conversation:
            let existing = commentTab(in: workspace)
            let tab = existing ?? workspace.newConversation()
            // Named before the comment can become a new tab's title.
            let sentTo = existing.map { "Sent to “\($0.title)”" } ?? "Sent to a new conversation"
            tab.post(line, images: images, files: files)
            commentConfirmation = (UUID(), sentTo)
            leaveCommenting()
        }
    }

    /// "Preview comment on `button.cta` "Start trial" (mobile 402×874,
    /// localhost:3000/pricing, outlined in the screenshot): too close to the edge"
    nonisolated static func commentLine(_ pick: Pick, note: String, viewport: PreviewViewport) -> String {
        var what = pick.kind == .area ? "the area around `\(pick.selector)`" : "`\(pick.selector)`"
        if pick.kind == .element, !pick.text.isEmpty { what += " \"\(pick.text)\"" }
        let size = "\(viewport.rawValue) \(Int(pick.viewport.width.rounded()))×\(Int(pick.viewport.height.rounded()))"
        let page = URL(string: pick.url).map { display($0) } ?? pick.url
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Preview comment on \(what) (\(size), \(page), outlined in the screenshot)" + (trimmed.isEmpty ? "" : ": \(trimmed)")
    }

    fileprivate func received(_ name: String, _ body: Any, from page: WKWebView? = nil) {
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
            let inTwin = page != nil && page === twin
            // One pick at a time: the other page lets go of its own.
            if let other = inTwin ? webView : twin { picker("resume", in: other) }
            pick = Pick(kind: kind, selector: m["selector"] as? String ?? "", text: m["text"] as? String ?? "",
                        rect: CGRect(x: r["x"] as? Double ?? 0, y: r["y"] as? Double ?? 0,
                                     width: r["width"] as? Double ?? 0, height: r["height"] as? Double ?? 0),
                        viewport: size("viewport", "width", "height"), url: m["url"] as? String ?? "", inTwin: inTwin,
                        point: (m["point"] as? [String: Any]).map { CGPoint(x: $0["x"] as? Double ?? 0, y: $0["y"] as? Double ?? 0) })
        default:
            break
        }
    }

    /// Esc in the page, or a comment sent: done commenting. The keyboard
    /// stays in the browser window (the user is looking at it).
    func leaveCommenting() {
        setCommenting(false)
    }
}

/// Where a page Claude is using waits while its window is closed: a window
/// of one point, transparent, above the others (so nothing covers it) and
/// passing every click through, on every Space. WebKit sees its page in a
/// visible window and runs it as one; nobody sees anything. The page keeps
/// its own size: it's laid out and pictured at that size, only what's
/// painted to the screen is the one point.
@MainActor
final class PreviewBackstage {
    static let shared = PreviewBackstage()

    private lazy var window: NSWindow = {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]
        w.isExcludedFromWindowsMenu = true
        w.hidesOnDeactivate = false
        w.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        w.contentView?.clipsToBounds = true
        return w
    }()

    /// Returns whether the page has just come in (it wasn't here already).
    @discardableResult
    func hold(_ web: WKWebView, size: CGSize) -> Bool {
        guard let content = window.contentView else { return false }
        let arriving = web.superview !== content
        if arriving { content.addSubview(web) }
        web.frame = NSRect(origin: .zero, size: size)
        if !window.isVisible {
            if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY)) }
            window.orderFrontRegardless()
        }
        return arriving
    }

    func release(_ web: WKWebView) {
        guard let content = window.contentView, web.superview === content else { return }
        web.removeFromSuperview()
        if content.subviews.isEmpty { window.orderOut(nil) }
    }

    #if DEBUG
    var holding: Int { window.contentView?.subviews.count ?? 0 }
    #endif
}

struct PreviewError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// The iPhone page's navigation and new windows (side by side). It has no
/// console, comments or dialogs of its own: those are the desktop page's.
private final class TwinDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var session: PreviewSession?
    init(_ session: PreviewSession) { self.session = session }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        return ["http", "https", "file", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { session?.twinLoadEnded() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: a pick in the old one is gone.
        MainActor.assumeIsolated { session?.twinPickGone() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { session?.twinFailed(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { session?.twinFailed(error) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }
}

/// The user content controller keeps its handlers alive; this keeps it from
/// keeping the session alive.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var session: PreviewSession?
    init(_ session: PreviewSession) { self.session = session }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == PreviewScrollSync.handler { session?.scrolled(in: message.webView, message.body); return }
        session?.received(message.name, message.body, from: message.webView)
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
        mainFollowing = false
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
        mainFollowing = false
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
    /// Links that ask for a new window open in the same page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    /// The page's alert/confirm/prompt: asked as a sheet on the browser
    /// window while it's open and Toasty is in front (a sheet doesn't bring
    /// the window forward); otherwise dismissed (and noted in the console,
    /// so Claude knows it happened) rather than leaving the page waiting unseen.
    private func ask(_ kind: String, _ message: String, cancel: Bool, field: String? = nil,
                     completion: @escaping (_ confirmed: Bool, _ text: String?) -> Void) {
        guard let window = webView?.window, window.isVisible, NSApp.isActive else {
            log("warn", "\(kind)(\"\(message)\") was dismissed: the browser window wasn't open.")
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

/// The open workspaces' browsers, what each last showed, and the one window
/// that shows the selected workspace's.
@MainActor
final class PreviewStore {
    static let shared = PreviewStore()
    private static let key = "PreviewState"

    /// One per open workspace, each with its own cookies and storage. Claude
    /// reaches the one of its conversation's workspace, whichever is on view.
    private var sessions: [UUID: PreviewSession] = [:]
    /// The browser window, made the first time it's shown.
    private(set) var presenter: PreviewWindowController?
    private var cleanedData = false

    func session(for workspace: Workspace) -> PreviewSession {
        prune()
        if let s = sessions[workspace.id] { return s }
        let saved = (UserDefaults.standard.dictionary(forKey: Self.key)?[workspace.id.uuidString] as? [String: String]) ?? [:]
        // Desktop until the workspace's browser has been switched; then
        // what it was left at.
        let s = PreviewSession(workspaceID: workspace.id, address: saved["address"] ?? "",
                               viewport: saved["viewport"].flatMap(PreviewViewport.init(rawValue:)) ?? .desktop,
                               phone: saved["phone"].flatMap(PreviewViewport.init(rawValue:)))
        sessions[workspace.id] = s
        return s
    }

    /// Show the browser window and bring it forward, showing `workspace`'s
    /// browser if one is given (the user asked for that one), else what it
    /// showed. Only for what the user does: Claude's tools never call this.
    func showWindow(_ workspace: Workspace? = nil) {
        guard PreviewSettings.shared.enabled else { return }
        let controller = presenter ?? PreviewWindowController(store: WorkspaceStore.shared)
        presenter = controller
        if let workspace { controller.show(workspace) }
        controller.reveal()
    }

    /// The workspaces whose browser has a page (made by the user or by
    /// Claude), in the sidebar's order: what the window's menu offers.
    func workspacesWithPages() -> [Workspace] {
        WorkspaceStore.shared.workspaces.filter { sessions[$0.id]?.webView != nil }
    }

    /// Keep a workspace's address and viewport for next time.
    func remember(_ session: PreviewSession) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        all[session.workspaceID.uuidString] = ["address": session.address, "viewport": session.viewport.rawValue,
                                               "phone": session.lastPhone.rawValue]
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
    /// browser shows what was just changed without relying on the dev
    /// server's hot reload. Not while the user is in the middle of a comment
    /// (the pick would be lost), and never makes a preview that isn't open.
    func turnEnded(in workspace: Workspace) {
        guard PreviewSettings.shared.enabled, let session = sessions[workspace.id],
              session.url != nil, session.failure == nil, session.pick == nil, !session.isLoading else { return }
        session.reload()
    }

    /// The setting was turned off: every window and web view goes.
    func turnedOff() {
        presenter?.close()
        presenter = nil
        sessions.values.forEach { $0.close() }
        sessions = [:]
    }

    /// A web address on this Mac or by IP address (a dev server), not a site
    /// with a name: `localhost`, `*.localhost`, `*.local`, `127.0.0.1`,
    /// `192.168.1.20`, `[::1]`.
    nonisolated static func isLocal(_ url: URL) -> Bool {
        opensInBrowser(url, localhost: true, ipAddresses: true, sites: [])
    }

    /// Whether a clicked link opens in Toasty's browser (Settings ▸ Browser):
    /// every link, or only localhost names (`localhost`, `*.localhost`, `*.local`), IP addresses
    /// (`127.0.0.1`, `192.168.1.20`, `[::1]`), and the user's own sites, each
    /// with its subdomains. Only http and https.
    nonisolated static func opensInBrowser(_ url: URL, every: Bool = false, localhost: Bool, ipAddresses: Bool,
                                           sites: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if every { return true }
        if localhost, host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if ipAddresses, isIPAddress(host) { return true }
        return sites.contains { site in host == site || host.hasSuffix("." + site) }
    }

    nonisolated private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }  // an IPv6 address
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// A link clicked in a terminal: an address Settings ▸ Browser sends
    /// here opens in that workspace's browser, and the browser window comes
    /// forward showing it. False when the browser is off or the link isn't
    /// one of those: the default browser gets it.
    func open(_ url: URL, fromTerminal view: TerminalView) -> Bool {
        let settings = PreviewSettings.shared
        guard settings.enabled,
              Self.opensInBrowser(url, every: settings.opensEveryLink, localhost: settings.opensLocalhost,
                                  ipAddresses: settings.opensIPAddresses, sites: settings.sites),
              let workspace = WorkspaceStore.shared.workspaces.first(where: { w in
                  w.terminals.contains { $0.terminalView === view }
              }) else { return false }
        // "Listening on 0.0.0.0" means every interface; this Mac is one.
        let address = url.absoluteString.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
        session(for: workspace).open(address)
        showWindow(workspace)
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
