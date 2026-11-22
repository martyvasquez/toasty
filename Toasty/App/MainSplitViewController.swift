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

    /// The workspaces sidebar's default width. The user can drag its edge
    /// (the width is kept, `WorkspaceStore.sidebarWidth`) and double-click
    /// it to come back to this; nothing else resizes it (not the columns
    /// beside it, not the window).
    static var sidebarWidth: CGFloat { WorkspaceStore.defaultSidebarWidth }
    static let minConversation: CGFloat = 440
    static let minTerminal: CGFloat = 280

    private var cancellables: Set<AnyCancellable> = []
    private var workspaceCancellables: Set<AnyCancellable> = []
    /// Applying a workspace's layout (not the user dragging the divider).
    private var applying = false
    private var shownWorkspace: UUID?
    private var sidebarAnimating = false
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
        sidebarItem.minimumThickness = WorkspaceStore.sidebarWidthRange.lowerBound
        sidebarItem.maximumThickness = WorkspaceStore.sidebarWidthRange.upperBound
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !store.sidebarVisible || store.workspaces.isEmpty
        // Its width is the user's: the window and the other columns don't
        // take from it (only a drag on its edge changes it).
        sidebarItem.holdingPriority = .init(260)

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
        // Double-clicking a column's edge puts it back to its default width.
        (splitView as? HairlineSplitView)?.onDoubleClickDivider = { [weak self] i in self?.resetColumn(atDivider: i) }
        // `splitViewDidResizeSubviews` can arrive before the right column's
        // frame is set: the titlebar row would sit over the old width.
        rightColumn.onLayout = { [weak self] in self?.layoutChanged() }

        store.$activeID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showActiveWorkspace() }
            .store(in: &cancellables)
        // Published values arrive before they're set: use the new ones.
        store.$sidebarVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                self.applySidebar(wanted: visible && !self.store.workspaces.isEmpty)
            }
            .store(in: &cancellables)
        // With no workspaces the sidebar has nothing to show: hidden until
        // the first one, which it slides in with.
        store.$workspaces
            .map(\.isEmpty)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] empty in
                guard let self else { return }
                self.applySidebar(wanted: self.store.sidebarVisible && !empty)
            }
            .store(in: &cancellables)
    }

    /// Show the sidebar if the user wants it (and there's a workspace).
    private func applySidebar(wanted: Bool? = nil, animated: Bool = true) {
        guard isViewLoaded else { return }
        let visible = wanted ?? (store.sidebarVisible && !store.workspaces.isEmpty)
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

    override func viewDidAppear() {
        super.viewDidAppear()
        applySidebarWidth()
        showActiveWorkspace()
    }

    /// The workspaces at their width, after anything that may have let the
    /// split view bring them back at another.
    func applySidebarWidth() {
        guard isViewLoaded, !sidebarItem.isCollapsed, !sidebarAnimating, view.window?.inLiveResize != true else { return }
        let w = store.sidebarWidth
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
            return
        }
        rightColumn.apply(w, animated: false)
        setTerminal(visible: columnVisible(for: w), animated: false, width: columnWidth(for: w))
        terminalColumn.show(w.terminalVisible ? w.selectedTerminal : nil)

        // Either half of the right column showing or hiding.
        w.$terminalVisible.combineLatest(w.$inspectorVisible)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak w] _ in
                guard let self, let w else { return }
                if w.terminalVisible { self.terminalColumn.show(w.selectedTerminal ?? w.terminals.first) }
                let columnChanges = self.terminalItem.isCollapsed == self.columnVisible(for: w)
                // Within a shown column, the halves animate; a column that
                // opens or closes takes its new halves with it.
                self.rightColumn.apply(w, animated: !columnChanges)
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

    private func columnVisible(for w: Workspace) -> Bool {
        w.rightColumnVisible
    }

    /// The inspector and terminal keep the width the user gave them.
    private func columnWidth(for w: Workspace) -> CGFloat {
        store.rightColumnWidth
    }

    /// The column at the workspace's width (put back to its default).
    func applyColumn() {
        guard isViewLoaded, view.window != nil, let w = store.active else { return }
        setTerminal(visible: columnVisible(for: w), animated: false, width: columnWidth(for: w))
    }

    private func setTerminal(visible: Bool, animated: Bool, width: CGFloat? = nil) {
        let was = applying
        applying = true
        defer { applying = was }
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
                // The titlebar's part over the column slides with it, frame
                // by frame: the split view sets the end frames at once and
                // animates what's drawn, so the bar follows what's drawn.
                let open = rightColumn.view.frame.width
                if visible, open > 0 { layout.terminalOpenWidth = open }
                followSlide(true)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.columnSlide
                    ctx.allowsImplicitAnimation = true
                    terminalItem.animator().isCollapsed = !visible
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.followSlide(false)
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
        if !terminalAnimating, !terminalItem.isCollapsed, w.rightColumnVisible {
            let width = rightColumn.view.frame.width
            if abs(width - store.rightColumnWidth) > 0.5, width >= Self.minTerminal {
                store.rightColumnWidth = width
                store.setNeedsSave()
            }
        }
        // The user dragged the sidebar's edge: remember its width.
        if !sidebarAnimating, !sidebarItem.isCollapsed, draggingDivider(0) {
            let width = sidebarItem.viewController.view.frame.width
            if abs(width - store.sidebarWidth) > 0.5, WorkspaceStore.sidebarWidthRange.contains(width) {
                store.sidebarWidth = width
                store.setNeedsSave()
            }
        }
        // The user collapsed the sidebar by dragging it closed.
        let sidebarShown = !sidebarItem.isCollapsed
        if !sidebarAnimating, !store.workspaces.isEmpty, sidebarShown != store.sidebarVisible {
            store.sidebarVisible = sidebarShown
            store.setNeedsSave()
        }
    }


    /// The right column sliding open or closed (the titlebar follows it).
    static let columnSlide: TimeInterval = 0.22

    /// While the right column slides: a tick each frame that sets the
    /// titlebar's width from where the column is drawn.
    private var slideLink: CADisplayLink?

    private func followSlide(_ on: Bool) {
        slideLink?.invalidate()
        slideLink = nil
        guard on else { return }
        let link = splitView.displayLink(target: self, selector: #selector(slideTick))
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    @objc private func slideTick() {
        let column = rightColumn.view.superview ?? rightColumn.view
        // Its left edge as drawn this frame (mid-animation), to the
        // window's right edge.
        let drawn = column.layer?.presentation()?.frame ?? column.frame
        let width = max(0, min(splitView.bounds.width, splitView.bounds.width - drawn.minX))
        if abs(layout.terminalWidth - width) > 0.25 { layout.terminalWidth = width }
        onLayout?()
    }

    private func layoutChanged() {
        let width = terminalItem.isCollapsed ? 0 : rightColumn.view.frame.width
        // While it slides, the titlebar's width is the animation's.
        if terminalAnimating {
            onLayout?()
            return
        }
        if width > 0 { layout.terminalOpenWidth = width }
        if abs(layout.terminalWidth - width) > 0.25 { layout.terminalWidth = width }
        onLayout?()
    }

    /// Left edge of the conversation column, in window coordinates.
    var contentMinX: CGFloat {
        guard let v = contentItem?.viewController.view, v.window != nil else { return 0 }
        return v.convert(v.bounds, to: nil).minX
    }

    /// The conversation's right edge in the window (nil before it's in one).
    var contentMaxX: CGFloat? {
        guard let v = contentItem?.viewController.view, v.window != nil else { return nil }
        return v.convert(v.bounds, to: nil).maxX
    }
}

/// A 0.5pt divider in the separator color with a wider grab area.
final class HairlineSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0.5 }
    override var dividerColor: NSColor { .separatorColor }

    /// A double-click on a divider (its index): the column goes back to its
    /// default width.
    var onDoubleClickDivider: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClickDivider {
            let x = convert(event.locationInWindow, from: nil).x
            // The divider nearest the click (clicks reach the split view
            // itself only on a divider's grab area).
            let edges = arrangedSubviews.dropLast().enumerated().filter { !isSubviewCollapsed($0.element) }
                .map { ($0.offset, abs($0.element.frame.maxX - x)) }
            if let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 < 12 {
                onDoubleClickDivider(nearest.0)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

extension MainSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let r = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return r.insetBy(dx: -4, dy: 0)
    }

    /// A double-click on a column's edge: it goes back to its default width
    /// (the convention for resizable sidebars).
    func resetColumn(atDivider index: Int) {
        guard store.active != nil else { return }
        if index == 0 {
            store.sidebarWidth = WorkspaceStore.defaultSidebarWidth
            store.setNeedsSave()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                applySidebarWidth()
            }
        } else if index == 1 {
            store.rightColumnWidth = WorkspaceStore.defaultRightColumnWidth
            store.setNeedsSave()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                applyColumn()
            }
        }
    }

    /// The mouse is down on the divider at `index` (the user dragging it,
    /// not the window being resized).
    func draggingDivider(_ index: Int) -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0, view.window?.inLiveResize != true,
              let window = view.window, splitView.arrangedSubviews.indices.contains(index) else { return false }
        let edge = splitView.arrangedSubviews[index].frame.maxX
        let x = splitView.convert(window.mouseLocationOutsideOfEventStream, from: nil).x
        return abs(x - edge) < 12
    }
}

