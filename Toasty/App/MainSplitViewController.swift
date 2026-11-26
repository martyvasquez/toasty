import AppKit
import Combine
import SwiftUI

/// Workspaces sidebar · conversation · widgets, as a real split view: the
/// sidebar collapses (⇧⌘S); the widget column is a fixed 380pt (the 356pt
/// grid and its margins), with no divider, hidden per workspace (⌃⌘I).
final class MainSplitViewController: NSSplitViewController {
    let store: WorkspaceStore
    let layout: WindowLayout
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var contentItem: NSSplitViewItem!
    private(set) var terminalItem: NSSplitViewItem!
    private(set) var rightColumn: NSViewController!

    /// Column frames changed (the titlebar row follows them).
    var onLayout: (() -> Void)?

    /// The workspaces sidebar's default width. The user can drag its edge
    /// (the width is kept, `WorkspaceStore.sidebarWidth`) and double-click
    /// it to come back to this; nothing else resizes it (not the columns
    /// beside it, not the window).
    static var sidebarWidth: CGFloat { WorkspaceStore.defaultSidebarWidth }
    static let minConversation: CGFloat = 440
    static let minTerminal: CGFloat = WidgetGrid.columnWidth

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
        // A narrow window sets it aside by `applyWidth`, not AppKit's own
        // rule (the two would fight over the widgets).
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.isCollapsed = !store.sidebarVisible || store.workspaces.isEmpty
        // Its width is the user's: the window and the other columns don't
        // take from it (only a drag on its edge changes it).
        sidebarItem.holdingPriority = .init(260)

        let content = ConversationColumnController(store: store, layout: layout)
        contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = Self.minConversation
        contentItem.holdingPriority = .init(249)

        let widgets = WidgetColumnController(store: store, layout: layout)
        rightColumn = widgets
        terminalItem = NSSplitViewItem(viewController: widgets)
        terminalItem.minimumThickness = WidgetGrid.columnWidth
        terminalItem.maximumThickness = WidgetGrid.columnWidth
        terminalItem.canCollapse = true
        terminalItem.canCollapseFromWindowResize = false
        terminalItem.holdingPriority = .init(255)
        terminalItem.isCollapsed = true

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(terminalItem)
        // Double-clicking a column's edge puts it back to its default width.
        (splitView as? HairlineSplitView)?.onDoubleClickDivider = { [weak self] i in self?.resetColumn(atDivider: i) }
        // The widgets float on the page: no line between them and the
        // conversation, and nothing to drag.
        (splitView as? HairlineSplitView)?.hiddenDividers = [1]

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
    /// `exact`: show or hide it as asked (the width rule already decided).
    private func applySidebar(wanted: Bool? = nil, animated: Bool = true, exact: Bool = false) {
        guard isViewLoaded else { return }
        let wants = wanted ?? (store.sidebarVisible && !store.workspaces.isEmpty && !browserFills)
        let visible = exact ? wants
            : wants && fits(sidebar: true, widgets: store.active?.widgetsVisible ?? false, width: splitView.bounds.width)
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
                self?.catchUpWidth()
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

    /// Show the active workspace's widget column (or not), and follow it.
    private func showActiveWorkspace() {
        guard isViewLoaded, view.window != nil else { return }
        let w = store.active
        guard w?.id != shownWorkspace || workspaceCancellables.isEmpty else { return }
        shownWorkspace = w?.id
        workspaceCancellables = []
        guard let w else {
            setTerminal(visible: false, animated: false)
            return
        }
        applyWidth(splitView.bounds.width, animated: false)
        // The browser tab filling the window (the experiment) comes and
        // goes with the tab and the setting.
        let settings = PreviewSettings.shared
        w.$widgetsVisible.map { _ in () }
            .merge(with: w.$shownBrowserTabID.map { $0 != nil }.removeDuplicates().map { _ in () },
                   settings.$fillsWindow.removeDuplicates().map { _ in () })
            .dropFirst(3)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyWidth(self.splitView.bounds.width, animated: true)
            }
            .store(in: &workspaceCancellables)
    }

