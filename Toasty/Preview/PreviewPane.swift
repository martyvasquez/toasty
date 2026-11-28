import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Window

/// A browser tab that left the tab row for a window of its own (the user,
/// 2026-11-26: "Move to Window" moves that tab, as dragging a tab out of
/// Safari; it replaced one shared window that picked a workspace). The
/// window is that tab's page, for good: one workspace, one page, so it
/// picks nothing. Its tab stays in the row as a dashed pseudo-tab that
/// brings it forward; Move Back to Tab puts the page back in the row.
/// Its close button only puts it away; Close Browser closes the page.
/// Claude's tools never open, raise or focus it.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let workspace: Workspace
    let session: PreviewSession
    private let model = PreviewWindowModel()
    private var cancellables: Set<AnyCancellable> = []

    init(workspace: Workspace, session: PreviewSession) {
        self.workspace = workspace
        self.session = session
        let size = NSSize(width: 1280, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty standard toolbar, as the main window's: the same titlebar
        // height and window-button place, and the same corner radius.
        window.toolbar = NSToolbar(identifier: "PreviewWindow")
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(Color.claudeChrome)
        super.init(window: window)
        window.delegate = self

        model.shown = (workspace, session)
        let host = NSHostingController(rootView: PreviewWindowRoot(model: model))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = host
        // After the content: a content view controller sets its own limits.
        window.contentMinSize = Self.minimumContent
        window.setContentSize(size)
        installBar()

        // Each page's window keeps its own frame; a new one starts where the
        // last browser window was, a step down and right.
        let autosave = Self.frameKey(session.pageID)
        if !window.setFrameUsingName(autosave) { place(window) }
        window.setFrameAutosaveName(autosave)
        let least = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContent)).size
        if window.frame.width < least.width || window.frame.height < least.height {
            var frame = window.frame
            frame.origin.y -= max(0, least.height - frame.height)
            frame.size = NSSize(width: max(frame.width, least.width), height: max(frame.height, least.height))
            window.setFrame(frame, display: false)
        }
        sizedForPhone = session.viewport.isPhone

        workspace.$name.combineLatest(session.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func frameKey(_ page: UUID) -> String { "PreviewWindow-\(page.uuidString)" }

    /// The titlebar row, in the titlebar view (clicks under a transparent
    /// titlebar don't reach content), centered on the window buttons' line.
    private func installBar() {
        guard let window, let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return }
        let host = NSHostingView(rootView: PreviewBar(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(host, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            host.topAnchor.constraint(equalTo: titlebar.topAnchor),
            host.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),
        ])
        updateButtonsLine()
    }

    private func updateButtonsLine() {
        guard let close = window?.standardWindowButton(.closeButton), let bar = close.superview else { return }
        let r = close.convert(close.bounds, to: bar)
        let mid = bar.isFlipped ? r.midY : bar.bounds.height - r.midY
        if mid > 0, abs(model.buttonsMidY - mid) > 0.25 { model.buttonsMidY = mid }
        if r.minX > 0, abs(model.buttonsMinX - r.minX) > 0.25 { model.buttonsMinX = r.minX }
    }

    func windowDidResize(_ notification: Notification) { updateButtonsLine() }

    /// A phone page is never drawn smaller: the window is at least as wide
    /// as one with a margin either side. (A short window gives the page
    /// less height; it scrolls.)
    static let minimumContent = NSSize(width: 460, height: 560)

    /// However the window is resized (the SwiftUI content can loosen
    /// `contentMinSize`), never below the minimum.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let least = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContent)).size
        return NSSize(width: max(frameSize.width, least.width), height: max(frameSize.height, least.height))
    }

    /// The window's content at a viewport's own size: a phone with room
    /// either side (enough for the whole titlebar row), a desktop page at
    /// 1280 (both under the titlebar).
    private static func contentSize(for viewport: PreviewViewport) -> NSSize {
        switch viewport {
        case .mobile, .mobileMax: NSSize(width: 540, height: 880)
        case .desktop: NSSize(width: 1280, height: 820)
        }
    }

    /// A new window: a step down and right of the browser window in front,
    /// else centered on the main window's screen (never larger than it).
    private func place(_ window: NSWindow) {
        if let last = PreviewStore.shared.frontWindow?.window, last !== window {
            var frame = last.frame
            frame.origin.x += 28
            frame.origin.y -= 28
            window.setFrame(frame, display: false)
            return
        }
        let main = AppDelegate.shared.windowController?.window
        guard let screen = main?.screen ?? NSScreen.main else { window.center(); return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width - 40)
        frame.size.height = min(frame.height, visible.height - 40)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: false)
    }

    /// The workspace and page, for the Window menu, Mission Control and the
    /// Dock (the titlebar row shows the address).
    private func updateTitle() {
        let page = session.url.map { PreviewSession.display($0) }
        let parts = [workspace.displayName, page].compactMap { $0 }.filter { !$0.isEmpty }
        window?.title = parts.isEmpty ? "Browser" : parts.joined(separator: " — ")
    }

    /// Show the window and bring it forward: the user asked for it.
    func reveal() {
        guard let window else { return }
        session.setWindowOpen(true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The user changed the page's size: the window takes it (keeping its
    /// top-left corner), if it's showing.
    func fitViewport(of changed: PreviewSession) {
        guard changed === session, let window, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let phone = session.viewport.isPhone
        defer { sizedForPhone = phone }
        if !phone {
            // Back to desktop: the window where the user left it.
            if let frame = desktopFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: true, animate: true)
            } else {
                setPageSize(PreviewViewport.desktop.nominal)
            }
            return
        }
        // Leaving desktop: keep its place to come back to.
        if !sizedForPhone { desktopFrame = window.frame }
        let content = Self.contentSize(for: session.viewport)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        let visible = window.screen?.visibleFrame ?? frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(max(frame.height, window.frame.height), visible.height)
        frame.origin.x = min(max(visible.minX, window.frame.minX), visible.maxX - frame.width)
        frame.origin.y = max(visible.minY, window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Side by side was turned on: the window grows to the right (as far as
    /// its screen allows) so the desktop page keeps its width beside the
    /// phone's column; turned off, it gives that room back.
    func fitSideBySide(of changed: PreviewSession) {
        guard changed === session, let window, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let column = session.lastPhone.nominal.width + 40
        var frame = window.frame
        let visible = window.screen?.visibleFrame ?? frame
        frame.size.width += session.sideBySide ? column : -column
        frame.size.width = min(max(frame.width, window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContent)).width), visible.width)
        frame.origin.x = min(max(visible.minX, frame.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Side by side's iPhone changed: the window changes width by as much as
    /// its column did, so the desktop page keeps its size.
    func fitTwinPhone(of changed: PreviewSession, from old: PreviewViewport) {
        guard changed === session, session.sideBySide, let window, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        let visible = window.screen?.visibleFrame ?? frame
        frame.size.width = min(frame.width + session.lastPhone.nominal.width - old.nominal.width, visible.width)
        frame.origin.x = min(max(visible.minX, frame.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Whether the window was last sized for a phone (else it's the
    /// user's desktop window).
    private var sizedForPhone = false

    /// The desktop window's frame when the user last switched to a phone:
    /// switching back puts it there. Kept across launches.
    private var desktopFrame: NSRect? {
        get { UserDefaults.standard.string(forKey: Self.desktopFrameKey).map(NSRectFromString).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue.map(NSStringFromRect), forKey: Self.desktopFrameKey) }
    }
    private static let desktopFrameKey = "PreviewDesktopFrame"

    /// The window's height that isn't page: the titlebar row, the loading
    /// line and the footer.
    private var chromeHeight: CGFloat { model.barHeight * 2 + 2 }

    /// The window sized so the page area is `size` (a desktop preset),
    /// keeping its top-left corner on screen.
    func setPageSize(_ size: CGSize) {
        guard let window, let frame = frame(forPage: size) else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    /// Whether a page of `size` fits this window's screen.
    func fits(page size: CGSize) -> Bool { frame(forPage: size) != nil }

    private func frame(forPage size: CGSize) -> NSRect? {
        guard let window else { return nil }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let wanted = NSSize(width: size.width, height: size.height + chromeHeight)
        guard wanted.width <= visible.width, wanted.height <= visible.height else { return nil }
        var frame = window.frame
        frame.origin.y = frame.maxY - wanted.height
        frame.size = wanted
        frame.origin.x = min(max(visible.minX, frame.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(visible.minY, frame.minY), visible.maxY - frame.height)
        return frame
    }

    // MARK: Window delegate

    /// The close button (and ⌘W) only puts the window away (the user,
    /// 2026-11-26): the page goes on, and its pseudo-tab brings the window
    /// right back. Close Browser (its ≡, or the pseudo-tab's) closes the
    /// page.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Put away, not closed: the page goes on running out of view.
    func hide() {
        session.setCommenting(false)
        session.setWindowOpen(false)
        window?.orderOut(nil)
    }

    /// Really closed (Move Back to Tab, Close Browser): the store lets go.
    func windowWillClose(_ notification: Notification) {
        session.setCommenting(false)
        session.setWindowOpen(false)
        PreviewStore.shared.windowClosed(self)
    }

    // MARK: Commands (the main menu, while this window is key)

    /// ⇧⌘B here hides the window (the main window is in front again);
    /// its pseudo-tab in the tab row brings it back.
    @objc func togglePreview(_ sender: Any?) { hide() }

    /// ⌘W, as the close button: the window goes away, the page doesn't.
    @objc func closeTab(_ sender: Any?) { hide() }

    @objc func togglePreviewSize(_ sender: Any?) { session.toggleViewport() }

    @objc func togglePreviewComment(_ sender: Any?) {
        guard session.commenting || (session.url != nil && session.failure == nil) else { return }
        session.setCommenting(!session.commenting)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePreview(_:)):
            item.title = "Hide Browser"
            return true
        case #selector(closeTab(_:)):
            item.title = "Close Window"
            return true
        case #selector(togglePreviewSize(_:)):
            item.title = session.viewport.isPhone ? "Show at Desktop Size" : "Show at \(session.lastPhone.title) Size"
            return true
        case #selector(togglePreviewComment(_:)):
            item.title = session.commenting ? "Done Commenting" : "Comment on the Page"
            return session.commenting || (session.url != nil && session.failure == nil)
        default:
            return true
        }
    }
}

/// What the window's bars need from the window: its page, and the window
/// buttons' place.
@MainActor
private final class PreviewWindowModel: ObservableObject {
    @Published var shown: (Workspace, PreviewSession)?
    /// The window buttons' center, from the titlebar's top: the row's
    /// controls share their line.
    @Published var buttonsMidY: CGFloat = 0
    /// The close button's left edge: the footer's first control lines up.
    @Published var buttonsMinX: CGFloat = 20
    /// The row's height: the window buttons' band.
    var barHeight: CGFloat { buttonsMidY > 0 ? buttonsMidY * 2 : 38 }
}

private struct PreviewWindowRoot: View {
    @ObservedObject var model: PreviewWindowModel

    var body: some View {
        Group {
            if let (workspace, session) = model.shown {
                VStack(spacing: 0) {
                    PreviewWindowContent(workspace: workspace, session: session)
                    PreviewFooter(model: model, workspace: workspace, session: session)
                }
            } else {
                InspectorEmpty(symbol: "safari", title: "No Workspace", detail: "Each workspace has a browser of its own.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // From right under the titlebar row (not the titlebar's full height).
        .padding(.top, model.barHeight)
        .background(Color.claudeChrome)
        .ignoresSafeArea(edges: .top)
    }
}

/// The page of the workspace shown, under the window's titlebar row.
struct PreviewWindowContent: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession

    var body: some View {
        VStack(spacing: 0) {
            LoadingLine(session: session)
            if session.started {
                PreviewPage(workspace: workspace, session: session)
            } else {
                PreviewStart(workspace: workspace, session: session)
            }
        }
        .background(Color.claudeChrome)
        .background {
            // ⌘L and ⌘R, as in any browser (this window's own keys).
            Button("Address") { session.addressFocusRequest += 1 }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("Reload") { session.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            Button("Back") { session.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
            Button("Forward") { session.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .hidden()
        }
        .onAppear {
            // Pick up where the workspace left off (its first time on view
            // since launch, if Claude hasn't opened a page already).
            if !session.started, !session.address.isEmpty { session.open(session.address) }
        }
    }
}

/// The browser as a tab in the main window (the experiment, Settings ▸
/// Browser ▸ Show In): the page right under the tab row (its back, reload
/// and address are in the tab itself, which widens while selected), and the
/// window's footer (without
/// the workspace menu or Show Conversation: the tab is the workspace's,
/// and its conversations are the tabs beside it). The bars are the tab
/// row's height. The page is on view (`windowOpen`) while the tab shows.
struct BrowserTabPage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession
    let barHeight: CGFloat

    /// Moved to a window of its own: the window has the page.
    private var detached: Bool { workspace.browserTab(session.pageID)?.isDetached == true }

    var body: some View {
        VStack(spacing: 0) {
            // Moved to its window: never take the page back from it on the
            // way out.
            if !detached {
                PreviewWindowContent(workspace: workspace, session: session)
            } else {
                Color.claudeChrome
            }
            PreviewFooter(tabBarHeight: barHeight, workspace: workspace, session: session)
        }
        .background(Color.claudeChrome)
        .onAppear { session.setWindowOpen(true) }
        .onDisappear {
            // Moved to its window: the window has the page by now.
            guard !detached else { return }
            session.setCommenting(false)
            session.setWindowOpen(false)
        }
    }
}

/// The browser window's titlebar row, as the main window's (`TitlebarRow`):
/// on the window buttons' line, in the window's chrome color, with the
/// app's flat bar buttons (a hairline capsule on hover) and its tooltips.
/// Only what a browser has: back and reload, the address (filling the room
/// in a narrow window, centered in a wide one), and opening the page in the
/// user's own browser at the right end. Everything else is in the footer
/// (`PreviewFooter`).
/// Hosted in the titlebar view: views under a transparent titlebar don't
/// get clicks.
private struct PreviewBar: View {
    @ObservedObject var model: PreviewWindowModel

    /// Room for the window buttons and a clear gap after them (about a
    /// window button's width, as Safari leaves).
    static let leading: CGFloat = 90

    var body: some View {
        HStack(spacing: 0) {
            if let (workspace, session) = model.shown {
                PreviewBarControls(session: session, leading: Self.leading)
                    .id(workspace.id)
            } else {
                Spacer()
            }
        }
        .padding(.leading, Self.leading)
        .padding(.trailing, TitlebarRow.edge)
        // The window buttons' band, as the main window's row; the
        // titlebar's extra height below it belongs to the page.
        .frame(height: model.barHeight)
        .background(ZStack { Color.claudeChrome; WindowDragArea() })
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct PreviewBarControls: View {
    @ObservedObject var session: PreviewSession
    /// Where the row starts, from the window's left edge (after the
    /// window buttons): the bar is centered on the whole window.
    let leading: CGFloat
    static let addressMax: CGFloat = 640

    private var workspace: Workspace? {
        WorkspaceStore.shared.workspaces.first { $0.id == session.workspaceID }
    }

    var body: some View {
        GeometryReader { geo in
            // As wide as there's room for, to 640, centered in the window
            // as far as the window buttons allow.
            let w = max(0, min(Self.addressMax, geo.size.width))
            let center = (geo.size.width + leading + TitlebarRow.edge) / 2 - leading
            let x = min(max(0, center - w / 2), geo.size.width - w)
            BrowserAddressBar(session: session, framed: true) {
                guard let workspace else { return [] }
                return [.init(title: "Move Back to Tab", symbol: "rectangle.topthird.inset.filled") { PreviewStore.shared.attach(session.pageID, in: workspace) },
                        .init(title: "Close Browser", symbol: "xmark") { PreviewStore.shared.closeBrowserTab(session.pageID, in: workspace) }]
            }
            .frame(width: w)
            .offset(x: x)
            .frame(height: geo.size.height, alignment: .center)
        }
    }
}

/// The browser's address bar, the same in its window's titlebar and in its
/// selected tab (as Safari's compact tab): back and forward at its start,
/// the address centered, reload (on hover) and the page menu (≡: Open in
/// each browser, then `menu`'s items) at its end. Editing: the whole
/// address, selected, a ring in the accent color, and a button that puts
/// the page's address back.
struct BrowserAddressBar: View {
    @ObservedObject var session: PreviewSession
    /// Its own capsule (in the window; a tab draws the tab's).
    var framed = false
    /// The ≡ menu after Open In: what this place can do.
    let menu: () -> [PopoverMenu.Item]
    @State private var hovering = false
    @State private var editing = false
    @State private var browsers = PreviewBrowser.installed()

    private static let button = CGSize(width: 22, height: 22)

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            Group {
                if editing {
                    Button {
                        session.address = session.url.map { PreviewSession.display($0) } ?? ""
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.toasty(TabStyle.fontSize))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .tooltipText("Cancel (esc)")
                } else {
                    HStack(spacing: 0) {
                        BarIconButton(symbol: "chevron.left", tooltip: Tooltip(title: "Back", shortcut: "⌘["),
                                      glyphSize: Theme.Size.meta, size: Self.button) { session.goBack() }
                            .disabled(!session.canGoBack)
                        BarIconButton(symbol: "chevron.right", tooltip: Tooltip(title: "Forward", shortcut: "⌘]"),
                                      glyphSize: Theme.Size.meta, size: Self.button) { session.goForward() }
                            .disabled(!session.canGoForward)
                    }
                }
            }
            .frame(width: Self.button.width * 2, alignment: .leading)
            PreviewAddressField(session: session, inTab: true) { editing = $0 }
                .frame(maxWidth: .infinity)
            BarIconButton(symbol: session.isLoading ? "xmark" : "arrow.clockwise",
                          tooltip: Tooltip(title: session.isLoading ? "Stop" : "Reload", shortcut: session.isLoading ? nil : "⌘R"),
                          glyphSize: Theme.Size.meta, size: Self.button) {
                if session.isLoading { session.stopLoading() } else { session.reload() }
            }
            .disabled(!session.started)
            .opacity(hovering || editing || session.isLoading ? 1 : 0)
            pageMenu
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(height: TabStyle.height)
        .background { if framed { Capsule().fill(Theme.Fill.selected) } }
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2).opacity(editing ? 1 : 0))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            let now = PreviewBrowser.installed()
            if now != browsers { browsers = now }
        }
    }

    private var pageMenu: some View {
        ClaudePopUp(items: [], makeItems: {
            browsers.map { b in
                PopoverMenu.Item(title: "Open in \(b.name)", symbol: "arrow.up.forward.app", enabled: session.url != nil) {
                    if let url = session.url { b.open(url) }
                }
            } + menu()
        }) { over in
            Image(systemName: "line.3.horizontal")
                .font(.toasty(Theme.Size.meta, .medium))
                .foregroundStyle(over ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: Self.button.width, height: Self.button.height)
                .background(Circle().fill(over ? Theme.Fill.subtle : Color.clear))
        }
        .tooltip(Tooltip(title: "Page Menu", detail: "Open in your own browser, and where the browser lives."))
    }
}

/// The address, in a capsule; ⌘L focuses it, esc puts back the page's.
struct PreviewAddressField: View {
    @ObservedObject var session: PreviewSession
    /// In the browser's tab: no capsule of its own (the tab is the
    /// field). At rest it shows the host, centered; editing, the whole
    /// address, selected (as Safari's compact tabs).
    var inTab = false
    /// Told when editing starts and ends (the tab draws its ring).
    var onEditing: (Bool) -> Void = { _ in }
    @FocusState private var addressFocused: Bool

    var body: some View {
        TextField("localhost:3000", text: $session.address)
            .textFieldStyle(.plain)
            .font(.toasty(inTab ? TabStyle.fontSize : Theme.Size.control, inTab ? .medium : .regular))
            .multilineTextAlignment(inTab ? .center : .leading)
            .focused($addressFocused)
            .onSubmit {
                session.open(session.address)
                addressFocused = false
            }
            .onExitCommand {
                // Put back what the page shows.
                session.address = session.url.map { PreviewSession.display($0) } ?? ""
                addressFocused = false
            }
            .padding(.horizontal, inTab ? 0 : Theme.Space.m)
            .frame(height: TabStyle.height)
            .background(Capsule().fill(inTab ? Color.clear : Theme.Fill.subtle))
            .accessibilityLabel("Address")
            .onChange(of: session.addressFocusRequest) { addressFocused = true }
            .onChange(of: addressFocused) { _, focused in
                onEditing(focused)
                guard inTab else { return }
                if focused {
                    // The whole address, selected, to type over.
                    if let url = session.url { session.address = url.absoluteString }
                    // (After the click that focused it has placed the caret.)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                } else {
                    session.address = session.url.map { PreviewSession.display($0) } ?? session.address
                }
            }
    }

    /// The tab's text at rest: the host (with its port), as Safari shows
    /// a site's name.
    static func host(_ url: URL?) -> String? {
        guard let url, let host = url.host else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// The browser window's footer, laid out as the composer's control row:
/// the workspace on the left (where the composer has its model), the tools
/// in the middle as wide icon buttons, and the page's size on the right
/// (where the composer has send). Drawn as the titlebar row: its buttons,
/// height, edges, surface and divider, so the two bars are one system.
struct PreviewFooter: View {
    /// The window's (nil in a tab: no workspace menu, no Show Conversation,
    /// the tab row's edges).
    fileprivate var model: PreviewWindowModel?
    /// The bar's height in a tab (the tab row's).
    var tabBarHeight: CGFloat = 38
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession
    @ObservedObject private var command = PreviewCommandKey.shared

    /// As the composer's icons: wide hover ovals (Things' toolbar), in the
    /// titlebar row's button style.
    private static let button = CGSize(width: 52, height: TabStyle.height)

    /// The conversation "Show Conversation" goes to: the one whose Claude
    /// last used this browser, else the workspace's selected tab.
    private var conversation: ClaudeConversation? {
        workspace.conversations.first { $0.id == session.lastAgentConversationID } ?? workspace.selected
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                // (The window is one workspace's page: nothing to pick.)
                Color.clear.frame(height: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.xxs) {
                BarIconButton(symbol: "plus.bubble",
                              tooltip: Tooltip(title: session.commenting ? "Done Commenting" : "Comment on the Page", shortcut: "⇧⌘C",
                                               detail: session.commenting ? "Or press esc." : "Click something in the page, or drag over an area, to tell Claude about it."),
                              active: session.commenting, glyphSize: Theme.Size.body, size: Self.button) {
                    session.setCommenting(!session.commenting)
                }
                .disabled(!session.commenting && (session.url == nil || session.failure != nil))
                let other: PreviewViewport = session.viewport.isPhone ? .desktop : session.lastPhone
                BarIconButton(symbol: session.viewport.symbol,
                              tooltip: Tooltip(title: "Switch to \(other.title)", shortcut: "⇧⌘M",
                                               detail: "The size, on the right, chooses which iPhone or presets the desktop window."),
                              glyphSize: Theme.Size.body, size: Self.button) {
                    session.toggleViewport()
                }
                BarIconButton(symbol: "macbook.and.iphone",
                              tooltip: Tooltip(title: session.sideBySide ? "Just the Desktop Page" : "Desktop and \(session.lastPhone.title) Side by Side",
                                               detail: session.sideBySide ? "The iPhone page goes away."
                                                   : "The same page at both sizes, one address: a page either one goes to, the other follows."),
                              active: session.sideBySide, glyphSize: Theme.Size.body, size: Self.button) {
                    session.setSideBySide(!session.sideBySide)
                    PreviewStore.shared.window(for: session)?.fitSideBySide(of: session)
                }
                if session.sideBySide {
                    BarIconButton(symbol: "arrow.up.and.down",
                                  tooltip: Tooltip(title: session.scrollSync ? "Stop Syncing Scroll" : "Sync Scrolling",
                                                   detail: session.scrollSync ? "Each page scrolls on its own."
                                                       : "Scrolling either page scrolls the other to the same place. Or hold ⌘ while scrolling to sync just then."),
                                  active: session.scrollSync, accent: !session.scrollSync && command.held,
                                  glyphSize: Theme.Size.body, size: Self.button) {
                        session.setScrollSync(!session.scrollSync)
                    }
                }
                if model != nil {
                BarIconButton(symbol: "text.bubble",
                              tooltip: Tooltip(title: "Show Conversation",
                                               detail: conversation.map { "“\($0.title)” in the main window\($0.id == session.lastAgentConversationID ? ", the conversation that last used this browser" : "")." }
                                                   ?? "This workspace has no conversation yet."),
                              glyphSize: Theme.Size.body, size: Self.button) {
                    if let conversation { Activity.shared.show(conversation) }
                }
                .disabled(conversation == nil)
                }
            }
            HStack(spacing: Theme.Space.xxs) {
                PreviewSizeMenu(session: session)
                if session.sideBySide, !session.viewport.isPhone {
                    PreviewSizeMenu(session: session, twin: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Edges as the titlebar row's: the workspace name under the close button,
        // the size the row's margin from the right; the same band height,
        // the same divider on the page's side.
        .padding(.leading, model.map { max(0, $0.buttonsMinX - ClaudeChip.padding) } ?? TitlebarRow.edge)
        .padding(.trailing, TitlebarRow.edge)
        .frame(height: model?.barHeight ?? tabBarHeight)
        .background(Theme.Surface.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
    }

}

/// The page's size, at the footer's right end, as the composer's pop-ups:
/// "iPhone · 402 × 874" with a chevron, opening Toasty's own menu. For an
/// iPhone, which iPhone; for a desktop page (as big as the window, sized by
/// dragging it), presets that size the window to them. Dropped in a window
/// too narrow for it.
private struct PreviewSizeMenu: View {
    @ObservedObject var session: PreviewSession
    /// Side by side's second menu: which iPhone the page beside it is.
    var twin = false

    static let desktopPresets = [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900),
                                 CGSize(width: 1920, height: 1080)]

    private var size: CGSize { session.shownPageSize == .zero ? session.pageSize : session.shownPageSize }

    private static func text(_ s: CGSize) -> String { "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))" }

    private var items: [PopoverMenu.Item] {
        if twin {
            return PreviewViewport.allCases.filter(\.isPhone).map { v in
                PopoverMenu.Item(title: v.title, subtitle: Self.text(v.nominal), checked: session.lastPhone == v) {
                    session.setTwinPhone(v)
                }
            }
        }
        if session.viewport.isPhone {
            return PreviewViewport.allCases.filter(\.isPhone).map { v in
                PopoverMenu.Item(title: v.title, subtitle: Self.text(v.nominal), checked: session.viewport == v) {
                    session.setViewport(v, byUser: true)
                }
            }
        }
        // In a tab the desktop page is the tab's room: no presets.
        guard let window = PreviewStore.shared.window(for: session) else {
            return [PopoverMenu.Item(title: "As Big as the Tab", subtitle: "Resize the window, or fill it (⇧⌘F)",
                                     checked: true, enabled: false) {}]
        }
        return Self.desktopPresets.map { p in
            let fits = window.fits(page: p)
            return PopoverMenu.Item(title: Self.text(p), subtitle: fits ? "" : "Larger than this screen",
                                    checked: abs(size.width - p.width) < 1 && abs(size.height - p.height) < 1,
                                    enabled: fits) {
                window.setPageSize(p)
            }
        }
    }

    var body: some View {
        let label = twin ? "\(session.lastPhone.title) · \(Self.text(session.lastPhone.nominal))"
            : "\(session.viewport.title) · \(Self.text(size))"
        // Always shown, whole: the window is never too narrow for it (the
        // workspace chip gives up its room first).
        ClaudePopUp(items: [], makeItems: { items }) { hovering in
                HStack(spacing: Theme.Space.xs + 1) {
                    Text(label)
                        .font(.toasty(Theme.Size.meta).monospacedDigit())
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.toasty(Theme.Glyph.small, .semibold)).opacity(0.6)
                }
                .padding(.horizontal, ClaudeChip.padding)
                .frame(height: TabStyle.height)
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .overlay(Capsule().strokeBorder(hovering ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
        }
        .tooltip(Tooltip(title: twin ? "iPhone Size" : "Page Size",
                         detail: twin || session.viewport.isPhone ? "Which iPhone the page is shown as."
                             : "The desktop page is as big as the window: drag the window, or pick a size here."))
        .accessibilityLabel("Page size: \(label)")
    }
}

/// A browser that Open In offers: the user's default, and whichever of
/// Safari, Chrome and Firefox are installed.
struct PreviewBrowser: Equatable, Identifiable {
    let app: URL
    let name: String
    var id: URL { app }

    private static let known = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox"]

    /// The default browser first, then the others of the three in that
    /// order. Empty only when nothing opens web pages.
    static func installed() -> [PreviewBrowser] {
        let ws = NSWorkspace.shared
        var list: [PreviewBrowser] = []
        func add(_ url: URL?) {
            guard let url, !list.contains(where: { $0.app.standardizedFileURL == url.standardizedFileURL }) else { return }
            list.append(PreviewBrowser(app: url, name: FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")))
        }
        add(ws.urlForApplication(toOpen: URL(string: "http://localhost")!))
        for id in known { add(ws.urlForApplication(withBundleIdentifier: id)) }
        return list
    }


    func open(_ url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Open In: the default browser's icon, with the other installed
/// browsers sliding out to its left on hover. The bar keeps their room, so
/// opening never moves the address.
struct OpenInBrowserButton: View {
    let browsers: [PreviewBrowser]
    let size: CGSize
    let open: (PreviewBrowser) -> Void

    private static let detail = "The same address, in your own browser (its own cookies and logins)."

    var body: some View {
        HoverRevealButtons(count: max(0, browsers.count - 1), size: size, reserve: true) {
            ForEach(Array(browsers.dropFirst())) { browser in
                AppIconButton(app: browser.app, tooltip: Tooltip(title: "Open in \(browser.name)", detail: Self.detail),
                                  size: size) { open(browser) }
            }
        } main: {
            if let main = browsers.first {
                AppIconButton(app: main.app, tooltip: Tooltip(title: "Open in \(main.name)", detail: Self.detail),
                                  size: size) { open(main) }
            } else {
                BarIconButton(symbol: "arrow.up.forward.app", tooltip: Tooltip(title: "Open in Browser", detail: Self.detail),
                              glyphSize: Theme.Size.body, size: size) {}
                    .disabled(true)
            }
        }
    }
}

/// Page loading progress, a line under the titlebar row.
struct LoadingLine: View {
    @ObservedObject var session: PreviewSession

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(Color.accentColor)
                .frame(width: geo.size.width * session.progress, height: 2)
                .opacity(session.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: session.progress)
                .animation(.easeOut(duration: 0.3), value: session.isLoading)
        }
        .frame(height: 2)
    }
}

// MARK: - Start

/// Before any page: where the dev server is, if a terminal said.
struct PreviewStart: View {
    let workspace: Workspace
    @ObservedObject var session: PreviewSession
    @State private var addresses: [String] = []

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "safari")
                .font(.toasty(Theme.Glyph.hero, .light))
                .foregroundStyle(.tertiary)
            Text("Browser")
                .font(.toasty(Theme.Size.control, .medium))
                .foregroundStyle(.secondary)
            Text(addresses.isEmpty ? "Type your dev server's address in the bar above, or ask Claude to open it."
                                   : "Running in this workspace's terminal:")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(addresses, id: \.self) { address in
                Button(address) { session.open(address) }
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { addresses = PreviewStore.shared.localAddresses(in: workspace) }
    }
}

// MARK: - Page

struct PreviewPage: View {
    let workspace: Workspace
    @ObservedObject var session: PreviewSession
    @ObservedObject private var settings = PreviewSettings.shared
    /// The comment confirmation on screen.
    @State private var confirmation: String?
    /// The comment field's height (it grows as the comment does).
    @State private var commentHeight = CommentField.restingHeight
    /// Its width as drawn (wider than `CommentField.width` with a long tab
    /// name in its tab menu).
    @State private var commentWidth = CommentField.width

    var body: some View {
        GeometryReader { whole in
          let twin = session.sideBySide && !session.viewport.isPhone
          let column = twin ? PreviewTwinColumn.width(for: session.lastPhone) : 0
          HStack(spacing: 0) {
          GeometryReader { geo in
            let fit = session.viewport.fit(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.claudeChrome
                if session.windowOpen {
                    PreviewWebHost(session: session, page: fit.page)
                        .frame(width: fit.display.width, height: fit.display.height)
                        .overlay(Rectangle().strokeBorder(Color.claudeSeparator, lineWidth: 0.5)
                            .opacity(fit.display.width < geo.size.width - 1 || fit.display.height < geo.size.height - 1 ? 1 : 0))
                        .offset(x: fit.display.minX, y: fit.display.minY)
                }
                if let failure = session.failure {
                    PreviewFailure(failure: failure) { session.open(failure.address) }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(Color.claudeChrome)
                }
            }
          }
          .frame(width: max(0, whole.size.width - column))
          if twin {
              PreviewTwinColumn(session: session)
                  .frame(width: column)
                  .overlay(alignment: .leading) { Rectangle().fill(Theme.Stroke.barDivider).frame(width: 1) }
          }
          }
          // Over both pages: the comment field by what was picked, in
          // either one, and the confirmation centered on the whole window.
          .overlay(alignment: .topLeading) {
              if session.failure == nil, let pick = session.pick, let fit = pickFit(pick, in: whole.size, column: column) {
                  let field = CommentField.frame(for: pick.rect, point: pick.point, fit: fit, pane: whole.size,
                                                 width: commentWidth, height: commentHeight)
                  CommentField(destination: $settings.commentsTo, workspace: workspace.id, height: $commentHeight,
                               tabs: CommentTabs(workspace: workspace, pinnedID: $session.commentTabID)) { note, images, files in
                      Task { await session.comment(note, images: images, files: files, in: workspace, to: settings.commentDestination) }
                  } cancel: {
                      session.cancelPick()
                  }
                  // At least its width, wider when its controls need it
                  // (a long tab name).
                  .frame(minWidth: min(CommentField.width, max(120, whole.size.width - 16)), alignment: .leading)
                  .fixedSize(horizontal: true, vertical: false)
                  // Its real width, so it's placed all in the window.
                  .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { commentWidth = $0 }
                  .frame(height: field.height)
                  .offset(x: field.minX, y: field.minY)
                  .id(pick)
              }
          }
          .overlay(alignment: .bottom) {
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.toasty(Theme.Size.meta, .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.claudeField).shadow(color: .black.opacity(0.22), radius: 8, y: 2))
                        .overlay(Capsule().strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
                        .padding(.bottom, 14)
                        .transition(.opacity)
                }
          }
        }
        .clipped()
        .task(id: session.commentConfirmation?.id) {
            guard let text = session.commentConfirmation?.text else { return }
            withAnimation(.easeOut(duration: 0.15)) { confirmation = text }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { confirmation = nil }
        }
    }

    /// Where the picked page is drawn, in the whole page area: the main
    /// page on the left, or side by side's iPhone page in its column (laid
    /// out as `PreviewTwinColumn` lays it out). Nil if that page isn't shown.
    private func pickFit(_ pick: PreviewSession.Pick, in whole: CGSize, column: CGFloat) -> PreviewViewport.Fit? {
        guard pick.inTwin else { return session.viewport.fit(in: CGSize(width: whole.width - column, height: whole.height)) }
        guard column > 0 else { return nil }
        let m = PreviewTwinColumn.margin
        let fit = session.lastPhone.fit(in: CGSize(width: max(1, column - m * 2), height: max(1, whole.height - m * 2)))
        return PreviewViewport.Fit(display: fit.display.offsetBy(dx: whole.width - column + m, dy: m), page: fit.page)
    }
}

private struct PreviewFailure: View {
    let failure: PreviewSession.Failure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            InspectorEmpty(symbol: "exclamationmark.triangle", title: "Can't Open \(failure.address)", detail: failure.reason)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry)
                .controlSize(.small)
                .padding(.top, -14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where a comment is typed: a box by the thing that was picked, the
/// composer's own text (so dictation, Right Option, works in it too). Two
/// lines at rest; it grows with the comment, then scrolls. Under it, where
/// the comment goes: Send (to a tab of the conversation, now) or Tee-Up
/// (onto the workspace's list), a choice that stays for the next comment
/// (it's Settings ▸ Browser ▸ Comments); with Send and more than one tab,
/// which tab. Pictures and files can go with it: pasted, dropped on the
/// text, picked with +, or a ⇧⌘0 screenshot (which comes here while a
/// comment is open). Return does what's chosen, Shift-Return starts a new
/// line (the other way round with `ReturnKey.newLine`), Esc drops the pick.
struct CommentField: View {
    @Binding var destination: PreviewSettings.CommentDestination
    /// For dictation's vocabulary (the field isn't a conversation).
    let workspace: UUID
    /// The whole field's height, for placing it by the pick.
    @Binding var height: CGFloat
    /// Which tab it goes to, shown when the workspace has more than one.
    let tabs: CommentTabs?
    /// What Send does, for its tooltip.
    var sendTip = "Send the comment to Claude now, with a screenshot."
    let submit: (_ note: String, _ images: [NSImage], _ files: [URL]) -> Void
    let cancel: () -> Void
    @State private var note = ""
    @State private var images: [NSImage] = []
    @State private var files: [URL] = []
    @State private var textHeight = ClaudeComposer.minHeight
    @State private var focusToken = 0
    /// Dictation's target id for this field (its own, so the conversation's
    /// mic doesn't light up too).
    @State private var dictationID = UUID()
    @AppStorage(ReturnKey.defaultsKey) private var returnKey = ReturnKey.sends
    /// Send or Tee-Up is offered only while the Tee-Up widget is in a space.
    @ObservedObject private var teeUpWidget = TeeUpWidgetPresence.shared

    private static let fontSize = Theme.Size.control
    private static let lineHeight = ceil(ClaudeTypography.lineHeight(.systemFont(ofSize: fontSize), ClaudeTypography.inputLineHeightMultiple))
    /// Two lines at rest, six before it scrolls.
    private static let textMin = lineHeight * 2 + 6
    private static let textMax = lineHeight * 6 + 6
    private static let footer: CGFloat = 24
    private static let padding: CGFloat = 8
    static let restingHeight = textMin + footer + padding * 2 + 6
    /// The row of pictures and files, when there are any (with the room
    /// over it for their remove buttons, and the gap under it).
    private static let thumb: CGFloat = 40
    private static let attachmentsRow = thumb + 5 + 6
    static let width: CGFloat = 420

    /// By the pick: centered on where it was clicked (an area: on its
    /// middle), under it when there's room, else above it; always all in
    /// the pane, by the box's real `width` (it grows past `Self.width`
    /// when its controls need it, a long tab name). A tall element (a
    /// section, the whole page) puts it by the click, not its far edge.
    static func frame(for rect: CGRect, point: CGPoint?, fit: PreviewViewport.Fit, pane: CGSize,
                      width measured: CGFloat, height: CGFloat) -> CGRect {
        let shown = CGRect(x: fit.display.minX + rect.minX * fit.scale, y: fit.display.minY + rect.minY * fit.scale,
                           width: rect.width * fit.scale, height: rect.height * fit.scale)
        let click = point.map { CGPoint(x: fit.display.minX + $0.x * fit.scale, y: fit.display.minY + $0.y * fit.scale) }
        let width = min(max(measured, Self.width), max(120, pane.width - 16))
        let x = min(max(8, (click?.x ?? shown.midX) - width / 2), max(8, pane.width - width - 8))
        var below = shown.maxY, above = shown.minY
        if let click, shown.maxY - click.y > Self.nearEdge { below = click.y + 14; above = click.y - 14 }
        var y = below + 8
        if y + height > pane.height - 8 { y = above - 8 - height }
        y = min(max(8, y), max(8, pane.height - height - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// How far under the click an element's bottom edge can be for the box
    /// to go under the element rather than under the click.
    private static let nearEdge: CGFloat = 60

    private var teeUp: Bool { destination == .teeUp && teeUpWidget.active }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "plus.bubble")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: Self.lineHeight + 6)
                ClaudeComposer(text: $note, height: $textHeight,
                               placeholder: teeUp ? "Comment for Tee-Up" : "Comment for Claude",
                               focusToken: focusToken,
                               onSubmit: { submit(note, images, files) },
                               onEscape: { cancel(); return true },
                               onShiftTab: {},
                               onPasteImage: { images.append($0) },
                               onFiles: add,
                               dictationID: dictationID,
                               dictationWorkspace: workspace,
                               fontSize: Self.fontSize,
                               maxTextHeight: Self.textMax)
                    .frame(height: max(textHeight, Self.textMin), alignment: .top)
            }
            if !images.isEmpty || !files.isEmpty { attachments }
            HStack(spacing: 6) {
                if teeUpWidget.active {
                    CommentDestinationSwitch(destination: $destination, sendTip: sendTip, refocus: { focusToken += 1 }, commit: {
                        // Nothing written yet: the click only picks where it goes.
                        let empty = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && files.isEmpty
                        if empty { return false }
                        submit(note, images, files)
                        return true
                    })
                }
                if let tabs, !teeUp { tabs }
                Spacer(minLength: 4)
                CommentIconButton(symbol: "plus", tip: "Pictures and files to go with the comment. You can also paste or drop them, or press \(ScreenshotCapture.shortcutLabel) for a screenshot.",
                                  label: "Attach Files", action: pick)
                DictationMicButton(conversation: dictationID, width: 30, height: 22)
                Text(returnKey == .sends ? "↩" : "⌘↩").font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary)
                    .fixedSize()
                    .tooltipText(teeUp ? "\(returnKey.send) adds the comment to Tee-Up. \(returnKey.newLine) starts a new line."
                                : "\(returnKey.send) sends the comment to Claude. \(returnKey.newLine) starts a new line.")
            }
            .frame(height: Self.footer)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.padding)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Color.claudeField)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
        .onAppear {
            height = Self.restingHeight
            DispatchQueue.main.async { focusToken += 1 }
        }
        .onChange(of: textHeight) { _, _ in resize() }
        .onChange(of: images.count + files.count) { _, _ in resize() }
    }

    private func resize() {
        height = Self.restingHeight + max(0, textHeight - Self.textMin)
            + (images.isEmpty && files.isEmpty ? 0 : Self.attachmentsRow)
    }

    /// Images go in as pictures, anything else by path (as the composer).
    private func add(_ urls: [URL]) {
        for url in urls {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
                images.append(image)
            } else if !files.contains(url) {
                files.append(url)
            }
        }
        focusToken += 1
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Inside a folder named like a package ("com.example.app") too.
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { response in
            if response == .OK { add(panel.urls) } else { focusToken += 1 }
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.thumb, height: Self.thumb)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.Stroke.border))
                        .overlay(alignment: .topTrailing) {
                            RemoveAttachmentButton(label: "Remove Image") { images.remove(at: i); focusToken += 1 }
                        }
                }
                ForEach(files, id: \.self) { url in
                    AttachedFileChip(url: url, height: Self.thumb)
                        .overlay(alignment: .topTrailing) {
                            RemoveAttachmentButton(label: "Remove \(url.lastPathComponent)") {
                                files.removeAll { $0 == url }
                                focusToken += 1
                            }
                        }
                }
            }
            .padding(.top, 5).padding(.trailing, 5)
        }
        .frame(height: Self.thumb + 5)
        .padding(.leading, 22)
    }
}

/// A small icon button in the comment field's bottom row (the mic's size).
struct CommentIconButton: View {
    let symbol: String
    let tip: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.body))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 22)
                .background(Capsule().strokeBorder(hovering ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .tooltipText(tip)
        .accessibilityLabel(label)
    }
}

/// Send or Tee-Up, side by side in a capsule; the chosen one stands out and
/// is what Return (the send key) does. Clicking one sends the comment
/// there (and makes it Return's); with nothing written yet it only chooses. The keyboard stays
/// in the comment (`refocus`).
struct CommentDestinationSwitch: View {
    @Binding var destination: PreviewSettings.CommentDestination
    let sendTip: String
    let refocus: () -> Void
    /// Sends the comment; false when there's nothing to send.
    let commit: () -> Bool
    @AppStorage(ReturnKey.defaultsKey) private var returnKey = ReturnKey.sends

    var body: some View {
        let highlighted = "\(returnKey.send) does what's highlighted."
        HStack(spacing: 2) {
            segment(.conversation, "Send", "arrow.up", "\(sendTip) \(highlighted)")
            segment(.teeUp, "Tee-Up", "text.badge.plus", "Add the comment to the workspace's Tee-Up list and go on commenting. \(highlighted)")
        }
        .padding(2)
        .background(Capsule().fill(Theme.Fill.subtle))
        .fixedSize()
    }

    private func segment(_ value: PreviewSettings.CommentDestination, _ title: String, _ symbol: String, _ tip: String) -> some View {
        let on = destination == value
        return Button {
            destination = value
            if !commit() { refocus() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.toasty(Theme.Glyph.small, .semibold))
                Text(title).font(.toasty(Theme.Size.meta, .medium))
            }
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(on ? Theme.Fill.pressed : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .tooltipText(tip)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// In the comment field, when the workspace has more than one tab: the tab
/// the comment goes to, which opens a menu: Last Active Tab (the default:
/// whichever tab was last selected in the workspace), then each tab, to pin
/// it for this and later comments. A pin glyph marks a pinned tab. The
/// keyboard stays in the comment (Toasty's own menu doesn't take it).
struct CommentTabs: View {
    @ObservedObject var workspace: Workspace
    /// The pinned tab's id (the browser's session keeps it; a file page
    /// its own).
    @Binding var pinnedID: UUID?

    /// "to [tab ▾]", once the workspace has more than one tab. It watches
    /// the tabs itself, so one opened while the comment is open shows here.
    var body: some View {
        if workspace.conversations.count > 1 {
            HStack(spacing: 6) {
                Text("to").font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary).fixedSize()
                picker
            }
        }
    }

    @ViewBuilder private var picker: some View {
        let pinned = pinnedID.flatMap { id in workspace.conversations.first { $0.id == id } }
        let current = pinned ?? workspace.selected
        let items = [PopoverMenu.Item(title: "Last Active Tab", subtitle: workspace.selected?.title ?? "",
                                      checked: pinned == nil) { pinnedID = nil }]
            + workspace.conversations.map { c in
                PopoverMenu.Item(title: c.title, checked: c.id == pinned?.id) { pinnedID = c.id }
            }
        ClaudePopUp(items: items) { hovering in
            HStack(spacing: 4) {
                if pinned != nil {
                    Image(systemName: "pin.fill").font(.toasty(Theme.Glyph.small)).opacity(0.7)
                }
                Text(Self.short(current?.title ?? "New Tab", 24))
                    .font(.toasty(Theme.Size.meta, .medium))
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down").font(.toasty(Theme.Glyph.small, .semibold)).opacity(0.6)
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(hovering ? Theme.Fill.selected : Theme.Fill.subtle))
            .contentShape(Capsule())
        }
        .fixedSize()
        .tooltipText(pinned == nil ? "Goes to the last active tab. Click to pin a tab."
                                   : "Pinned to this tab for later comments. Click to change.")
        .accessibilityLabel("Comment goes to \(current?.title ?? "a new tab")\(pinned == nil ? "" : ", pinned")")
    }

    private static func short(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Web view host

/// Shows the session's web view at the page's real size, drawn to fit.
private struct PreviewWebHost: NSViewRepresentable {
    let session: PreviewSession
    let page: CGSize

    func makeNSView(context: Context) -> PreviewStage { PreviewStage() }

    func updateNSView(_ stage: PreviewStage, context: Context) {
        stage.show(session, page: page)
    }

    static func dismantleNSView(_ stage: PreviewStage, coordinator: ()) {
        stage.clear()
    }
}

/// Holds a web view laid out at the page's size (what the site sees) and
/// scaled to this view's size (what the window has room for), so a
/// 1280-wide desktop page is still 1280 wide to its CSS in a narrow window,
/// and pictures of it are taken at full size.
final class PreviewStage: NSView {
    private let canvas = PreviewCanvas()
    private weak var session: PreviewSession?
    private var page: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ session: PreviewSession, page: CGSize) {
        self.page = page
        if self.session !== session { clear() }
        self.session = session
        session.stage = self
        let web = session.web()
        if web.superview !== canvas {
            PreviewBackstage.shared.release(web)
            canvas.addSubview(web)
        }
        needsLayout = true
    }

    /// Give the web view back (the window closed): it keeps running, out
    /// of any window, at its nominal size.
    func clear() {
        guard let session else { return }
        self.session = nil
        if session.stage === self { session.stage = nil }
        if let web = session.webView, web.superview === canvas {
            web.removeFromSuperview()
            web.frame = NSRect(origin: .zero, size: session.viewport.nominal)
        }
        session.updateBackstage()
    }

    override func layout() {
        super.layout()
        guard page.width > 0, page.height > 0, bounds.width > 0 else { return }
        canvas.frame = bounds
        canvas.setBoundsOrigin(.zero)
        canvas.setBoundsSize(page)
        session?.webView?.frame = NSRect(origin: .zero, size: page)
        let size = page
        DispatchQueue.main.async { [weak session] in session?.notePageSize(size) }
    }
}

private final class PreviewCanvas: NSView {
    override var isFlipped: Bool { true }
}


// MARK: - Side by side

/// The iPhone page beside the desktop one (side by side): laid out at the
/// phone's real size, drawn smaller when the window is short, centered in
/// a column of its own.
private struct PreviewTwinColumn: View {
    @ObservedObject var session: PreviewSession

    static let margin: CGFloat = 20
    static func width(for phone: PreviewViewport) -> CGFloat { phone.nominal.width + margin * 2 }

    var body: some View {
        GeometryReader { geo in
            let inner = CGSize(width: max(1, geo.size.width - Self.margin * 2), height: max(1, geo.size.height - Self.margin * 2))
            let fit = session.lastPhone.fit(in: inner)
            ZStack(alignment: .topLeading) {
                Color.claudeChrome
                // Nothing beside the desktop page's "Can't Open" (a blank phone).
                if session.windowOpen, session.failure == nil {
                    PreviewTwinHost(session: session, page: fit.page)
                        .frame(width: fit.display.width, height: fit.display.height)
                        .overlay(Rectangle().strokeBorder(Color.claudeSeparator, lineWidth: 0.5))
                        .offset(x: Self.margin + fit.display.minX, y: Self.margin + fit.display.minY)
                }
            }
        }
    }
}

private struct PreviewTwinHost: NSViewRepresentable {
    let session: PreviewSession
    let page: CGSize

    func makeNSView(context: Context) -> PreviewTwinStage { PreviewTwinStage() }

    func updateNSView(_ stage: PreviewTwinStage, context: Context) {
        stage.show(session, page: page)
    }

    static func dismantleNSView(_ stage: PreviewTwinStage, coordinator: ()) {
        stage.clear()
    }
}

/// As `PreviewStage`, for the iPhone page: laid out at the phone's size and
/// scaled to the room it has.
final class PreviewTwinStage: NSView {
    private let canvas = PreviewCanvas()
    private weak var session: PreviewSession?
    private var page: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ session: PreviewSession, page: CGSize) {
        self.page = page
        self.session = session
        // A last update on the way out mustn't make the page again.
        guard session.sideBySide else { clear(); return }
        let web = session.twinWeb()
        if web.superview !== canvas { canvas.addSubview(web) }
        needsLayout = true
    }

    func clear() {
        if let web = session?.twin, web.superview === canvas { web.removeFromSuperview() }
        session = nil
    }

    override func layout() {
        super.layout()
        guard page.width > 0, page.height > 0, bounds.width > 0 else { return }
        canvas.frame = bounds
        canvas.setBoundsOrigin(.zero)
        canvas.setBoundsSize(page)
        session?.twin?.frame = NSRect(origin: .zero, size: page)
    }
}

/// Fades a glyph in and out while `active` (as a symbol's pulse effect,
/// for a glyph that isn't a symbol).
struct PulseWhile: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .onAppear(perform: update)
            .onChange(of: active) { update() }
    }

    private func update() {
        if active {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dim = false }
        }
    }
}
