import AppKit
import Combine
import SwiftUI

/// The one Toasty window. It shows one workspace at a time; the others keep
/// running (their conversations and terminals stay alive in the store).
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let store: WorkspaceStore
    let layout = WindowLayout()
    private(set) var split: MainSplitViewController!
    private var titlebarHost: NSView?
    private var titlebarLeading: NSLayoutConstraint?
    /// The sidebar handle's strip, at the conversation's leading edge.
    private var handleHost: NSView?
    private var handleLeading: NSLayoutConstraint?
    /// The inspector handle's strip, at the conversation's trailing edge.
    private var inspectorHandleHost: NSView?
    private var inspectorHandleTrailing: NSLayoutConstraint?
    /// Both handles' bottoms: above the terminal drawer while it's open.
    private var handleBottoms: [NSLayoutConstraint] = []
    /// The Add Widget gallery, over the conversation column.
    private var galleryLeading: NSLayoutConstraint?
    private var galleryTrailing: NSLayoutConstraint?
    private var cancellables: Set<AnyCancellable> = []

    init(store: WorkspaceStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Toasty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 480)
        // An empty standard toolbar, as Things: the taller titlebar puts the
        // window buttons where Things has them and gives the window macOS's
        // larger corner radius for toolbar windows.
        window.toolbar = NSToolbar(identifier: "Toasty")
        window.toolbarStyle = .unified
        window.backgroundColor = .textBackgroundColor
        super.init(window: window)
        window.delegate = self

        split = MainSplitViewController(store: store, layout: layout)
        split.onLayout = { [weak self] in self?.updateTitlebar() }
        // Size the content before handing it to the window, which otherwise
        // shrinks to the split view's fitting size.
        split.view.setFrameSize(NSSize(width: 1280, height: 820))
        window.contentViewController = split

        if let frame = store.windowFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else if let screen = NSScreen.main {
            // First launch: nearly the whole screen, so the conversation gets
            // room next to both side columns.
            let visible = screen.visibleFrame
            let size = NSSize(width: min(visible.width - 40, 1800), height: min(visible.height - 30, 1150))
            window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        } else {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }

        installTitlebar()
        installToast()
        installSidebarHandle()
        installGallery()
        store.selectionChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Titlebar

    /// Put the tab row in the titlebar, right of the workspaces sidebar
    /// (which runs under the window buttons). Views in the titlebar get
    /// clicks; content under a transparent titlebar doesn't.
    private func installTitlebar() {
        guard let titlebar = window?.standardWindowButton(.closeButton)?.superview else { return }
        let host = NSHostingView(rootView: TitlebarRow(store: store, layout: layout))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(host)
        let leading = host.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            host.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            host.topAnchor.constraint(equalTo: titlebar.topAnchor),
            host.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),
        ])
        titlebarHost = host
        titlebarLeading = leading
        updateTitlebar()
    }

    /// The sidebar's handle: a strip along the conversation's left edge
    /// (moved with it in `updateTitlebar`).
    private func installSidebarHandle() {
        guard let content = window?.contentView else { return }
        let host = NSHostingView(rootView: SidebarHandle(store: store))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host, positioned: .above, relativeTo: nil)
        let leading = host.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        let bottom = host.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.handleBottomInset)
        NSLayoutConstraint.activate([
            leading,
            host.widthAnchor.constraint(equalToConstant: 20),
            host.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 40),
            bottom,
        ])
        handleHost = host
        handleLeading = leading

        let right = NSHostingView(rootView: InspectorHandle(store: store, layout: layout))
        right.sizingOptions = []
        right.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(right, positioned: .above, relativeTo: nil)
        let trailing = right.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        let rightBottom = right.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.handleBottomInset)
        NSLayoutConstraint.activate([
            trailing,
            right.widthAnchor.constraint(equalToConstant: 20),
            right.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 40),
            rightBottom,
        ])
        inspectorHandleHost = right
        inspectorHandleTrailing = trailing
        handleBottoms = [bottom, rightBottom]
        // The drawer's tabs and close button are its own: the handles end
        // above it (and its resize edge), following it as it slides.
        DrawerLayout.shared.$shown
            .removeDuplicates()
            .sink { [weak self] shown in self?.placeHandles(aboveDrawer: shown) }
            .store(in: &cancellables)
        updateTitlebar()
    }

    /// The handles' strips end this far over the window's bottom.
    private static let handleBottomInset: CGFloat = 40

    private func placeHandles(aboveDrawer shown: CGFloat) {
        // Clear of the drawer's resize edge (its top 8pt) with a little room.
        let inset = shown > 0 ? shown + 12 : Self.handleBottomInset
        for c in handleBottoms where abs(c.constant + inset) > 0.25 { c.constant = -inset }
    }

    /// The Add Widget gallery: over the conversation column (which it
    /// dims), under the tab row. Clicks pass through while it's closed.
    private func installGallery() {
        guard let content = window?.contentView else { return }
        let host = GalleryHostingView(rootView: WidgetGalleryOverlay(store: store, layout: layout))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host, positioned: .above, relativeTo: nil)
        let leading = host.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        let trailing = host.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        NSLayoutConstraint.activate([
            leading, trailing,
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        galleryLeading = leading
        galleryTrailing = trailing
        updateTitlebar()
    }

    /// The activity toast, floating at the window's top-right below the tab
    /// row. Clicks pass through when there's no toast.
    private func installToast() {
        guard let content = window?.contentView else { return }
        let host = PassthroughHostingView(rootView: ActivityToastView())
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            host.widthAnchor.constraint(equalToConstant: 324),
            host.heightAnchor.constraint(equalToConstant: 130),
        ])
    }

    private func updateTitlebar() {
        let minX = split.contentMinX
        if let titlebarLeading, abs(titlebarLeading.constant - minX) > 0.25 { titlebarLeading.constant = minX }
        // The window buttons sit over the conversation when the sidebar is
        // hidden: the tabs start about 20pt after them (as Safari's).
        let inset: CGFloat = minX < 60 ? 86 - minX : 0
        if layout.leadingInset != inset { layout.leadingInset = inset }
        // The handles start clear of the column dividers' grab areas, so a
        // drag or double-click on a divider reaches it.
        let clear = SidebarHandle.dividerClearance
        if let handleLeading, abs(handleLeading.constant - (minX + clear)) > 0.25 { handleLeading.constant = minX + clear }
        if let content = window?.contentView, let inspectorHandleTrailing {
            let offset = (split.contentMaxX.map { $0 - content.bounds.width } ?? 0) - clear
            if abs(inspectorHandleTrailing.constant - offset) > 0.25 { inspectorHandleTrailing.constant = offset }
        }
        if let galleryLeading, abs(galleryLeading.constant - minX) > 0.25 { galleryLeading.constant = minX }
        if let content = window?.contentView, let galleryTrailing {
            let offset = split.contentMaxX.map { $0 - content.bounds.width } ?? 0
            if abs(galleryTrailing.constant - offset) > 0.25 { galleryTrailing.constant = offset }
        }
        // The row's controls center on the window buttons' line.
        if let button = window?.standardWindowButton(.closeButton), let bar = button.superview {
            let r = button.convert(button.bounds, to: bar)
            let mid = bar.isFlipped ? r.midY : bar.bounds.height - r.midY
            if abs(layout.buttonsMidY - mid) > 0.25 { layout.buttonsMidY = mid }
        }
    }

    private func updateTitle() {
        guard let window else { return }
        if let w = store.active {
            window.title = w.selected.map { "\(w.displayName) — \($0.title)" } ?? w.displayName
        } else {
            window.title = "Toasty"
        }
    }

    // MARK: Window delegate

    /// Text fields (prompt answers, renaming) edit in this field editor:
    /// the standard one, minus the system badge beside the cursor.
    private let fieldEditor: NoAccessoryFieldEditor = {
        let e = NoAccessoryFieldEditor()
        e.isFieldEditor = true
        e.writingToolsBehavior = .none
        return e
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is NSTextField ? fieldEditor : nil
    }

    func windowDidResize(_ notification: Notification) {
        frameChanged()
        // Wider again: columns set aside come back (and any resize the
        // delegate didn't see, such as a full-screen change).
        if let content = window?.contentView { split.applyWidth(content.bounds.width, animated: true) }
    }

    /// Narrowing past what the widgets and a conversation need sets the
    /// widgets aside (they come back as it widens again).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        split.windowWillResize(toWidth: content.width)
        return frameSize
    }
    /// A narrow window squeezes the workspaces; with room again they're
    /// back at their width.
    func windowDidEndLiveResize(_ notification: Notification) { split.applySidebarWidth() }
    func windowDidMove(_ notification: Notification) { frameChanged() }

    private func frameChanged() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        store.windowFrame = window.frame
        store.setNeedsSave()
    }

    // MARK: Focus

    /// Is keyboard focus in a terminal (a Terminal widget)?
    private var terminalFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return store.active?.terminals.contains { $0.isStarted && responder === $0.terminalView } ?? false
    }

    /// Focus the selected terminal, once its widget is on screen.
    func focusTerminal() {
        guard let t = store.active?.selectedTerminal else { return }
        DispatchQueue.main.async { [weak self] in
            if let v = t.terminalView, v.window === self?.window { self?.window?.makeFirstResponder(v) }
        }
    }

    /// The terminal drawer under the conversation (⌘J): open and focus it;
    /// open with the focus elsewhere, focus it; focused, close it.
    @objc func toggleTerminalDrawer(_ sender: Any?) {
        guard let w = store.active else { return }
        if !w.drawerOpen { setTerminalDrawer(open: true) }
        else if !drawerFocused { focusDrawerTerminal() }
        else { setTerminalDrawer(open: false) }
    }

    func setTerminalDrawer(open: Bool) {
        store.active?.setDrawer(open: open)
    }

    var conversationColumnHeight: CGFloat? { ConversationColumnController.current?.columnHeight }

    /// Is keyboard focus in a drawer terminal?
    var drawerFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return store.active?.drawerTerminals.contains { $0.isStarted && responder === $0.terminalView } ?? false
    }

    /// Focus the drawer's terminal, once its view is in the window (a
    /// new one is made by its host a moment after it's selected).
    func focusDrawerTerminal(tries: Int = 10) {
        guard let t = store.active?.selectedDrawerTerminal else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.store.active?.selectedDrawerTerminal === t else { return }
            if let v = t.terminalView, v.window === self.window { self.window?.makeFirstResponder(v) }
            else if tries > 0 { self.focusDrawerTerminal(tries: tries - 1) }
        }
    }

    /// Focus the terminal tab showing in the conversation column.
    func focusTabTerminal() {
        guard let t = store.active?.shownTabTerminal else { return }
        DispatchQueue.main.async { [weak self] in
            if let v = t.terminalView, v.window === self?.window { self?.window?.makeFirstResponder(v) }
        }
    }

    /// ⇧⌘T: a new terminal tab in the top row.
    @objc func newTerminalTab(_ sender: Any?) {
        guard let w = store.active else { return }
        w.newTabTerminal()
        focusTabTerminal()
    }

    /// ⌃`: between the conversation and the last terminal tab (a new one
    /// if there's none).
    @objc func toggleTerminalTab(_ sender: Any?) {
        guard let w = store.active else { return }
        if w.shownTabTerminalID != nil {
            if let c = w.selected { w.select(c) }
        } else if let id = w.lastTabTerminalID ?? w.tabTerminals.first?.id, w.tabTerminals.contains(where: { $0.id == id }) {
            w.showTabTerminal(id)
            focusTabTerminal()
        } else {
            w.newTabTerminal()
            focusTabTerminal()
        }
    }

    // MARK: Commands (main menu)

    @objc func newTab(_ sender: Any?) {
        guard let w = store.active else { store.createWithFolderPicker(); return }
        if terminalFocused {
            w.newTerminal()
            focusTerminal()
        } else if drawerFocused {
            w.newDrawerTerminal()
            focusDrawerTerminal()
        } else {
            w.newConversation()
        }
    }

    @objc func newTerminal(_ sender: Any?) {
        guard let w = store.active else { return }
        // No sidebar terminal: a new one in the drawer.
        guard TerminalLayoutSettings.shared.sidebarTerminal else {
            w.newDrawerTerminal()
            w.setDrawer(open: true)
            focusDrawerTerminal()
            return
        }
        w.newTerminal()
        w.showTerminal()
        focusTerminal()
    }

    /// ⌘W: the focused terminal, else the conversation tab.
    @objc func closeTab(_ sender: Any?) {
        guard let w = store.active else { return }
        if terminalFocused, let t = w.selectedTerminal {
            Activity.shared.confirm(Activity.shared.closeWarning(conversations: [], terminals: [t], action: "close it"),
                                    title: "Close this terminal?", button: "Close Terminal") { [weak self] in
                w.closeTerminal(t.id)
                if !w.terminals.isEmpty { self?.focusTerminal() }
            }
        } else if drawerFocused, let t = w.selectedDrawerTerminal {
            w.requestCloseDrawerTerminal(t.id)
        } else if let t = w.shownTabTerminal {
            w.requestCloseTabTerminal(t.id)
        } else if let c = w.selected {
            w.requestClose(c)
        }
    }

    @objc func selectNextTab(_ sender: Any?) { selectRelativeTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectRelativeTab(-1) }

    private func selectRelativeTab(_ delta: Int) {
        guard let w = store.active else { return }
        if terminalFocused { w.selectTerminalRelative(delta) } else {
            w.selectRelative(delta)
        }
    }

    /// ⌃⌘T: open and focus the terminal over the widgets; collapse it
    /// when it already has focus.
    @objc func toggleTerminal(_ sender: Any?) {
        guard let w = store.active else { return }
        guard TerminalLayoutSettings.shared.sidebarTerminal else { return toggleTerminalDrawer(sender) }
        let open = w.terminalOpen && layout.terminalWidth > 0 && !store.editingWidgets
        if !open {
            if store.editingWidgets { store.endEditingWidgets() }
            w.showTerminal()
            focusTerminal()
        } else if !terminalFocused {
            focusTerminal()
        } else {
            w.hideTerminal()
            window?.makeFirstResponder(nil)
        }
    }

    /// ⌃⌘I and the titlebar button: hide the widgets (the conversation
    /// alone) or bring them back as they were.
    @objc func toggleWidgets(_ sender: Any?) {
        guard let w = store.active else { return }
        let hadTerminalFocus = terminalFocused
        // What's on screen: set aside by a narrow window counts as hidden.
        let shown = layout.terminalWidth > 0
        if shown {
            store.endEditingWidgets()
            w.setWidgets(visible: false)
            if hadTerminalFocus { window?.makeFirstResponder(nil) }
        } else if split.makeRoomForWidgets() {
            w.setWidgets(visible: true)
        } else {
            NSSound.beep()
        }
    }

    /// View ▸ Edit Widgets…: units show, widgets can be removed, resized
    /// and moved, free space offers Add Widget.
    @objc func editWidgets(_ sender: Any?) {
        guard let w = store.active else { return }
        if store.editingWidgets { store.endEditingWidgets(); return }
        revealWidgets(w)
        store.editingWidgets = true
    }

    @objc func addWidget(_ sender: Any?) {
        guard let w = store.active else { return }
        revealWidgets(w)
        WidgetGalleryModel.shared.open()
    }

    /// The widgets on screen: the workspace's setting on, and room made in
    /// a window too narrow for them (`makeRoomForWidgets`).
    func revealWidgets(_ w: Workspace) {
        split.makeRoomForWidgets()
        w.setWidgets(visible: true)
    }

    @objc func newSpace(_ sender: Any?) {
        guard store.active != nil else { return }
        store.newSpace()
    }

    /// ⌃⌘1…9: the nth space.
    @objc func showSpace(_ sender: NSMenuItem) {
        guard let w = store.active, store.spaces.indices.contains(sender.tag) else { return }
        revealWidgets(w)
        w.selectSpace(store.spaces[sender.tag].id)
    }

    @objc func nextSpace(_ sender: Any?) { store.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { store.switchSpace(by: -1) }

    /// ⌃⌘P: a new teed-up prompt, open for typing (on a space with the
    /// Tee-Up widget, if one has it).
    @objc func newTeeUp(_ sender: Any?) {
        guard let w = store.active else { return }
        if let s = store.space(for: w), !s.widgets.contains(where: { $0.kind == .teeUp }),
           let other = store.spaces.first(where: { $0.widgets.contains { $0.kind == .teeUp } }) {
            w.selectSpace(other.id)
        }
        revealWidgets(w)
        w.newTeeUp()
    }

    /// ⇧⌘B (View ▸ Show Browser): back to the browser window as it was
    /// left, on whatever workspace it shows (the user, 2026-11-20: going
    /// back to the browser and showing this workspace's are two things).
    /// Never opened: it opens on this workspace. (Experimental; no menu
    /// item while it's turned off.) From the browser window, the same keys
    /// put it away (`PreviewWindowController`).
    @objc func togglePreview(_ sender: Any?) {
        guard PreviewSettings.shared.enabled else { return }
        PreviewStore.shared.showWindow()
    }

    /// The titlebar's globe: the browser window, showing this workspace's
    /// browser (asked for, so the window switches to it).
    func showWorkspaceBrowser(_ workspace: Workspace) {
        guard PreviewSettings.shared.enabled else { return }
        PreviewStore.shared.showWindow(workspace)
    }

    /// ⇧⌘M: the workspace's page at the other size, phone or desktop.
    @objc func togglePreviewSize(_ sender: Any?) {
        guard let w = store.active, PreviewSettings.shared.enabled else { return }
        PreviewStore.shared.session(for: w).toggleViewport()
    }

    /// ⇧⌘C: comment on the workspace's page, in its browser window.
    @objc func togglePreviewComment(_ sender: Any?) {
        guard let w = store.active, PreviewSettings.shared.enabled else { return }
        let session = PreviewStore.shared.session(for: w)
        guard session.url != nil, session.failure == nil else { return }
        PreviewStore.shared.showWindow(w)
        session.setCommenting(true)
    }

    @objc func toggleWorkspaces(_ sender: Any?) {
        // On screen (a narrow window may have set it aside): hide it;
        // else show it, widening the window if it needs room.
        let shown = !split.sidebarItem.isCollapsed
        if !shown {
            guard split.makeRoomForSidebar() else { NSSound.beep(); return }
        }
        store.sidebarVisible = !shown
        store.setNeedsSave()
        if !shown, store.sidebarVisible { split.applyWidth(split.splitView.bounds.width, animated: true) }
    }

    @objc func newWorkspace(_ sender: Any?) { store.createWithFolderPicker() }
    @objc func renameWorkspace(_ sender: Any?) { store.renameActive() }
    @objc func newHeading(_ sender: Any?) { store.newHeading() }
    @objc func selectNextWorkspace(_ sender: Any?) { store.activateRelative(1) }
    @objc func selectPreviousWorkspace(_ sender: Any?) { store.activateRelative(-1) }
    @objc func jumpToAttention(_ sender: Any?) { store.jumpToAttention() }
    /// ⌘1–9: open the nth notification in the sidebar's list.
    /// ⌘1–9: the nth workspace with something for you (its row shows the
    /// number).
    @objc func openNotification(_ sender: NSMenuItem) {
        if !Activity.shared.showNumbered(sender.tag) { NSSound.beep() }
    }

    @objc func changeWorkspaceFolder(_ sender: Any?) {
        if let id = store.activeID { store.chooseFolder(for: id) }
    }

    @objc func openWorkspaceInFinder(_ sender: Any?) {
        if let w = store.active { NSWorkspace.shared.open(URL(fileURLWithPath: w.folder)) }
    }

    @objc func openWorkspaceInEditor(_ sender: Any?) {
        if let w = store.active { ExternalEditor.shared.openFolder(w.folder) }
    }

    /// ⇧⌘O: the file or diff on screen, in the editor at the line in view.
    @objc func openInEditor(_ sender: Any?) {
        guard let file = shownFile else { return NSSound.beep() }
        ExternalEditor.shared.open(file.url, project: file.project, line: ShownCode.line(), textOnly: true)
    }

    /// The file on the active workspace's page: a diff's (not a deleted
    /// file's), else the file page's.
    private var shownFile: (url: URL, project: String)? {
        guard let w = store.active else { return nil }
        if let diff = w.diffFile {
            return diff.status == .deleted ? nil : (diff.url, w.folder)
        }
        return w.viewedFile.map { ($0, w.folder) }
    }

    @objc func newWorktree(_ sender: Any?) {
        if let id = store.activeID { store.requestNewWorktree(for: id) }
    }

    @objc func removeWorktree(_ sender: Any?) {
        if let id = store.activeID { store.requestRemoveWorktree(id) }
    }

    @objc func closeWorkspace(_ sender: Any?) {
        if let id = store.activeID { store.requestClose(id) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let w = store.active
        switch item.action {
        case #selector(toggleTerminal(_:)) where !TerminalLayoutSettings.shared.sidebarTerminal:
            // The drawer's command (⌘J) does it: this one goes away.
            item.isHidden = true
            return w != nil
        case #selector(toggleTerminal(_:)):
            item.isHidden = false
            item.title = w?.terminalOpen == true && layout.terminalWidth > 0 && !store.editingWidgets
                ? (terminalFocused ? "Collapse Terminal" : "Focus Terminal") : "Open Terminal"
            return w != nil
        case #selector(toggleWidgets(_:)):
            item.title = layout.terminalWidth > 0 ? "Hide Widgets" : "Show Widgets"
            return w != nil
        case #selector(editWidgets(_:)):
            item.title = store.editingWidgets ? "Done Editing Widgets" : "Edit Widgets…"
            return w != nil
        case #selector(addWidget(_:)), #selector(newSpace(_:)), #selector(newTeeUp(_:)):
            return w != nil
        case #selector(nextSpace(_:)), #selector(previousSpace(_:)):
            return w != nil && store.spaces.count > 1
        case #selector(showSpace(_:)):
            let has = store.spaces.indices.contains(item.tag)
            item.isHidden = !has
            if has {
                item.title = "Space \(item.tag + 1)"
                item.state = w.map { store.space(for: $0)?.id == store.spaces[item.tag].id } == true && layout.terminalWidth > 0 ? .on : .off
            }
            return w != nil && has
        case #selector(togglePreview(_:)):
            // No menu items or shortcuts while the browser is turned off.
            item.isHidden = !PreviewSettings.shared.enabled
            item.title = "Show Browser"
            return w != nil && !item.isHidden
        case #selector(togglePreviewSize(_:)):
            item.isHidden = !PreviewSettings.shared.enabled
            guard let w, !item.isHidden else { return false }
            let s = PreviewStore.shared.session(for: w)
            item.title = s.viewport.isPhone ? "Show at Desktop Size" : "Show at \(s.lastPhone.title) Size"
            return true
        case #selector(togglePreviewComment(_:)):
            item.isHidden = !PreviewSettings.shared.enabled
            item.title = "Comment on the Page"
            guard let w, !item.isHidden else { return false }
            let session = PreviewStore.shared.session(for: w)
            return session.url != nil && session.failure == nil
        case #selector(toggleWorkspaces(_:)):
            item.title = split.sidebarItem.isCollapsed ? "Show Workspaces" : "Hide Workspaces"
            return !store.workspaces.isEmpty
        case #selector(openInEditor(_:)):
            let editor = ExternalEditor.shared.editor
            item.title = editor.map { "Open in \($0.name)" } ?? "Open in Default App"
            return shownFile != nil
        case #selector(openWorkspaceInEditor(_:)):
            let editor = ExternalEditor.shared.editor
            item.isHidden = editor == nil
            item.title = editor.map { "Open in \($0.name)" } ?? "Open in Editor"
            return w != nil && editor != nil
        case #selector(closeTab(_:)):
            return terminalFocused ? w?.selectedTerminal != nil : w?.selected != nil
        case #selector(newTerminal(_:)), #selector(renameWorkspace(_:)),
             #selector(openWorkspaceInFinder(_:)), #selector(closeWorkspace(_:)):
            return w != nil
        case #selector(newWorktree(_:)):
            return w.map { Worktrees.isInRepository($0.folder) } ?? false
        case #selector(removeWorktree(_:)):
            return w?.isWorktree == true
        case #selector(changeWorkspaceFolder(_:)):
            return w.map { !$0.isWorktree } ?? false
        case #selector(selectNextWorkspace(_:)), #selector(selectPreviousWorkspace(_:)):
            return store.workspaces.count > 1
        default:
            return true
        }
    }
}

/// The toast's host: takes clicks only while a toast is showing (SwiftUI
/// handles them in the host view itself), so the terminal or conversation
/// below gets them otherwise.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Activity.shared.toast != nil else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window's field editor without the cursor accessory (Siri,
/// dictation, input source badge).
final class NoAccessoryFieldEditor: NSTextView {
    override func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement { .invisible }
}
