import AppKit
import Combine
import SwiftUI

/// The window's content: the split view (workspaces · conversation · right
/// column), filling it.
///
/// It's a view of its own for the preview's sake (`PreviewDrawer`): when a
/// desktop page hasn't room beside the conversation, the page is shown here
/// across the whole window, and the split view (by then only the workspaces
/// and the conversation) becomes a drawer over the page's left side that
/// slides off the window's left edge.
final class MainContainerController: NSViewController {
    let store: WorkspaceStore
    let split: MainSplitViewController
    private let drawer = PreviewDrawer.shared
    private var page: NSView!
    private let edge = PreviewDrawerEdge()
    /// Under the split view, in the window's own color: over the page, the
    /// workspaces' material shows this through and not the page's colors,
    /// so the sidebar looks as it does everywhere else.
    private let backing = WindowBackingView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var width: NSLayoutConstraint!
    private var cancellables: Set<AnyCancellable> = []
    private var lastWidth: CGFloat = 0

    init(store: WorkspaceStore, split: MainSplitViewController) {
        self.store = store
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()

        let host = NSHostingView(rootView: PreviewDrawerPage(store: store))
        host.sizingOptions = []
        page = host
        edge.isHidden = true

        addChild(split)
        for v in [host, backing, split.view, edge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        leading = split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        trailing = split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        width = split.view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            leading, trailing,
            backing.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
            backing.topAnchor.constraint(equalTo: view.topAnchor),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            // The page, below the titlebar row.
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: split.view.trailingAnchor),
            edge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            edge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: PreviewDrawerEdge.width),
        ])

        // Whatever decides between beside and over: the workspace and what
        // it shows (asked by the split view just before it lays out the
        // right column), the page's size, the window's width (`viewDidLayout`).
        split.resolveDrawer = { [weak self] in self?.updateMode() }
        drawer.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateMode()
                self?.split.applyColumn()
            }
            .store(in: &cancellables)
        drawer.$open
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyOpen(animated: true) }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard abs(view.bounds.width - lastWidth) > 0.25 else { return }
        lastWidth = view.bounds.width
        // Not from inside the layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.updateMode()
            self?.split.noteLayout()
        }
    }

    // MARK: Beside or over

    private var sidebarWidth: CGFloat {
        MainSplitViewController.sidebarWidth
    }

    /// The drawer: the workspaces and the conversation at its narrowest.
    private var drawerWidth: CGFloat {
        (sidebarWidth + MainSplitViewController.minConversation + 1).rounded()
    }

    private func updateMode() {
        guard isViewLoaded, view.window != nil, view.bounds.width > 0 else { return }
        let on = PreviewDrawer.wanted(for: store.active, width: view.bounds.width, sidebar: sidebarWidth)
        if on, drawer.active, abs(width.constant - drawerWidth) > 0.5 {
            // The workspaces were made wider or narrower.
            width.constant = drawerWidth
            if !drawer.open { leading.constant = -(drawerWidth + PreviewDrawerEdge.width) }
        }
        guard on != drawer.active else { return }
        if on {
            // The right column goes while the split view still has the
            // window, then the split view narrows to the drawer.
            drawer.setActive(true)
            split.setDrawerMode(true)
            trailing.isActive = false
            width.constant = drawerWidth
            width.isActive = true
            applyOpen(animated: false)
        } else {
            // The split view gets the window back before the page's column
            // opens in it, so the column opens at its real width.
            width.isActive = false
            trailing.isActive = true
            leading.constant = 0
            split.view.isHidden = false
            edge.isHidden = true
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            if split.view.frame.width < view.bounds.width - 0.5 { split.view.frame = view.bounds }
            drawer.setActive(false)
            split.setDrawerMode(false)
        }
        split.noteLayout()
    }

    // MARK: Out or away

    private func applyOpen(animated: Bool) {
        guard drawer.active else { return }
        let open = drawer.open
        let away = -(drawerWidth + PreviewDrawerEdge.width)
        let window = view.window
        if open {
            split.view.isHidden = false
            edge.isHidden = false
        } else if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: split.view) {
            // Typing goes to the page, not to a composer nobody can see.
            let web = store.active.flatMap { PreviewStore.shared.session(for: $0).webView }
            window.makeFirstResponder(web?.window === window ? web : nil)
        }
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = open ? 0.2 : 0.17
                ctx.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
                ctx.allowsImplicitAnimation = true
                leading.animator().constant = open ? 0 : away
                view.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.settled() }
            }
        } else {
            leading.constant = open ? 0 : away
            settled()
        }
        split.noteLayout()
        if open {
            // Out again: what it shows has been seen, and typing goes to it.
            Activity.shared.markShownAsSeen()
            store.active?.selected?.focusComposer()
        }
    }

    /// The drawer has stopped moving: away, it isn't drawn at all.
    private func settled() {
        guard drawer.active else { return }
        if !drawer.open {
            split.view.isHidden = true
            edge.isHidden = true
        }
        split.noteLayout()
    }
}

private final class WindowBackingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = (window?.backgroundColor ?? .textBackgroundColor).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
