import AppKit
import Combine
import SwiftUI

/// Workspaces sidebar · conversation · right column, as a real split view:
/// the sidebar collapses (⇧⌘S); the right column (inspector over terminals)
/// shows when either half does and keeps a width per workspace.
final class MainSplitViewController: NSSplitViewController {
    let store: WorkspaceStore
    let layout: WindowLayout
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var contentItem: NSSplitViewItem!
    private(set) var terminalItem: NSSplitViewItem!
    let rightColumn: RightColumnController
    var terminalColumn: TerminalColumnController { rightColumn.terminalColumn }

    /// Column frames changed (the titlebar row follows them).
    var onLayout: (() -> Void)?

    static let minConversation: CGFloat = 440
    static let minTerminal: CGFloat = 280

    private var cancellables: Set<AnyCancellable> = []
    private var workspaceCancellables: Set<AnyCancellable> = []
    /// Applying a workspace's layout (not the user dragging the divider).
    private var applying = false
    private var shownWorkspace: UUID?
    private var sidebarAnimating = false
    /// The preview's page has the whole window and this split view is the
    /// drawer over it (`PreviewDrawer`, `MainContainerController`): the
    /// workspaces and the conversation, with no right column.
    private(set) var drawerMode = false
    /// Asked before a workspace's right column is laid out: whether the
    /// drawer has it instead (the answer arrives through `setDrawerMode`).
    var resolveDrawer: (() -> Void)?
    private var terminalAnimating = false

