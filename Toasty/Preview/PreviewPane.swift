import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Window

/// The browser window: one native window, apart from the main window, that
/// shows the browser of whichever workspace is selected in Toasty. Each
/// workspace's browser (`PreviewSession`) is its own: its own cookies,
/// storage and page, running whether this window shows it or not. Switching
/// workspaces only changes which one is on view here; no page is reloaded,
/// navigated or interrupted, and Claude's tools go on reaching their own
/// workspace's browser (`PreviewTools` finds it from the conversation, never
/// from this window).
///
/// Closing the window hides it; every page keeps running. Claude's tools
/// never open it, bring it forward or give it focus. Only the user does
/// that (the titlebar's indicator, ⇧⌘B, a local link clicked in a terminal,
/// ⇧⌘C).
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// What the window shows: the selected workspace's browser.
    private(set) var workspace: Workspace?
    private(set) var session: PreviewSession?
    private let model = PreviewWindowModel()
    private let toolbar = PreviewToolbar()
    private var cancellables: Set<AnyCancellable> = []
    private var titleCancellables: Set<AnyCancellable> = []

    init(store: WorkspaceStore) {
        let size = NSSize(width: 1280, height: 820)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 480, height: 360)
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        window.delegate = self

        let host = NSHostingController(rootView: PreviewWindowRoot(model: model))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = host
        window.setContentSize(size)
        window.toolbar = toolbar.toolbar

        window.setFrameAutosaveName("PreviewWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame PreviewWindow") == nil { place(window) }

        store.$activeID
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak store] _ in self?.show(store?.active) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `workspace`'s browser here instead of the one shown now. The one
    /// shown now is left as it is (only commenting on it ends: the comment
    /// field was in this window).
    private func show(_ next: Workspace?) {
        guard next !== workspace else { return }
        session?.setCommenting(false)
        session?.setWindowOpen(false)
        workspace = next
        session = next.map { PreviewStore.shared.session(for: $0) }
        if window?.isVisible == true { session?.setWindowOpen(true) }
        model.shown = workspace.flatMap { w in session.map { (w, $0) } }
        toolbar.bind(session)
        titleCancellables = []
        if let workspace, let session {
            workspace.$name.combineLatest(session.$url)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _ in self?.updateTitle() }
                .store(in: &titleCancellables)
        }
        updateTitle()
    }

    /// The window's content at a viewport's own size: a phone with a little
    /// room either side, a desktop page at 1280 (both under the toolbar).
    private static func contentSize(for viewport: PreviewViewport) -> NSSize {
        switch viewport {
        case .mobile: NSSize(width: 480, height: 880)
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
    /// Dock (the toolbar shows the address).
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
    func focusAddress() { toolbar.focusAddress() }

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
            item.title = session?.viewport == .mobile ? "Show at Desktop Size" : "Show at Phone Size"
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

/// Which workspace's browser the window shows.
@MainActor
private final class PreviewWindowModel: ObservableObject {
    @Published var shown: (Workspace, PreviewSession)?
}

private struct PreviewWindowRoot: View {
    @ObservedObject var model: PreviewWindowModel

    var body: some View {
        if let (workspace, session) = model.shown {
            // A view of its own per workspace: switching takes the shown
            // page out of the window and puts the other one in, untouched.
            PreviewWindowContent(workspace: workspace, session: session)
                .id(workspace.id)
        } else {
            InspectorEmpty(symbol: "safari", title: "No Workspace", detail: "Each workspace has a browser of its own.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.claudeChrome)
        }
    }
}

/// The page of the workspace shown, under the window's toolbar.
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
        }
        .onAppear {
            // Pick up where the workspace left off (its first time on view
            // since launch, if Claude hasn't opened a page already).
            if !session.started, !session.address.isEmpty { session.open(session.address) }
        }
    }
}

/// The browser window's toolbar, in AppKit: reload, the address (which
/// takes the room there is, down to a narrow phone window), the page's
/// size, and commenting. Bound to the shown workspace's browser.
@MainActor
private final class PreviewToolbar: NSObject, NSToolbarDelegate, NSTextFieldDelegate {
    let toolbar = NSToolbar(identifier: "PreviewWindow")
    private var session: PreviewSession?
    private var cancellables: Set<AnyCancellable> = []

    private static let reload = NSToolbarItem.Identifier("reload")
    private static let address = NSToolbarItem.Identifier("address")
    private static let size = NSToolbarItem.Identifier("size")
    private static let comment = NSToolbarItem.Identifier("comment")

    private var reloadItem: NSToolbarItem?
    private var sizeItem: NSToolbarItemGroup?
    private var commentItem: NSToolbarItem?
    private let field = NSTextField()

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false