/// The right column: the inspector over the terminals, each half
/// collapsible, their divider kept per workspace.
final class RightColumnController: NSSplitViewController {
    let store: WorkspaceStore
    let terminalColumn: TerminalColumnController
    private(set) var inspectorItem: NSSplitViewItem!
    private(set) var terminalItem: NSSplitViewItem!
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

        addSplitViewItem(inspectorItem)
        addSplitViewItem(terminalItem)
    }

    /// Show the workspace's halves (and its divider position).
    func apply(_ w: Workspace?, animated: Bool) {
        loadViewIfNeeded()
        shown = w
        let inspector = w?.inspectorVisible ?? false
        // A column with neither half keeps its last look while it closes.
        let terminal = w?.terminalVisible ?? false
        guard inspector || terminal else { return }
        applying = true
        defer { applying = false }
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
        guard let w = shown, w.inspectorVisible, w.terminalVisible else { return }
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
        guard !applying, let w = shown, w.inspectorVisible, w.terminalVisible,
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

/// The terminal half: a card floating in the right column, as Things'
/// popovers (rounded, a light inner edge and a dark outer one, a soft
/// shadow), holding the workspace's terminal tabs and the selected terminal.
final class TerminalColumnController: NSViewController {
    private(set) var current: TerminalSession?
    let store: WorkspaceStore
    private var strip: NSView!
    /// The card the strip and the terminal sit in (clipped to its corners).
    private var card: NSView!

    /// A secondary bar, as the sidebar's footer (40pt).
    static let stripHeight: CGFloat = 40
    /// The card's margin from the column's sides and bottom.
    static let cardMargin: CGFloat = 12

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = TerminalColumnView()
        let m = Self.cardMargin
        // Under the card: its shadow and dark outer edge (the card itself
        // clips, so it can't cast a shadow).
        let shadow = TerminalCardShadow()
        shadow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shadow)
        let card = TerminalCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: m),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -m),
            shadow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: -0.5),
            shadow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: 0.5),
            shadow.topAnchor.constraint(equalTo: card.topAnchor, constant: -0.5),
            shadow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: 0.5),
        ])
        self.card = card
        let host = NSHostingView(rootView: TerminalStrip(store: store))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            host.topAnchor.constraint(equalTo: card.topAnchor),
            host.heightAnchor.constraint(equalToConstant: Self.stripHeight),
        ])
        strip = host
    }

    func show(_ session: TerminalSession?) {
        loadViewIfNeeded()
        guard session?.id != current?.id || (session != nil && session!.view.superview !== card) else { return }
        current?.view.removeFromSuperview()
        current = session
        guard let session else { return }
        let v = session.view
        v.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(v, positioned: .below, relativeTo: strip)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            v.topAnchor.constraint(equalTo: strip.bottomAnchor),
            v.bottomAnchor.constraint(equalTo: card.bottomAnchor),
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

/// The column around the card: the inspector's panel color.
private final class TerminalColumnView: NSView {
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ClaudeStyle.chrome.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The terminal's card: its own background, rounded, clipped, with a light
/// inner edge (Things: white 10%; none in light mode).
private final class TerminalCard: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.backgroundColor = TerminalTheme.current(for: effectiveAppearance).background.cgColor
        layer.cornerRadius = Theme.Radius.large
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = dark ? 1 : 0
        layer.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Behind the card: its dark outer edge and shadow (Things' popover edge,
/// black 90% at 0.5pt; a shadow 10pt down, 24pt blur, 60% dark / 30% light).
private final class TerminalCardShadow: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.cornerRadius = Theme.Radius.large + 0.5
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = NSColor(white: 0, alpha: dark ? 0.9 : 0.2).cgColor
        layer.backgroundColor = NSColor.black.cgColor
        layer.shadowColor = NSColor.black.cgColor
        // A step deeper than Things' popover, so the card clearly floats.
        layer.shadowOpacity = dark ? 0.6 : 0.3
        layer.shadowRadius = dark ? 12 : 8  // Core Animation's radius is half the blur
        layer.shadowOffset = CGSize(width: 0, height: -(dark ? 10 : 6))
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.large + 0.5,
                                   cornerHeight: Theme.Radius.large + 0.5, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