    init(store: WorkspaceStore, layout: WindowLayout) {
        self.store = store
        self.layout = layout
        rightColumn = RightColumnController(store: store)
        super.init(nibName: nil, bundle: nil)
        splitView = HairlineSplitView()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        super.viewDidLoad()

        let sidebar = NSHostingController(rootView: WorkspaceSidebarView(store: store))
        sidebar.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !store.sidebarVisible

        let content = ConversationColumnController(store: store)
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = Self.minConversation
        contentItem.holdingPriority = .init(249)

        terminalItem = NSSplitViewItem(viewController: rightColumn)
        terminalItem.minimumThickness = Self.minTerminal
        terminalItem.canCollapse = true
        terminalItem.holdingPriority = .init(255)
        terminalItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(terminalItem)
        // While the window resizes beside the preview it's the right column
        // that changes width, and `splitViewDidResizeSubviews` arrives before
        // its frame is set: the titlebar row would sit over the old width.
        rightColumn.onLayout = { [weak self] in self?.layoutChanged() }

        store.$activeID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showActiveWorkspace() }
            .store(in: &cancellables)
        store.$sidebarVisible
            .removeDuplicates()
            .sink { [weak self] visible in self?.applySidebar(wanted: visible) }
            .store(in: &cancellables)
    }

    /// Show the sidebar if the user wants it. In the drawer the workspaces
    /// always come along, wanted beside the conversation or not.
    private func applySidebar(wanted: Bool? = nil, animated: Bool = true) {
        guard isViewLoaded else { return }
        let visible = drawerMode || (wanted ?? store.sidebarVisible)
        guard sidebarItem.isCollapsed == visible else { return }
        guard animated, view.window != nil else {
            sidebarItem.isCollapsed = !visible
            applySidebarWidth()
            return
        }
        sidebarAnimating = true
        NSAnimationContext.runAnimationGroup { _ in
            self.sidebarItem.animator().isCollapsed = !visible
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.sidebarAnimating = false
                self?.applySidebarWidth()
                self?.layoutChanged()
            }
        }
    }

    /// The page takes the whole window (or gives it back): at once, since
    /// the page changes size with it.
    func setDrawerMode(_ on: Bool) {
        guard on != drawerMode else { return }
        drawerMode = on
        applying = true
        applySidebar(animated: false)
        applySidebarWidth()
        if let w = store.active {
            rightColumn.apply(w, animated: false)
            setTerminal(visible: columnVisible(for: w), animated: false, width: columnWidth(for: w))
            if !on, columnVisible(for: w) {
                // Opened at once, the column is laid out against the
                // conversation's old width: place its edge once it's there.
                splitView.layoutSubtreeIfNeeded()
                setTerminal(visible: true, animated: false, width: columnWidth(for: w))
            }
        }
        applying = false
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySidebarWidth()
        showActiveWorkspace()
    }

    /// The workspaces at the width the user gave them. The split view
    /// brings a collapsed sidebar back narrower, and squeezes it when the
    /// columns beside it change, so this follows every such change: only
    /// the user dragging its edge makes it another width.
    func applySidebarWidth() {
        guard isViewLoaded, !sidebarItem.isCollapsed, !sidebarAnimating, view.window?.inLiveResize != true else { return }
        let w = min(max(store.sidebarWidth, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
        guard abs(sidebarItem.viewController.view.frame.width - w) > 0.5 else { return }
        let was = applying
        applying = true
        defer { applying = was }
        splitView.setPosition(w, ofDividerAt: 0)
    }

    /// Show the active workspace's terminal column (its width, visibility
    /// and selected terminal), and follow its changes.
    private func showActiveWorkspace() {
        guard isViewLoaded, view.window != nil else { return }
        let w = store.active
        guard w?.id != shownWorkspace || workspaceCancellables.isEmpty else { return }
        shownWorkspace = w?.id
        workspaceCancellables = []
        guard let w else {
            terminalColumn.show(nil)
            rightColumn.apply(nil, animated: false)
            setTerminal(visible: false, animated: false)
            resolveDrawer?()
            return
        }
        resolveDrawer?()
        rightColumn.apply(w, animated: false)
        setTerminal(visible: columnVisible(for: w), animated: false, width: columnWidth(for: w))
        terminalColumn.show(w.terminalVisible ? w.selectedTerminal : nil)

        // Either half of the right column showing or hiding, or the preview
        // taking the column over.
        w.$terminalVisible.combineLatest(w.$inspectorVisible, w.$previewVisible)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak w] _ in
                guard let self, let w else { return }
                if w.terminalVisible { self.terminalColumn.show(w.selectedTerminal ?? w.terminals.first) }
                self.resolveDrawer?()
                let columnChanges = self.terminalItem.isCollapsed == self.columnVisible(for: w)
                let swaps = self.rightColumn.showsPreview != w.previewShowing
                // Within a shown column, the halves animate; a column that
                // opens or closes (or changes hands) takes its new halves with it.
                self.rightColumn.apply(w, animated: !columnChanges && !swaps)
                self.setTerminal(visible: self.columnVisible(for: w), animated: true, width: self.columnWidth(for: w))
            }
            .store(in: &workspaceCancellables)
        w.$selectedTerminalID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self, weak w] id in
                guard let self, let w else { return }
                let focused = self.terminalColumn.isFocused
                self.terminalColumn.show(w.terminals.first { $0.id == id })
                if focused { self.terminalColumn.focus() }
            }
            .store(in: &workspaceCancellables)
    }

    /// The preview takes all the room there is (the conversation keeps its
    /// minimum); the inspector and terminal keep the width the user gave them.
    /// The right column shows, unless its page has the whole window.
    private func columnVisible(for w: Workspace) -> Bool {
        w.rightColumnVisible && !drawerMode
    }

    private func columnWidth(for w: Workspace) -> CGFloat {
        guard w.previewShowing else { return store.rightColumnWidth }
        return previewIsPhone(w) ? PreviewSettings.shared.phoneColumnWidth : 100_000
    }

    /// The preview has the column at phone size: a sidebar of its own
    /// width, with the conversation getting the rest.
    private func previewIsPhone(_ w: Workspace) -> Bool {
        w.previewShowing && PreviewStore.shared.session(for: w).viewport == .mobile
    }

    /// The page changed size (phone or desktop): its column follows.
    func applyColumn() {
        guard isViewLoaded, view.window != nil, let w = store.active else { return }
        setTerminal(visible: columnVisible(for: w), animated: false, width: columnWidth(for: w))
    }

    private func setTerminal(visible: Bool, animated: Bool, width: CGFloat? = nil) {
        let was = applying
        applying = true
        defer { applying = was }
        // Resizing the window: the conversation takes the change, except
        // beside a desktop page, which keeps it at its minimum.
        let previewing = store.active.map { $0.previewShowing && !previewIsPhone($0) } ?? false
        contentItem.holdingPriority = .init(previewing ? 256 : 249)
        if visible, let width {
            let total = splitView.bounds.width - (sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width)
            let w = min(max(Self.minTerminal, width), max(Self.minTerminal, total - Self.minConversation))
            if terminalItem.isCollapsed {
                // Expand at the workspace's width.
                rightColumn.view.setFrameSize(NSSize(width: w, height: rightColumn.view.frame.height))
            } else {
                splitView.setPosition(splitView.bounds.width - w - splitView.dividerThickness, ofDividerAt: 1)
            }
        }
        if terminalItem.isCollapsed == visible {
            if animated {
                terminalAnimating = true
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.allowsImplicitAnimation = true
                    terminalItem.animator().isCollapsed = !visible
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.terminalAnimating = false
                        self?.applySidebarWidth()
                        self?.layoutChanged()
                    }
                }
            } else {
                terminalItem.isCollapsed = !visible
            }
        }
        if !terminalAnimating { applySidebarWidth() }
        layoutChanged()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        layoutChanged()
        guard !applying, let w = store.active else { return }
        // The user dragged the column's divider: remember the width.
        if !terminalAnimating, !drawerMode, !terminalItem.isCollapsed, w.rightColumnVisible, !w.previewShowing {
            let width = rightColumn.view.frame.width
            if abs(width - store.rightColumnWidth) > 0.5, width >= Self.minTerminal {
                store.rightColumnWidth = width
                store.setNeedsSave()
            }
        }
        // The user dragged the edge of the preview's column at phone size:
        // that width is its own.
        if !terminalAnimating, !drawerMode, !terminalItem.isCollapsed, previewIsPhone(w), draggingColumnEdge {
            let width = rightColumn.view.frame.width
            if abs(width - PreviewSettings.shared.phoneColumnWidth) > 0.5, width >= Self.minTerminal {
                PreviewSettings.shared.phoneColumnWidth = width
            }
        }
        // The user dragged the sidebar's edge: remember its width. Not a
        // drag of anything else (the window's edge, the other divider),
        // which can squeeze the sidebar without being asked to.
        if !sidebarAnimating, !sidebarItem.isCollapsed, draggingSidebarEdge {
            let width = sidebarItem.viewController.view.frame.width
            if abs(width - store.sidebarWidth) > 0.5 {
                store.sidebarWidth = width
                store.setNeedsSave()
                // The drawer is as wide as what's in it.
                if drawerMode { resolveDrawer?() }
            }
        }
        // The user collapsed the sidebar by dragging it closed.
        let sidebarShown = !sidebarItem.isCollapsed
        if !sidebarAnimating, !drawerMode, sidebarShown != store.sidebarVisible {
            store.sidebarVisible = sidebarShown
            store.setNeedsSave()
        }
    }

    /// The mouse is down and at the sidebar's edge: the user is dragging
    /// it. (Asked of the mouse itself, not of the event or the split view's
    /// notification, which differ between kinds of sidebar.) Held past its
    /// narrowest or widest, the pointer is beyond the edge on that side.
    private var draggingSidebarEdge: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, let window = view.window else { return false }
        let side = sidebarItem.viewController.view
        let edge = side.convert(side.bounds, to: nil).maxX
        let x = window.mouseLocationOutsideOfEventStream.x
        if abs(x - edge) <= 16 { return true }
        let width = side.frame.width
        return (x < edge && width <= sidebarItem.minimumThickness + 0.5)
            || (x > edge && width >= sidebarItem.maximumThickness - 0.5 && x < edge + 200)
    }

    /// The mouse is down at the right column's edge.
    private var draggingColumnEdge: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, let window = view.window else { return false }
        let edge = rightColumn.view.convert(rightColumn.view.bounds, to: nil).minX
        return abs(window.mouseLocationOutsideOfEventStream.x - edge) <= 16
    }

    /// Something outside the split view moved what the titlebar row follows.
    func noteLayout() { layoutChanged() }

    private func layoutChanged() {
        var width = terminalItem.isCollapsed ? 0 : rightColumn.view.frame.width
        if drawerMode, let total = view.superview?.bounds.width {
            // The preview's controls sit over the page: what shows of it
            // right of the drawer, or all of it.
            width = PreviewDrawer.shared.open ? max(0, total - view.frame.width) : total
        }
        if abs(layout.terminalWidth - width) > 0.25 { layout.terminalWidth = width }
        onLayout?()
    }

    /// Left edge of the conversation column, in window coordinates.
    var contentMinX: CGFloat {
        guard let v = contentItem?.viewController.view, v.window != nil else { return 0 }
        return v.convert(v.bounds, to: nil).minX
    }
}