        field.placeholderString = "localhost:3000"
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(submitAddress)
        field.setAccessibilityLabel("Address")
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 2000),
        ])
    }

    /// Follow another workspace's browser (or none).
    func bind(_ session: PreviewSession?) {
        self.session = session
        cancellables = []
        // An address half typed for the other workspace doesn't carry over.
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        field.stringValue = session?.address ?? ""
        guard let session else { update(); return }
        session.$address.combineLatest(session.$isLoading, session.$started)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        session.$viewport.combineLatest(session.$commenting, session.$url, session.$failure)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    func focusAddress() {
        guard session != nil else { return }
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func update() {
        field.isEnabled = session != nil
        // Not while the user is typing an address.
        if let session, field.currentEditor() == nil, field.stringValue != session.address { field.stringValue = session.address }
        let loading = session?.isLoading ?? false
        reloadItem?.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
        reloadItem?.label = loading ? "Stop" : "Reload"
        reloadItem?.toolTip = loading ? "Stop" : "Reload (⌘R)"
        reloadItem?.isEnabled = session?.started ?? false
        sizeItem?.isEnabled = session != nil
        if let session { sizeItem?.selectedIndex = PreviewViewport.allCases.firstIndex(of: session.viewport) ?? 0 }
        let commenting = session?.commenting ?? false
        let pageOpen = session.map { $0.url != nil && $0.failure == nil } ?? false
        commentItem?.isEnabled = commenting || pageOpen
        (commentItem?.view as? NSControl)?.isEnabled = commenting || pageOpen
        // Selected (filled) while commenting.
        (commentItem?.view as? NSButton)?.state = commenting ? .on : .off
        commentItem?.toolTip = commenting ? "Done Commenting (⇧⌘C or esc)" : "Comment on the Page (⇧⌘C)"
    }

    // MARK: Actions

    @objc private func submitAddress() {
        session?.open(field.stringValue)
        field.window?.makeFirstResponder(nil)
    }

    @objc private func reloadOrStop() {
        guard let session else { return }
        if session.isLoading { session.stopLoading() } else { session.reload() }
    }

    @objc private func pickSize(_ sender: NSToolbarItemGroup) {
        let all = PreviewViewport.allCases
        guard all.indices.contains(sender.selectedIndex) else { return }
        session?.setViewport(all[sender.selectedIndex], byUser: true)
    }

    @objc private func toggleComment() {
        guard let session else { return }
        session.setCommenting(!session.commenting)
        update()
    }

    /// Esc in the address: put back what the page shows.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        field.stringValue = session?.address ?? ""
        field.window?.makeFirstResponder(nil)
        return true
    }

    // MARK: Toolbar delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.reload, Self.address, Self.size, Self.comment]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case Self.reload:
            item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.label = "Reload"
            item.target = self
            item.action = #selector(reloadOrStop)
            item.isBordered = true
            item.autovalidates = false
            reloadItem = item
        case Self.address:
            item = NSToolbarItem(itemIdentifier: id)
            item.label = "Address"
            item.view = field
            item.isBordered = true
            item.visibilityPriority = .high
        case Self.size:
            let all = PreviewViewport.allCases
            let group = NSToolbarItemGroup(itemIdentifier: id,
                                           images: all.compactMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) },
                                           selectionMode: .selectOne, labels: all.map(\.title),
                                           target: self, action: #selector(pickSize(_:)))
            group.label = "Size"
            group.toolTip = "Phone or Desktop Size (⇧⌘M)"
            sizeItem = group
            item = group
        case Self.comment:
            let toggle = NSButton(image: NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: "Comment")!,
                                  target: self, action: #selector(toggleComment))
            toggle.setButtonType(.pushOnPushOff)
            toggle.bezelStyle = .toolbar
            item = NSToolbarItem(itemIdentifier: id)
            item.label = "Comment"
            item.view = toggle
            commentItem = item
        default:
            return nil
        }
        DispatchQueue.main.async { [weak self] in self?.update() }
        return item
    }
}

/// Page loading progress, a line under the toolbar.
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
                    let field = CommentField.frame(for: pick.rect, fit: fit, pane: geo.size)
                    CommentField(teeUp: settings.commentsTo == .teeUp) { note, other in
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
    static func frame(for rect: CGRect, fit: PreviewViewport.Fit, pane: CGSize) -> CGRect {
        let shown = CGRect(x: fit.display.minX + rect.minX * fit.scale, y: fit.display.minY + rect.minY * fit.scale,
                           width: rect.width * fit.scale, height: rect.height * fit.scale)
        let width = min(300, max(120, pane.width - 16))
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
    }
}

private final class PreviewCanvas: NSView {
    override var isFlipped: Bool { true }
}