    /// The browser's tab is showing and fills the window (the experiment):
    /// the workspaces and widgets step aside, as if hidden.
    var browserFills: Bool {
        let settings = PreviewSettings.shared
        return settings.enabled && settings.fillsWindow && store.active?.browserShown == true
    }

    // MARK: Narrow windows

    /// The conversation's width below which a side column steps aside:
    /// a little over its minimum, so the step happens before the window
    /// meets its minimum size.
    static let comfortableConversation: CGFloat = minConversation + 40

    /// Whether these columns fit in a window this wide beside a
    /// comfortable conversation.
    private func fits(sidebar: Bool, widgets: Bool, width: CGFloat) -> Bool {
        var need = Self.comfortableConversation
        if sidebar { need += store.sidebarWidth + splitView.dividerThickness }
        if widgets { need += WidgetGrid.columnWidth + splitView.dividerThickness }
        return width >= need
    }

    /// One rule for both side columns at a window width. The widgets come
    /// first: they show (if the workspace wants them) when they fit beside
    /// the conversation; the workspaces sidebar shows (if wanted) when it
    /// fits beside them too. So narrowing sets the sidebar aside, then the
    /// widgets, leaving the conversation alone (the sidebar doesn't come
    /// back into the room the widgets left); widening brings the widgets
    /// back, then the sidebar. What the user asked for (`sidebarVisible`,
    /// `widgetsVisible`) never changes.
    /// `arrivals: false` (before a resize): only set columns aside; they
    /// come back once the window has the width (after it).
    func applyWidth(_ width: CGFloat, animated: Bool, arrivals: Bool = true) {
        guard isViewLoaded, view.window != nil else { return }
        let fill = browserFills
        let wantsWidgets = (store.active?.widgetsVisible ?? false) && !fill
        let wantsSidebar = store.sidebarVisible && !store.workspaces.isEmpty && !fill
        let widgets = wantsWidgets && fits(sidebar: false, widgets: true, width: width)
        let sidebar = wantsSidebar && fits(sidebar: true, widgets: wantsWidgets, width: width)
        // Each column waits out its own slide (and catches up after it).
        // Columns leave before any arrive, so the window's minimum (the
        // shown columns' widths) never blocks the change.
        let moveSidebar = !sidebarAnimating && sidebarItem.isCollapsed == sidebar
        let moveWidgets = !terminalAnimating && terminalItem.isCollapsed == widgets
        // A width under what the shown columns need can't wait for a
        // slide (the window would stop at their minimum): they go at once.
        var minimum = Self.minConversation
        if !sidebarItem.isCollapsed { minimum += sidebarItem.minimumThickness + splitView.dividerThickness }
        if !terminalItem.isCollapsed { minimum += WidgetGrid.columnWidth + splitView.dividerThickness }
        let leaveAnimated = animated && width >= minimum
        if moveSidebar, !sidebar { setSidebar(false, animated: leaveAnimated) }
        if moveWidgets, !widgets { setTerminal(visible: false, animated: leaveAnimated) }
        guard arrivals else { return }
        if moveWidgets, widgets { setTerminal(visible: true, animated: animated, width: WidgetGrid.columnWidth) }
        if moveSidebar, sidebar { setSidebar(true, animated: animated) }
    }

    /// After a slide: the window may have kept moving while it played.
    private func catchUpWidth() {
        applyWidth(splitView.bounds.width, animated: true)
    }

    private func setSidebar(_ visible: Bool, animated: Bool) {
        if animated {
            applySidebar(wanted: visible, exact: true)
        } else {
            let was = applying
            applying = true
            defer { applying = was }
            sidebarItem.isCollapsed = !visible
            applySidebarWidth()
        }
    }

    /// The window is about to be this wide (the user dragging its edge):
    /// set columns aside before the window gets there.
    func windowWillResize(toWidth width: CGFloat) {
        // Sliding, as when shown or hidden by hand.
        applyWidth(width, animated: true, arrivals: false)
    }

    /// Asked to show the widgets in a window too narrow for them: widen
    /// the window (within its screen). The sidebar steps aside on its own
    /// if only it was in the way.
    @discardableResult
    func makeRoomForWidgets() -> Bool {
        let width = splitView.bounds.width
        guard !fits(sidebar: false, widgets: true, width: width) else { return true }
        return widen(to: Self.comfortableConversation + WidgetGrid.columnWidth + splitView.dividerThickness)
    }