/// A 0.5pt divider in the separator color with a wider grab area.
final class HairlineSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0.5 }
    override var dividerColor: NSColor { .separatorColor }
}

extension MainSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let r = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return r.insetBy(dx: -4, dy: 0)
    }
}

/// The right column: the inspector over the terminals, each half
/// collapsible, their divider kept per workspace.
final class RightColumnController: NSSplitViewController {
    let store: WorkspaceStore
    let terminalColumn: TerminalColumnController
    private(set) var inspectorItem: NSSplitViewItem!
    private(set) var terminalItem: NSSplitViewItem!
    /// The preview browser (experimental): instead of both halves.
    private(set) var previewItem: NSSplitViewItem!
    private(set) var showsPreview = false
    private var applying = false
    private weak var shown: Workspace?
    /// The column was laid out (its width is final).
    var onLayout: (() -> Void)?

    static let minInspector: CGFloat = 150
    static let minTerminal: CGFloat = 120

    init(store: WorkspaceStore) {
        self.store = store
        terminalColumn = TerminalColumnController(store: store)
        super.init(nibName: nil, bundle: nil)
        splitView = HairlineSplitView()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        super.viewDidLoad()

        let inspector = NSHostingController(rootView: InspectorPane(store: store))
        inspector.sizingOptions = []
        inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = Self.minInspector
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .init(250)

        terminalItem = NSSplitViewItem(viewController: terminalColumn)
        terminalItem.minimumThickness = Self.minTerminal
        terminalItem.canCollapse = true
        terminalItem.holdingPriority = .init(251)

        let preview = NSHostingController(rootView: PreviewColumn(store: store))
        preview.sizingOptions = []
        previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = Self.minInspector
        previewItem.canCollapse = true
        previewItem.holdingPriority = .init(249)
        previewItem.isCollapsed = true

        addSplitViewItem(inspectorItem)
        addSplitViewItem(terminalItem)
        addSplitViewItem(previewItem)
    }

