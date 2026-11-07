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
        // An empty compact toolbar gives the titlebar the standard height of
        // a Mac app with tabs in its toolbar (Safari, Xcode).
        window.toolbar = NSToolbar(identifier: "Toasty")
        window.toolbarStyle = .unifiedCompact
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
        // The window buttons sit over the conversation when the sidebar is hidden.
        let inset: CGFloat = minX < 60 ? 76 - minX : 0
        if layout.leadingInset != inset { layout.leadingInset = inset }
    }

    private func updateTitle() {
        guard let window else { return }
        if let w = store.active {
            window.title = w.selected.map { "\(w.name) — \($0.title)" } ?? w.name
        } else {
            window.title = "Toasty"
        }
    }

    // MARK: Window delegate

    func windowDidResize(_ notification: Notification) { frameChanged() }
    func windowDidMove(_ notification: Notification) { frameChanged() }

    private func frameChanged() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        store.windowFrame = window.frame
        store.setNeedsSave()
    }

    // MARK: Focus

    /// Is keyboard focus in the terminal column?
    private var terminalFocused: Bool { split.terminalColumn.isFocused }

    func focusTerminal() {
        split.terminalColumn.focus()
    }

    // MARK: Commands (main menu)

    @objc func newTab(_ sender: Any?) {
        guard let w = store.active else { store.createWithFolderPicker(); return }
        if terminalFocused {
            w.newTerminal()
            focusTerminal()
        } else {
            w.newConversation()
        }
    }

    @objc func newTerminal(_ sender: Any?) {
        guard let w = store.active else { return }
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
                if w.terminalVisible { self?.focusTerminal() }
            }
        } else if let c = w.selected {
            w.requestClose(c)
        }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let w = store.active else { return }
        if terminalFocused {
            let i = sender.tag == 9 ? w.terminals.count - 1 : sender.tag - 1
            if w.terminals.indices.contains(i) { w.selectTerminal(w.terminals[i].id) }
        } else {
            w.select(index: sender.tag == 9 ? w.conversations.count - 1 : sender.tag - 1)
        }
    }

    @objc func selectNextTab(_ sender: Any?) { selectRelativeTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { selectRelativeTab(-1) }

    private func selectRelativeTab(_ delta: Int) {
        guard let w = store.active else { return }
        if terminalFocused { w.selectTerminalRelative(delta) } else { w.selectRelative(delta) }
    }

    /// ⌃⌘T: show and focus the terminal; hide it when it already has focus.
    @objc func toggleTerminal(_ sender: Any?) {
        guard let w = store.active else { return }
        if !w.terminalVisible {
            w.showTerminal()
            DispatchQueue.main.async { self.focusTerminal() }
        } else if !terminalFocused, sender is NSMenuItem {
            focusTerminal()
        } else {
            let hadFocus = terminalFocused
            w.hideTerminal()
            if hadFocus { window?.makeFirstResponder(nil) }
        }
    }

    /// ⌃⌘I: show or hide the inspector (the top of the right column).
    @objc func toggleInspector(_ sender: Any?) {
        guard let w = store.active else { return }
        if w.inspectorVisible { w.hideInspector() } else { w.showInspector() }
    }

    /// ⌃⌘1…3: show an inspector tab.
    @objc func showInspectorTab(_ sender: NSMenuItem) {
        guard let w = store.active, InspectorTab.allCases.indices.contains(sender.tag) else { return }
        w.showInspector(InspectorTab.allCases[sender.tag])
    }

    /// ⌥⌘0 and the titlebar button: the whole right column.
    @objc func toggleRightColumn(_ sender: Any?) {
        guard let w = store.active else { return }
        let hadTerminalFocus = terminalFocused
        w.toggleRightColumn()
        if hadTerminalFocus, !w.terminalVisible { window?.makeFirstResponder(nil) }
    }

    @objc func toggleWorkspaces(_ sender: Any?) {
        store.sidebarVisible.toggle()
        store.setNeedsSave()
    }

    @objc func newWorkspace(_ sender: Any?) { store.createWithFolderPicker() }
    @objc func renameWorkspace(_ sender: Any?) { store.renameActive() }
    @objc func selectNextWorkspace(_ sender: Any?) { store.activateRelative(1) }
    @objc func selectPreviousWorkspace(_ sender: Any?) { store.activateRelative(-1) }
    @objc func selectWorkspaceByNumber(_ sender: NSMenuItem) { store.activate(index: sender.tag - 1) }
    @objc func jumpToAttention(_ sender: Any?) { store.jumpToAttention() }

    @objc func changeWorkspaceFolder(_ sender: Any?) {
        if let id = store.activeID { store.chooseFolder(for: id) }
    }

    @objc func openWorkspaceInFinder(_ sender: Any?) {
        if let w = store.active { NSWorkspace.shared.open(URL(fileURLWithPath: w.folder)) }
    }

    @objc func importFromMostty(_ sender: Any?) { MosttyImport.present(store: store) }

    @objc func closeWorkspace(_ sender: Any?) {
        if let id = store.activeID { store.requestClose(id) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let w = store.active
        switch item.action {
        case #selector(toggleTerminal(_:)):
            item.title = w?.terminalVisible == true ? "Hide Terminal" : "Show Terminal"
            return w != nil
        case #selector(toggleInspector(_:)):
            item.title = w?.inspectorVisible == true ? "Hide Inspector" : "Show Inspector"
            return w != nil
        case #selector(showInspectorTab(_:)):
            item.state = w?.inspectorVisible == true && InspectorTab.allCases.indices.contains(item.tag)
                && w?.inspectorTab == InspectorTab.allCases[item.tag] ? .on : .off
            return w != nil
        case #selector(toggleRightColumn(_:)):
            item.title = w?.rightColumnVisible == true ? "Hide Inspector and Terminal" : "Show Inspector and Terminal"
            return w != nil
        case #selector(toggleWorkspaces(_:)):
            item.title = store.sidebarVisible ? "Hide Workspaces" : "Show Workspaces"
            return true
        case #selector(closeTab(_:)):
            return terminalFocused ? w?.selectedTerminal != nil : w?.selected != nil
        case #selector(selectTabByNumber(_:)):
            return w != nil
        case #selector(selectWorkspaceByNumber(_:)):
            return store.workspaces.indices.contains(item.tag - 1)
        case #selector(newTerminal(_:)), #selector(renameWorkspace(_:)), #selector(changeWorkspaceFolder(_:)),
             #selector(openWorkspaceInFinder(_:)), #selector(closeWorkspace(_:)):
            return w != nil
        case #selector(importFromMostty(_:)):
            return MosttyImport.isAvailable
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