    /// Asked to show the sidebar where it doesn't fit: widen the window.
    @discardableResult
    func makeRoomForSidebar() -> Bool {
        let width = splitView.bounds.width
        let widgets = store.active?.widgetsVisible ?? false
        guard !fits(sidebar: true, widgets: widgets, width: width) else { return true }
        var need = Self.comfortableConversation + store.sidebarWidth + splitView.dividerThickness
        if widgets { need += WidgetGrid.columnWidth + splitView.dividerThickness }
        return widen(to: need)
    }

    private func widen(to need: CGFloat) -> Bool {
        guard let window = view.window, let screen = window.screen?.visibleFrame else { return false }
        let deficit = need - splitView.bounds.width + 1
        guard deficit > 0 else { return true }
        var frame = window.frame
        frame.size.width += deficit
        guard frame.width <= screen.width else { return false }
        // Grow to the left (the widgets are on the right), kept on screen.
        frame.origin.x = max(screen.minX, min(frame.origin.x - deficit, screen.maxX - frame.width))
        window.setFrame(frame, display: true, animate: true)
        return true
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
                        self?.catchUpWidth()
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
        guard !applying, store.active != nil else { return }
        // The user dragged the sidebar's edge: remember its width.
        if !sidebarAnimating, !sidebarItem.isCollapsed, draggingDivider(0) {
            let width = sidebarItem.viewController.view.frame.width
            if abs(width - store.sidebarWidth) > 0.5, WorkspaceStore.sidebarWidthRange.contains(width) {
                store.sidebarWidth = width
                store.setNeedsSave()
            }
        }
        // The user collapsed the sidebar by dragging its edge closed (not a
        // narrow window setting it aside).
        let sidebarShown = !sidebarItem.isCollapsed
        if !sidebarAnimating, !store.workspaces.isEmpty, sidebarShown != store.sidebarVisible, draggingDivider(0) {
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
    /// Dividers drawn as nothing and never dragged.
    var hiddenDividers: Set<Int> = []

    func dividerIndex(at rect: NSRect) -> Int? {
        let edges = arrangedSubviews.dropLast().enumerated().map { ($0.offset, abs($0.element.frame.maxX - rect.minX)) }
        return edges.min { $0.1 < $1.1 }?.0
    }

    override func drawDivider(in rect: NSRect) {
        if let i = dividerIndex(at: rect), hiddenDividers.contains(i) {
            // The page's color shows through (the conversation's background).
            ClaudeStyle.background.setFill()
            rect.fill()
            return
        }
        super.drawDivider(in: rect)
    }

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
        if (splitView as? HairlineSplitView)?.hiddenDividers.contains(dividerIndex) == true { return .zero }
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

/// The widget column's controller: the SwiftUI grid, and the two-finger
/// swipe (or a click and drag sideways) that switches spaces.
final class WidgetColumnController: NSHostingController<WidgetColumnView> {
    let store: WorkspaceStore
    private let layout: WindowLayout
    private var monitor: Any?
    private var mouseMonitor: Any?
    /// A click that may become a sideways drag: where it went down, and
    /// whether it has taken over (its later events are the drag's).
    private var grab: (start: NSPoint, index: Int)?
    private var grabbing = false
    /// The drag's last few moves, for how fast it let go.
    private var grabMoves: [(time: TimeInterval, x: CGFloat)] = []
    private var settle: Timer?
    /// A swipe the system is tracking (its later events are its).
    private var tracking = false
    /// Without the system's swipe tracking (turned off in Trackpad
    /// settings): how far this swipe has gone, and whether it switched.
    private var swipe: CGFloat = 0
    private var swiped = false

    init(store: WorkspaceStore, layout: WindowLayout) {
        self.store = store
        self.layout = layout
        super.init(rootView: WidgetColumnView(store: store, layout: layout))
        sizingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.scrolled(e) ?? e
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.dragged(e) ?? e
        }
    }

    /// One column's width: the distance a space slides.
    private var page: CGFloat { WidgetGrid.width + WidgetGrid.margin * 2 }

    /// A click and drag sideways over the widgets (not while editing them,
    /// when a drag moves a widget): the column follows the pointer as it
    /// does the fingers, and lets go onto the space it's nearer, or the
    /// next one if flicked. A drag that starts in a terminal is its own
    /// (it selects text); one that goes mostly up or down is left alone.
    private func dragged(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .leftMouseDown:
            grab = nil
            grabbing = false
            guard WidgetDragSetting.shared.enabled, e.window === view.window,
                  !store.editingWidgets, !store.galleryOpen,
                  let w = store.active, store.spaces.count > 1, settle == nil else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            let bar = layout.buttonsMidY > 0 ? layout.buttonsMidY * 2 : 52
            // The view's flipped or not; the tab row is at the top either way.
            let fromTop = view.isFlipped ? p.y : view.bounds.height - p.y
            guard view.bounds.contains(p), fromTop > bar, !inTerminal(e),
                  !Self.onResizeEdge(e.locationInWindow, of: view.window) else { return e }
            grab = (e.locationInWindow, store.spaceIndex(for: w))
            return e
        case .leftMouseDragged:
            guard let grab else { return e }
            // The window is being resized (its edge was grabbed): that's
            // not a swipe, so let the column go back where it was.
            if view.window?.inLiveResize == true {
                self.grab = nil
                grabbing = false
                grabMoves = []
                SpaceSwipe.shared.amount = 0
                return e
            }
            let dx = e.locationInWindow.x - grab.start.x
            let dy = e.locationInWindow.y - grab.start.y
            if !grabbing {
                if abs(dy) > 6 && abs(dy) > abs(dx) { self.grab = nil; return e }
                guard abs(dx) > 6 else { return e }
                grabbing = true
            }
            let now = e.timestamp
            grabMoves.append((now, dx))
            grabMoves.removeAll { now - $0.time > 0.08 }
            SpaceSwipe.shared.amount = followed(dx, from: grab.index)
            return nil
        case .leftMouseUp:
            guard let grab else { return e }
            self.grab = nil
            guard grabbing else { return e }
            grabbing = false
            land(from: grab.index)
            grabMoves = []
            // The click's own release lands nowhere, so whatever it went
            // down on (a button, a row) doesn't take it as a click.
            return NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000),
                                      modifierFlags: e.modifierFlags, timestamp: e.timestamp,
                                      windowNumber: e.windowNumber, context: nil,
                                      eventNumber: e.eventNumber, clickCount: e.clickCount,
                                      pressure: 0) ?? e
        default:
            return e
        }
    }

    /// The band along the window's right and bottom edges where a click
    /// resizes the window (the column runs to both).
    static let resizeEdge: CGFloat = 8

    private static func onResizeEdge(_ p: NSPoint, of window: NSWindow?) -> Bool {
        guard let window, window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else { return false }
        let size = window.frame.size
        return p.x > size.width - resizeEdge || p.y < resizeEdge
    }

    private func inTerminal(_ e: NSEvent) -> Bool {
        guard let content = view.window?.contentView,
              var v = content.hitTest(content.convert(e.locationInWindow, from: nil)) else { return false }
        while true {
            if v is TerminalHostView || v is NSText || v is NSTextField { return true }
            guard let up = v.superview else { return false }
            v = up
        }
    }

    /// How far the column has followed a drag of `dx`: one for one, except
    /// toward a space that isn't there, where it gives a little.
    private func followed(_ dx: CGFloat, from i: Int) -> CGFloat {
        let amount = dx / page
        let open = amount > 0 ? i > 0 : i < store.spaces.count - 1
        if open { return max(-1, min(1, amount)) }
        let give = abs(amount)
        return (amount > 0 ? 1 : -1) * 0.12 * give / (give + 0.3)
    }

    /// Let go: onto the space it's past halfway to, or the one it was
    /// flicked toward; else back.
    private func land(from i: Int) {
        let amount = SpaceSwipe.shared.amount
        var speed: CGFloat = 0
        if let first = grabMoves.first, let last = grabMoves.last, last.time > first.time {
            speed = (last.x - first.x) / CGFloat(last.time - first.time) / page
        }
        let toward: CGFloat = amount > 0 ? 1 : -1
        let open = amount > 0 ? i > 0 : i < store.spaces.count - 1
        let flicked = speed * toward > 1.2
        let target: CGFloat = open && amount != 0 && (abs(amount) > 0.5 || flicked) ? toward : 0
        animate(to: target) { [weak self] in
            guard let self, target != 0, let w = self.store.active else { return }
            let to = i + (target > 0 ? -1 : 1)
            if self.store.spaces.indices.contains(to) {
                SpaceSwipe.shared.landed = true
                w.selectSpace(self.store.spaces[to].id)
            }
        }
    }

    /// Eases the column to `target` frame by frame (as the system's swipe
    /// does, so the space beside it stays drawn until it's off), then
    /// `done`, with the column back at rest.
    private func animate(to target: CGFloat, done: @escaping @MainActor () -> Void) {
        let from = SpaceSwipe.shared.amount
        let start = CACurrentMediaTime()
        let duration = 0.12 + 0.18 * Double(abs(target - from))
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = 1 - pow(1 - p, 3)
                SpaceSwipe.shared.amount = from + (target - from) * CGFloat(eased)
                guard p >= 1 else { return }
                self.settle?.invalidate()
                self.settle = nil
                var tr = Transaction()
                tr.disablesAnimations = true
                withTransaction(tr) {
                    done()
                    SpaceSwipe.shared.amount = 0
                }
            }
        }
    }

    /// Two fingers sideways over the column: the next or previous space.
    /// The column follows the fingers (the system's page swipe, as
    /// Safari's back and forward), and settles on whichever space the
    /// swipe leaves it nearer; at the first or last space it gives a
    /// little and springs back. Vertical scrolling passes through.
    private func scrolled(_ e: NSEvent) -> NSEvent? {
        guard e.window === view.window, e.hasPreciseScrollingDeltas,
              view.bounds.contains(view.convert(e.locationInWindow, from: nil)) else { return e }
        // Not while the button's held or the window's being resized: fingers
        // moving on the trackpad during a resize aren't a swipe.
        if view.window?.inLiveResize == true || NSEvent.pressedMouseButtons != 0 {
            if e.phase == .ended || e.phase == .cancelled { swipe = 0; swiped = false }
            return e
        }
        let sideways = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY)
        // The tracked swipe's own events, and its momentum.
        if tracking || e.momentumPhase != [] { return sideways ? nil : e }
        guard e.phase == .began || e.phase == .changed, sideways else {
            if e.phase == .ended || e.phase == .cancelled { swipe = 0; swiped = false }
            return e
        }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return countSwipe(e) }
        track(e)
        return nil
    }

    private func track(_ e: NSEvent) {
        guard let w = store.active, store.spaces.count > 1 else { return }
        let i = store.spaceIndex(for: w)
        let canPrevious = i > 0, canNext = i < store.spaces.count - 1
        tracking = true
        var ended = false
        e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                          dampenAmountThresholdMin: canNext ? -1 : 0,
                          max: canPrevious ? 1 : 0) { [weak self] amount, phase, complete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                SpaceSwipe.shared.amount = amount
                if phase == .ended { ended = true }
                if phase == .cancelled { ended = false }
                guard complete else { return }
                self.tracking = false
                // Swiped far enough: the space it slid to, in place (the
                // column is already there); else back where it was.
                let to = ended && amount != 0 ? i + (amount > 0 ? -1 : 1) : nil
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    if let to, self.store.spaces.indices.contains(to) {
                        SpaceSwipe.shared.landed = true
                        w.selectSpace(self.store.spaces[to].id)
                    }
                    SpaceSwipe.shared.amount = 0
                }
            }
        }
    }

    /// Two fingers sideways, counted (once per swipe).
    private func countSwipe(_ e: NSEvent) -> NSEvent? {
        if e.phase == .began { swipe = 0; swiped = false }
        swipe += e.scrollingDeltaX
        if !swiped, abs(swipe) > 40 {
            swiped = true
            store.switchSpace(by: swipe < 0 ? 1 : -1)
        }
        return nil
    }
}