    /// Show the workspace's halves (and its divider position).
    func apply(_ w: Workspace?, animated: Bool) {
        loadViewIfNeeded()
        shown = w
        let preview = w?.previewShowing ?? false
        let inspector = !preview && (w?.inspectorVisible ?? false)
        // A column with neither half keeps its last look while it closes.
        let terminal = !preview && (w?.terminalVisible ?? false)
        guard inspector || terminal || preview else { return }
        applying = true
        defer { applying = false }
        // The preview and the halves change places at once.
        if preview != showsPreview || preview {
            showsPreview = preview
            previewItem.isCollapsed = !preview
            if preview {
                inspectorItem.isCollapsed = true
                terminalItem.isCollapsed = true
                return
            }
        }
        let change = {
            self.inspectorItem.isCollapsed = !inspector
            self.terminalItem.isCollapsed = !terminal
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                self.inspectorItem.animator().isCollapsed = !inspector
                self.terminalItem.animator().isCollapsed = !terminal
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.applyFraction() }
            }
        } else {
            change()
            applyFraction()
        }
    }

    private func applyFraction() {
        guard let w = shown, w.inspectorVisible, w.terminalVisible, !w.previewShowing else { return }
        let total = splitView.bounds.height
        guard total > 0 else { return }
        applying = true
        defer { applying = false }
        let y = min(max(Self.minInspector, total * store.inspectorFraction), total - Self.minTerminal)
        splitView.setPosition(y, ofDividerAt: 0)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?()
        if splitView.bounds.height > 0, !didApplyFirstLayout {
            didApplyFirstLayout = true
            applyFraction()
        }
    }
    private var didApplyFirstLayout = false

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        // The user dragged the divider: remember where.
        guard !applying, let w = shown, w.inspectorVisible, w.terminalVisible, !w.previewShowing,
              !inspectorItem.isCollapsed, !terminalItem.isCollapsed,
              NSApp.currentEvent?.type == .leftMouseDragged else { return }
        let total = splitView.bounds.height
        guard total > 0 else { return }
        let f = inspectorItem.viewController.view.frame.height / total
        if abs(f - store.inspectorFraction) > 0.002 {
            store.inspectorFraction = f
            store.setNeedsSave()
        }
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let r = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return r.insetBy(dx: 0, dy: -4)
    }
}

/// The terminal half: the workspace's terminal tabs, then the selected
/// terminal, on the terminal's own background.
final class TerminalColumnController: NSViewController {
    private(set) var current: TerminalSession?
    let store: WorkspaceStore
    private var strip: NSView!

    static let stripHeight: CGFloat = 34

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = TerminalColumnView()
        let host = NSHostingView(rootView: TerminalStrip(store: store))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.heightAnchor.constraint(equalToConstant: Self.stripHeight),
        ])
        strip = host
    }

    func show(_ session: TerminalSession?) {
        loadViewIfNeeded()
        guard session?.id != current?.id || (session != nil && session!.view.superview !== view) else { return }
        current?.view.removeFromSuperview()
        current = session
        guard let session else { return }
        let v = session.view
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.topAnchor.constraint(equalTo: strip.bottomAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    var isFocused: Bool {
        guard let t = current?.terminalView else { return false }
        return t.window?.firstResponder === t
    }

    func focus() {
        guard let t = current?.terminalView else { return }
        t.window?.makeFirstResponder(t)
    }
}

private final class TerminalColumnView: NSView {
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let theme = TerminalTheme.current(for: effectiveAppearance)
        layer?.backgroundColor = theme.background.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
