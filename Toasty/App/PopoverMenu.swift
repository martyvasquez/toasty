import AppKit
import SwiftUI

/// Toasty's own pop-up menu (in place of a native one), as Things' menus:
/// a small rounded panel above its button, kept inside the window, rows of
/// body text with an optional line under them, a check by the current
/// choice. ↑↓ and Return work while it's open (the keyboard stays where it
/// was); Esc, a click elsewhere or the window going inactive close it.
@MainActor final class PopoverMenu {
    static let shared = PopoverMenu()

    struct Item {
        var title: String
        var subtitle: String = ""
        var symbol: String?
        var checked = false
        var enabled = true
        var action: () -> Void
    }

    private var panel: NSPanel?
    private var model: PopoverMenuModel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens `items` over `anchor` (above it, or below when there's no room
    /// above in its window). `onClose` runs when it goes, however it goes.
    func show(_ items: [Item], from anchor: NSView, onClose: @escaping () -> Void = {}) {
        close()
        guard let window = anchor.window else { return }
        TooltipController.shared.dismiss()
        self.onClose = onClose
        let model = PopoverMenuModel(items: items) { [weak self] i in self?.choose(i) }
        self.model = model

        // Measured whole, then, if it's taller than the room above (or
        // below) the button inside the window, scrolling at that height.
        let room = PopoverMenuView.shadowRoom
        let a = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let gap: CGFloat = 6, margin: CGFloat = 8
        let above = window.frame.maxY - margin - (a.maxY + gap)
        let below = (a.minY - gap) - (window.frame.minY + margin)
        // Its width first (its widest row, within limits); then, at exactly
        // that width, its height (lines that wrap count).
        let host = FirstMouseHostingView(rootView: PopoverMenuView(model: model, minWidth: anchor.bounds.width, scrollHeight: nil))
        let width = host.fittingSize.width - room * 2
        host.rootView = PopoverMenuView(model: model, minWidth: anchor.bounds.width, scrollHeight: nil, width: width)
        var size = host.fittingSize
        let content = size.height - room * 2
        let goesAbove = content <= above || above >= below
        let fits = goesAbove ? above : below
        if content > fits {
            host.rootView = PopoverMenuView(model: model, minWidth: anchor.bounds.width, scrollHeight: max(120, fits),
                                            width: width)
            size = host.fittingSize
        }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.appearance = window.effectiveAppearance
        panel.contentView = host

        // Above the button, centered on it (below when there's more room
        // there), kept inside the window with a margin.
        var origin = NSPoint(x: a.midX - size.width / 2,
                             y: goesAbove ? a.maxY + gap - room : a.minY - gap - size.height + room)
        origin.x = min(max(origin.x, window.frame.minX + margin - room), window.frame.maxX - margin - size.width + room)
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        watch(window)
    }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        model = nil
        let done = onClose
        onClose = nil
        done?()
    }

    private func choose(_ i: Int) {
        guard let model, model.items.indices.contains(i), model.items[i].enabled else { return }
        let action = model.items[i].action
        close()
        action()
    }

    /// Keys while it's open, clicks elsewhere, and the window going away.
    private func watch(_ window: NSWindow) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            switch event.keyCode {
            case 53: self.close(); return nil                          // esc
            case 125: model.step(1); return nil                        // ↓
            case 126: model.step(-1); return nil                       // ↑
            case 36, 76:                                               // return, enter
                if let i = model.highlighted { self.choose(i) }
                return nil
            default: return event
            }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            // A click elsewhere only closes it (as a menu does).
            self.close()
            return nil
        } as Any)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }
}

/// The open menu's rows and which one is highlighted (pointer or keys).
@MainActor final class PopoverMenuModel: ObservableObject {
    let items: [PopoverMenu.Item]
    let choose: (Int) -> Void
    @Published var highlighted: Int?

    init(items: [PopoverMenu.Item], choose: @escaping (Int) -> Void) {
        self.items = items
        self.choose = choose
    }

    func step(_ by: Int) {
        let enabled = items.indices.filter { items[$0].enabled }
        guard !enabled.isEmpty else { return }
        guard let h = highlighted, let at = enabled.firstIndex(of: h) else {
            highlighted = by > 0 ? enabled.first : enabled.last
            return
        }
        highlighted = enabled[max(0, min(enabled.count - 1, at + by))]
    }
}

/// Clicks on the menu work at once, though its panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PopoverMenuView: View {
    @ObservedObject var model: PopoverMenuModel
    let minWidth: CGFloat
    /// When it's too tall for the window: its rows scroll at this height
    /// (and this width, the one it measured whole).
    var scrollHeight: CGFloat?
    var width: CGFloat?

    /// Transparent room around the panel for its shadow.
    static let shadowRoom: CGFloat = 18
    static let maxWidth: CGFloat = 320

    private var hasLeading: Bool { model.items.contains { $0.checked || $0.symbol != nil } }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.offset) { i, item in
                row(item, highlighted: model.highlighted == i)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside, item.enabled { model.highlighted = i } else if model.highlighted == i { model.highlighted = nil }
                    }
                    .onTapGesture { model.choose(i) }
                    .id(i)
            }
        }
        .padding(Theme.Menu.inset)
    }

    @ViewBuilder private var content: some View {
        if let scrollHeight, let width {
            ScrollViewReader { proxy in
                ScrollView {
                    rows.frame(width: width, alignment: .leading)
                }
                .frame(width: width, height: scrollHeight)
                // Opens at the current choice; the keys scroll it along.
                .onAppear {
                    if let i = model.items.firstIndex(where: \.checked) { proxy.scrollTo(i, anchor: .center) }
                }
                .onChange(of: model.highlighted) { _, i in
                    if let i { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i) } }
                }
            }
        } else if let width {
            rows
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            rows
                .frame(minWidth: max(minWidth, 160), maxWidth: Self.maxWidth, alignment: .leading)
                .fixedSize()
        }
    }

    var body: some View {
        content
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.Tooltip.background))
        // A light inner edge and a dark outer hairline, as Things' popovers.
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .strokeBorder(Theme.Tooltip.innerBorder, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .stroke(Theme.Tooltip.outerBorder, lineWidth: 0.5))
        .popoverShadow()
        .padding(Self.shadowRoom)
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: PopoverMenu.Item, highlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if hasLeading {
                // The current choice's check, or the item's icon in Things'
                // menu blue.
                Group {
                    if item.checked {
                        Image(systemName: "checkmark").font(.toasty(Theme.Size.meta, .semibold))
                            .foregroundStyle(highlighted ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.headingBlue))
                    } else if let symbol = item.symbol {
                        Image(systemName: symbol).font(.toasty(Theme.Size.control))
                            .foregroundStyle(Theme.headingBlue)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.toasty(Theme.Size.body, .medium))
                    .foregroundStyle(item.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .lineLimit(item.subtitle.isEmpty ? 1 : 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Menu.rowPadding - Theme.Space.xs)
        .padding(.vertical, item.subtitle.isEmpty ? 0 : Theme.Space.s - Theme.Space.xxs)
        .frame(minHeight: Theme.Menu.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(highlighted ? Theme.Fill.accent : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }
}
