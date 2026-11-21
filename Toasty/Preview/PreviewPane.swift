import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Window

/// The browser window: one native window, apart from the main window, that
/// shows one workspace's browser. Each workspace's browser
/// (`PreviewSession`) is its own: its own cookies, storage and page, running
/// whether this window shows it or not. Switching only changes which one is
/// on view here; no page is reloaded, navigated or interrupted, and Claude's
/// tools go on reaching their own workspace's browser (`PreviewTools` finds
/// it from the conversation, never from this window).
///
/// Which workspace it shows is the window's own (the user, 2026-11-20: the
/// main window says which conversation I'm in, the browser which browser I'm
/// inspecting; neither changes the other). Selecting a workspace in Toasty
/// doesn't change it. What does: the workspace menu in its titlebar row, and
/// asking for a workspace's browser from the main window (its compass, ⇧⌘B,
/// ⇧⌘C, a local link clicked in its terminal). It's kept across launches; a
/// workspace that closes gives way to another with a page open.
///
/// Closing the window hides it; every page keeps running. Claude's tools
/// never open it, bring it forward or give it focus. Only the user does
/// that (the titlebar's indicator, ⇧⌘B, a local link clicked in a terminal,
/// ⇧⌘C).
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The workspace whose browser the window shows.
    private(set) var workspace: Workspace?
    private(set) var session: PreviewSession?
    private let model = PreviewWindowModel()
    private var cancellables: Set<AnyCancellable> = []
    private var titleCancellables: Set<AnyCancellable> = []

    init(store: WorkspaceStore) {
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

        let host = NSHostingController(rootView: PreviewWindowRoot(model: model))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = host
        // After the content: a content view controller sets its own limits.
        window.contentMinSize = Self.minimumContent
        window.setContentSize(size)
        installBar()

        window.setFrameAutosaveName("PreviewWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame PreviewWindow") == nil { place(window) }
        // A frame saved smaller than the minimum (restoring skips it).
        let least = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContent)).size
        if window.frame.width < least.width || window.frame.height < least.height {
            var frame = window.frame
            frame.origin.y -= max(0, least.height - frame.height)
            frame.size = NSSize(width: max(frame.width, least.width), height: max(frame.height, least.height))
            window.setFrame(frame, display: false)
        }

        model.choose = { [weak self] in self?.show($0) }

        // The workspace it showed last time, else the one selected in Toasty.
        let saved = UserDefaults.standard.string(forKey: Self.shownKey).flatMap(UUID.init(uuidString:))
        show(store.workspaces.first { $0.id == saved } ?? store.active)

        // The workspace shown was closed: another with a page open, else the
        // one selected in Toasty.
        store.$workspaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] list in
                guard let self, let store, let shown = self.workspace, !list.contains(where: { $0 === shown }) else { return }
                self.show(PreviewStore.shared.workspacesWithPages().first ?? store.active)
            }
            .store(in: &cancellables)
    }

    private static let shownKey = "PreviewWindowWorkspace"

    required init?(coder: NSCoder) { fatalError() }

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

    /// Show `workspace`'s browser here instead of the one shown now. The one
    /// shown now is left as it is (only commenting on it ends: the comment
    /// field was in this window). Toasty's selected workspace is untouched.
    func show(_ next: Workspace?) {
        guard next !== workspace else { return }
        if let next { UserDefaults.standard.set(next.id.uuidString, forKey: Self.shownKey) }
        session?.setCommenting(false)
        session?.setWindowOpen(false)
        workspace = next
        session = next.map { PreviewStore.shared.session(for: $0) }
        if window?.isVisible == true { session?.setWindowOpen(true) }
        model.shown = workspace.flatMap { w in session.map { (w, $0) } }
        titleCancellables = []
        if let workspace, let session {
            workspace.$name.combineLatest(session.$url)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in self?.updateTitle() }
                .store(in: &titleCancellables)
        }
        updateTitle()
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

    /// First time: centered on the main window's screen, at desktop size
    /// (never larger than the screen).
    private func place(_ window: NSWindow) {
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

    /// The workspace shown, for the Window menu, Mission Control and the
    /// Dock (the titlebar row shows the address).
    private func updateTitle() {
        let page = session?.url.map { PreviewSession.display($0) }
        let parts = [workspace?.displayName, page].compactMap { $0 }.filter { !$0.isEmpty }
        window?.title = parts.isEmpty ? "Browser" : parts.joined(separator: " — ")
    }

    /// Show the window and bring it forward: the user asked for it.
    func reveal() {
        guard let window else { return }
        session?.setWindowOpen(true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// ⌘L: the address field, as in any browser.
    func focusAddress() {
        guard session != nil else { return }
        model.focusAddress += 1
    }

    /// The user changed the shown page's size: the window takes it
    /// (keeping its top-left corner), if it's showing.
    func fitViewport(of changed: PreviewSession) {
        guard changed === session, let session, let window, window.isVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        let content = Self.contentSize(for: session.viewport)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        let visible = window.screen?.visibleFrame ?? frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(max(frame.height, window.frame.height), visible.height)
        frame.origin.x = min(max(visible.minX, window.frame.minX), visible.maxX - frame.width)
        frame.origin.y = max(visible.minY, window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Window delegate

    /// Closing only hides: the pages, their consoles and Claude's use of
    /// them go on. The shown page's view is let go of until the window is back.
    func windowWillClose(_ notification: Notification) {
        session?.setCommenting(false)
        session?.setWindowOpen(false)
    }

    // MARK: Commands (the main menu, while this window is key)

    /// ⇧⌘B here puts the browser away (the main window is in front again).
    @objc func togglePreview(_ sender: Any?) { window?.performClose(nil) }

    /// ⌘W closes the browser window (it has no tabs).
    @objc func closeTab(_ sender: Any?) { window?.performClose(nil) }

    @objc func togglePreviewSize(_ sender: Any?) { session?.toggleViewport() }

    @objc func togglePreviewComment(_ sender: Any?) {
        guard let session, session.commenting || (session.url != nil && session.failure == nil) else { return }
        session.setCommenting(!session.commenting)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePreview(_:)):
            item.title = "Hide Browser"
            return true
        case #selector(closeTab(_:)):
            item.title = "Close Browser"
            return true
        case #selector(togglePreviewSize(_:)):
            item.title = session.map { $0.viewport.isPhone ? "Show at Desktop Size" : "Show at \($0.lastPhone.title) Size" } ?? "Show at Desktop Size"
            return session != nil
        case #selector(togglePreviewComment(_:)):
            guard let session else { return false }
            item.title = session.commenting ? "Done Commenting" : "Comment on the Page"
            return session.commenting || (session.url != nil && session.failure == nil)
        default:
            return true
        }
    }
}

/// Which workspace's browser the window shows, and what its titlebar row
/// needs from the window.
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
    /// Bumped by ⌘L: the address field takes the keyboard.
    @Published var focusAddress = 0
    /// A workspace picked in the row's menu.
    var choose: ((Workspace) -> Void)?
}

private struct PreviewWindowRoot: View {
    @ObservedObject var model: PreviewWindowModel

    var body: some View {
        Group {
            if let (workspace, session) = model.shown {
                // A view of its own per workspace: switching takes the shown
                // page out of the window and puts the other one in, untouched.
                VStack(spacing: 0) {
                    PreviewWindowContent(workspace: workspace, session: session)
                    PreviewFooter(model: model, workspace: workspace, session: session)
                }
                .id(workspace.id)
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
private struct PreviewWindowContent: View {
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
            Button("Address") { PreviewStore.shared.presenter?.focusAddress() }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("Reload") { session.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            Button("Back") { session.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
        }
        .onAppear {
            // Pick up where the workspace left off (its first time on view
            // since launch, if Claude hasn't opened a page already).
            if !session.started, !session.address.isEmpty { session.open(session.address) }
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
                PreviewBarControls(model: model, workspace: workspace, session: session)
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
    @ObservedObject var model: PreviewWindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession
    @FocusState private var addressFocused: Bool

    private static let button = CGSize(width: 32, height: TabStyle.height)
    /// Back and reload, side by side.
    private static let navigation = button.width * 2 + Theme.Space.xxs
    /// Between the address and the buttons either side of it.
    private static let gap = Theme.Space.s
    static let addressMax: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
            let place = Self.address(in: geo.size.width)
            ZStack(alignment: .leading) {
                HStack(spacing: Theme.Space.xxs) {
                    BarIconButton(symbol: "chevron.left", tooltip: Tooltip(title: "Back", shortcut: "⌘["),
                                  glyphSize: Theme.Size.body, size: Self.button) { session.goBack() }
                        .disabled(!session.canGoBack)
                    BarIconButton(symbol: session.isLoading ? "xmark" : "arrow.clockwise",
                                  tooltip: Tooltip(title: session.isLoading ? "Stop" : "Reload", shortcut: session.isLoading ? nil : "⌘R"),
                                  glyphSize: Theme.Size.body, size: Self.button) {
                        if session.isLoading { session.stopLoading() } else { session.reload() }
                    }
                    .disabled(!session.started)
                    Spacer(minLength: 0)
                    BarIconButton(symbol: "arrow.up.forward.app",
                                  tooltip: Tooltip(title: "Open in \(PreviewBrowser.name)",
                                                   detail: "The same address, in your own browser (its own cookies and logins)."),
                                  glyphSize: Theme.Size.body, size: Self.button) {
                        if let url = session.url { NSWorkspace.shared.open(url) }
                    }
                    .disabled(session.url == nil)
                }
                addressField
                    .frame(width: place.width)
                    .offset(x: place.x)
            }
            .frame(height: geo.size.height)
        }
    }

    /// Where the address goes in a row `width` wide (the row starts after
    /// the window buttons' room and ends at the right margin): as wide as
    /// there is room for, to 640 points, and as near the window's center as
    /// that room allows. In a narrow window it fills the room between
    /// reload and Open in; in a wide one it's centered in the window.
    static func address(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let first = navigation + gap
        let last = width - button.width - gap
        let w = max(0, min(addressMax, last - first))
        let center = (width + PreviewBar.leading + TitlebarRow.edge) / 2 - PreviewBar.leading
        let x = min(max(first, center - w / 2), last - w)
        return (x, w)
    }

    private var addressField: some View {
        TextField("localhost:3000", text: $session.address)
            .textFieldStyle(.plain)
            .font(.toasty(Theme.Size.control))
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
            .padding(.horizontal, Theme.Space.m)
            .frame(height: TabStyle.height)
            .background(Capsule().fill(Theme.Fill.subtle))
            .accessibilityLabel("Address")
            .onChange(of: model.focusAddress) { addressFocused = true }
    }
}

/// The browser window's footer, laid out as the composer's control row:
/// the workspace on the left (where the composer has its model), the tools
/// in the middle as wide icon buttons, and the page's size on the right
/// (where the composer has send). Drawn as the titlebar row: its buttons,
/// height, edges, surface and divider, so the two bars are one system.
private struct PreviewFooter: View {
    @ObservedObject var model: PreviewWindowModel
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession

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
            PreviewWorkspaceMenu(model: model, workspace: workspace)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.xxs) {
                BarIconButton(symbol: "plus.bubble",
                              tooltip: Tooltip(title: session.commenting ? "Done Commenting" : "Comment on the Page", shortcut: "⇧⌘C",
                                               detail: session.commenting ? "Or press esc." : "Click something in the page, or drag over an area, to tell Claude about it."),
                              active: session.commenting, glyphSize: Theme.Size.body, size: Self.button) {
                    session.setCommenting(!session.commenting)
                }
                .disabled(!session.commenting && (session.url == nil || session.failure != nil))
                PreviewSizeMenu(session: session, size: Self.button)
                BarIconButton(symbol: "text.bubble",
                              tooltip: Tooltip(title: "Show Conversation",
                                               detail: conversation.map { "“\($0.title)” in the main window\($0.id == session.lastAgentConversationID ? ", the conversation that last used this browser" : "")." }
                                                   ?? "This workspace has no conversation yet."),
                              glyphSize: Theme.Size.body, size: Self.button) {
                    if let conversation { Activity.shared.show(conversation) }
                }
                .disabled(conversation == nil)
            }
            ViewThatFits(in: .horizontal) {
                Text(sizeText)
                    .font(.toasty(Theme.Size.meta).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityLabel("Page size \(sizeText)")
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Edges as the titlebar row's: the folder under the close button,
        // the size the row's margin from the right; the same band height,
        // the same divider on the page's side.
        .padding(.leading, max(0, model.buttonsMinX - ClaudeChip.padding))
        .padding(.trailing, TitlebarRow.edge)
        .frame(height: model.barHeight)
        .background(Theme.Surface.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
    }

    /// "390 × 844": the page's size as the site sees it.
    private var sizeText: String {
        let size = session.shownPageSize == .zero ? session.pageSize : session.shownPageSize
        return "\(session.viewport.title) · \(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

/// The page's size, in the footer: its icon in a bar button's place,
/// opening Toasty's own menu of the sizes (the one shown checked).
private struct PreviewSizeMenu: View {
    @ObservedObject var session: PreviewSession
    let size: CGSize

    var body: some View {
        ClaudePopUp(items: PreviewViewport.allCases.map { v in
            let s = v.nominal
            return PopoverMenu.Item(title: v.title,
                                    subtitle: v.isPhone ? "\(Int(s.width)) × \(Int(s.height))" : "\(Int(s.width)) wide",
                                    symbol: v.symbol, checked: session.viewport == v) {
                session.setViewport(v, byUser: true)
            }
        }) { hovering in
            Image(systemName: session.viewport.symbol)
                .font(.toasty(Theme.Size.body, .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: size.width, height: size.height)
                .overlay(Capsule().strokeBorder(hovering ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .tooltip(Tooltip(title: "\(session.viewport.title) Size", shortcut: "⇧⌘M",
                         detail: "Choose iPhone, iPhone Pro Max or desktop. ⇧⌘M switches between desktop and the last iPhone."))
        .accessibilityLabel("Page size: \(session.viewport.title)")
    }
}

/// The user's default browser, for "Open in …".
private enum PreviewBrowser {
    static var name: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://localhost")!) else { return "Browser" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Which workspace's browser the window shows: its name with a chevron, as
/// the composer's pop-ups, opening Toasty's own menu of the workspaces whose
/// browser has a page (the one shown checked). Picking one changes only
/// this window.
private struct PreviewWorkspaceMenu: View {
    @ObservedObject var model: PreviewWindowModel
    @ObservedObject var workspace: Workspace

    private var items: [PopoverMenu.Item] {
        var list = PreviewStore.shared.workspacesWithPages()
        if !list.contains(where: { $0 === workspace }) {
            list = WorkspaceStore.shared.workspaces.filter { w in w === workspace || list.contains { $0 === w } }
        }
        return list.map { w in
            PopoverMenu.Item(title: w.displayName, checked: w === workspace) { model.choose?(w) }
        }
    }

    /// The chip hugs the name; a long one is shortened.
    private static func short(_ name: String) -> String {
        name.count > 24 ? String(name.prefix(23)) + "…" : name
    }

    var body: some View {
        ClaudePopUp(items: items) { hovering in
            HStack(spacing: Theme.Space.xs + 1) {
                Image(systemName: "folder").font(.toasty(Theme.Size.meta, .medium))
                Text(Self.short(workspace.displayName))
                    .font(.toasty(Theme.Size.control, .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.toasty(Theme.Glyph.small, .semibold)).opacity(0.6)
            }
            .padding(.horizontal, ClaudeChip.padding)
            .frame(height: TabStyle.height)
            .fixedSize()
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .overlay(Capsule().strokeBorder(hovering ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .tooltip(Tooltip(title: "Workspace", detail: "Which workspace's browser this window shows. Each has its own page, logins and storage."))
        .accessibilityLabel("Workspace: \(workspace.displayName)")
    }
}

/// Page loading progress, a line under the titlebar row.
private struct LoadingLine: View {
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

// MARK: - Indicator

/// In the main window's titlebar, at the end of the conversation's tabs:
/// the workspace's browser. Tinted while Claude is using it, filled while
/// its window is open; a click brings the window forward. It's how the user
/// sees what Claude does there without the browser taking any room.
struct PreviewIndicator: View {
    @ObservedObject var session: PreviewSession
    @State private var hovering = false

    private var detail: String {
        if session.agentActive { return "Claude is using the browser\(session.url.map { " at \(PreviewSession.display($0))" } ?? "")." }
        if let url = session.url { return "Showing \(PreviewSession.display(url)). Claude can use it whether its window is open or not." }
        return "A browser window for the site you're building. Claude can use it whether its window is open or not."
    }

    var body: some View {
        Button {
            AppDelegate.shared.windowController?.togglePreview(nil)
        } label: {
            Image(systemName: "safari")
                .font(.toasty(Theme.Size.body, .medium))
                .foregroundStyle(session.agentActive ? AnyShapeStyle(Color.accentColor)
                                 : hovering || session.windowOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, options: .repeating, isActive: session.agentActive)
                .frame(width: 32, height: TabStyle.height)
                .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering, active: session.windowOpen))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.25), value: session.agentActive)
        .tooltip(Tooltip(title: "Show Browser", shortcut: "⇧⌘B", detail: detail))
        .accessibilityLabel(session.agentActive ? "Browser, in use by Claude" : "Browser")
        .accessibilityHint("Shows the browser window")
        .padding(.leading, 4)
    }
}

// MARK: - Start

/// Before any page: where the dev server is, if a terminal said.
private struct PreviewStart: View {
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

private struct PreviewPage: View {
    let workspace: Workspace
    @ObservedObject var session: PreviewSession
    @ObservedObject private var settings = PreviewSettings.shared
    @State private var teedUp = false

    var body: some View {
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
                } else if let pick = session.pick {
                    let choosing = settings.commentsTo == .conversation && workspace.conversations.count > 1
                    let field = CommentField.frame(for: pick.rect, fit: fit, pane: geo.size, wide: choosing)
                    CommentField(teeUp: settings.commentsTo == .teeUp,
                                 tabs: choosing ? CommentTabs(workspace: workspace, session: session) : nil) { note, other in
                        let to = other ? settings.commentsTo.other : settings.commentsTo
                        Task { await session.comment(note, in: workspace, to: to) }
                    } cancel: {
                        session.cancelPick()
                    }
                    .frame(width: field.width, height: field.height)
                    .offset(x: field.minX, y: field.minY)
                    .id(pick)
                }
            }
            .overlay(alignment: .bottom) {
                if teedUp {
                    Label("Added to Tee-Up", systemImage: "checkmark")
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
        .task(id: session.teedUpAt) {
            guard session.teedUpAt != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { teedUp = true }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { teedUp = false }
        }
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

/// Where a comment is typed: a small field by the thing that was picked.
/// Return sends it to the conversation or adds it to Tee-Up (Settings ▸
/// Browser), ⇧Return to the other one; Esc drops the pick.
private struct CommentField: View {
    let teeUp: Bool
    /// Which tab it goes to, shown when the workspace has more than one.
    let tabs: CommentTabs?
    /// `other`: ⇧Return, the destination the setting didn't choose.
    let submit: (_ note: String, _ other: Bool) -> Void
    let cancel: () -> Void
    @State private var note = ""
    @FocusState private var focused: Bool

    static let height: CGFloat = 34

    /// Shift held for the Return just pressed: on the keyboard now, or on
    /// the key event being handled.
    private static var shiftHeld: Bool {
        if NSEvent.modifierFlags.contains(.shift) { return true }
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.modifierFlags.contains(.shift)
    }

    /// Under the pick when there's room, else above it; always in the pane.
    /// `wide`: with room for the tab it goes to.
    static func frame(for rect: CGRect, fit: PreviewViewport.Fit, pane: CGSize, wide: Bool = false) -> CGRect {
        let shown = CGRect(x: fit.display.minX + rect.minX * fit.scale, y: fit.display.minY + rect.minY * fit.scale,
                           width: rect.width * fit.scale, height: rect.height * fit.scale)
        let width = min(wide ? 400 : 300, max(120, pane.width - 16))
        let x = min(max(8, shown.midX - width / 2), max(8, pane.width - width - 8))
        var y = shown.maxY + 8
        if y + height > pane.height - 8 { y = shown.minY - 8 - height }
        y = min(max(8, y), max(8, pane.height - height - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.bubble")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(Color.accentColor)
            TextField(teeUp ? "Comment for Tee-Up" : "Comment for Claude", text: $note)
                .textFieldStyle(.plain)
                .font(.toasty(Theme.Size.control))
                .focused($focused)
                .onSubmit { submit(note, Self.shiftHeld) }
                .onExitCommand(perform: cancel)
            if let tabs { tabs.layoutPriority(1) }
            Text("↩").font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary)
                .tooltipText(teeUp ? "Return adds the comment to Tee-Up. Shift-Return sends it to Claude now."
                            : "Return sends the comment to Claude. Shift-Return adds it to Tee-Up instead.")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Color.claudeField)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// In the comment field, when the workspace has more than one tab: the tab
/// the comment goes to, which opens a menu of the workspace's tabs. The
/// keyboard stays in the comment (Toasty's own menu doesn't take it).
private struct CommentTabs: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession

    var body: some View {
        let current = session.commentTab(in: workspace)
        ClaudePopUp(items: workspace.conversations.map { c in
            PopoverMenu.Item(title: c.title, checked: c.id == current?.id) { session.commentTabID = c.id }
        }) { hovering in
            HStack(spacing: 4) {
                Text(current?.title ?? "New Tab")
                    .font(.toasty(Theme.Size.meta, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.toasty(Theme.Glyph.small, .semibold)).opacity(0.6)
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(hovering ? Theme.Fill.selected : Theme.Fill.subtle))
            .contentShape(Capsule())
        }
        .fixedSize(horizontal: false, vertical: true)
        .tooltipText("The tab this comment goes to")
        .accessibilityLabel("Comment goes to \(current?.title ?? "a new tab")")
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
