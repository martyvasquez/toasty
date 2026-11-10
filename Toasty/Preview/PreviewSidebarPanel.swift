import AppKit
import Combine
import SwiftUI

/// The workspaces sidebar, floating over the conversation: how you get to
/// your workspaces while the preview has the sidebar's room.
///
/// - ⌃⌘S shows it until a workspace or conversation is picked, Esc, ⌃⌘S
///   again, or a click anywhere else.
/// - Resting the pointer on the window's left edge slides it out like the
///   Dock; opened that way it also leaves when the pointer does.
///
/// Never on a timer of its own.
@MainActor
final class PreviewSidebarPanel {
    static let shared = PreviewSidebarPanel()

    private var panel: PanelHost?
    private var leading: NSLayoutConstraint?
    private var monitors: [Any] = []
    private var selection: AnyCancellable?
    private var edge: EdgeSensor?

    var isShown: Bool { panel != nil }

    func toggle(in window: NSWindow, store: WorkspaceStore) {
        if isShown { dismiss() } else { show(in: window, store: store, hover: false) }
    }

    /// Watch the left edge of `window` for a resting pointer (while the
    /// sidebar is out of the preview's way), or stop watching (nil).
    func watchEdge(of window: NSWindow?, store: WorkspaceStore) {
        guard let content = window?.contentView else {
            edge?.removeFromSuperview()
            edge = nil
            dismiss()
            return
        }
        guard edge?.superview !== content else { return }
        edge?.removeFromSuperview()
        let sensor = EdgeSensor { [weak self, weak window] in
            guard let self, let window, !self.isShown else { return }
            self.show(in: window, store: store, hover: true)
        }
        sensor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sensor, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            sensor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sensor.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            sensor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sensor.widthAnchor.constraint(equalToConstant: EdgeSensor.width),
        ])
        edge = sensor
    }

    private func show(in window: NSWindow, store: WorkspaceStore, hover: Bool) {
        guard panel == nil, let content = window.contentView else { return }
        let host = PanelHost(rootView: FloatingSidebar(store: store))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host, positioned: .above, relativeTo: nil)
        let width = min(max(store.sidebarWidth, 190), 320) + 16
        let leading = host.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: -width)
        NSLayoutConstraint.activate([
            leading,
            host.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: width),
        ])
        content.layoutSubtreeIfNeeded()
        panel = host
        self.leading = leading
        // Opened by resting on the edge: gone when the pointer has left.
        if hover { host.onPointerLeft = { [weak self] in self?.dismiss() } }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            leading.animator().constant = 0
            content.layoutSubtreeIfNeeded()
        }

        // Picking a workspace or a conversation is what it was opened for.
        selection = store.selectionChanged.merge(with: store.$activeID.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.dismiss() }
        // Esc, or a click anywhere else (which still does what it would).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, event.window === window, self?.isShown == true else { return event }
            self?.dismiss()
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self, weak host] event in
            guard let self, let host, event.window === window else { return event }
            if !host.frame.contains(content.convert(event.locationInWindow, from: nil)) { self.dismiss() }
            return event
        }) { monitors.append(m) }
    }

    func dismiss() {
        guard let host = panel else { return }
        panel = nil
        selection = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        host.onPointerLeft = nil
        let leading = self.leading
        self.leading = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            leading?.animator().constant = -host.frame.width
            host.superview?.layoutSubtreeIfNeeded()
        } completionHandler: {
            MainActor.assumeIsolated { host.removeFromSuperview() }
        }
    }
}

/// The floating sidebar's host: says when the pointer has left it (and
/// stayed away for a moment, so brushing past the edge doesn't close it).
private final class PanelHost: NSHostingView<FloatingSidebar> {
    var onPointerLeft: (() -> Void)?
    private var area: NSTrackingArea?
    private var leaving: DispatchWorkItem?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        leaving?.cancel()
        leaving = nil
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard onPointerLeft != nil else { return }
        leaving?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                // Still away (a menu opened from a row keeps it open).
                let inside = self.frame.contains(self.superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero)
                if !inside, NSApp.mainMenu?.highlightedItem == nil, NSEvent.pressedMouseButtons == 0 { self.onPointerLeft?() }
            }
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// A sliver along the window's left edge that notices the pointer resting
/// there. It takes no clicks (the conversation under it gets them).
private final class EdgeSensor: NSView {
    static let width: CGFloat = 5
    /// How long the pointer rests before the sidebar comes out: enough that
    /// passing by, or reaching for the window's edge to resize, doesn't.
    static let dwell: TimeInterval = 0.15

    private let action: () -> Void
    private var area: NSTrackingArea?
    private var pending: DispatchWorkItem?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        pending?.cancel()
        // Not while dragging something (a selection, the window's edge).
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, NSEvent.pressedMouseButtons == 0,
                      self.frame.contains(self.superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil) ?? .zero)
                else { return }
                self.action()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        pending?.cancel()
        pending = nil
    }
}

/// The sidebar's own view on the sidebar's material, as a panel with a
/// shadow so it reads as over the conversation, not part of the layout.
private struct FloatingSidebar: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        WorkspaceSidebarView(store: store)
            .background(SidebarMaterial())
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
            .padding(8)
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
