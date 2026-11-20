import AppKit
import SwiftUI

/// A tooltip that explains a control, as Things does: a bold title, its
/// shortcut on the right, and one line about it. Shown in its own small
/// panel (system tooltips can't have structure), after a short hover; the
/// next one shows at once while you move along a bar.
struct Tooltip: Equatable {
    var title: String
    var shortcut: String? = nil
    var detail: String? = nil
}

extension View {
    /// Shows `tooltip` while the pointer rests on this view. It replaces
    /// `.help`; VoiceOver reads the title and detail as the help text.
    func tooltip(_ tooltip: Tooltip) -> some View {
        modifier(TooltipModifier(tooltip: tooltip))
    }

    func tooltip(_ title: String, shortcut: String? = nil, detail: String? = nil) -> some View {
        self.tooltip(Tooltip(title: title, shortcut: shortcut, detail: detail))
    }
}

private struct TooltipModifier: ViewModifier {
    let tooltip: Tooltip
    @State private var anchor = TooltipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchorView(anchor: anchor))
            .onHover { inside in
                if inside { TooltipController.shared.hover(tooltip, over: anchor) }
                else { TooltipController.shared.leave(anchor) }
            }
            // A click is an answer: the tooltip gets out of the way.
            .simultaneousGesture(TapGesture().onEnded { TooltipController.shared.leave(anchor) })
            .accessibilityHint([tooltip.title, tooltip.detail].compactMap { $0 }.joined(separator: ". "))
            .onDisappear { TooltipController.shared.leave(anchor) }
    }
}

/// The view a tooltip points at (found through an AppKit view placed
/// behind it, for its frame on screen).
@MainActor final class TooltipAnchor {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

@MainActor final class TooltipController {
    static let shared = TooltipController()

    /// Resting this long on a control shows its tooltip...
    private let delay: TimeInterval = 0.6
    /// ...unless one was showing a moment ago: then the next shows at once.
    private let warmFor: TimeInterval = 0.6

    private var panel: NSPanel?
    private var host: NSHostingView<TooltipView>?
    private var pending: DispatchWorkItem?
    private weak var current: TooltipAnchor?
    private var hiddenAt: Date = .distantPast

    func hover(_ tooltip: Tooltip, over anchor: TooltipAnchor) {
        pending?.cancel()
        current = anchor
        let warm = panel?.isVisible == true || Date().timeIntervalSince(hiddenAt) < warmFor
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, self.current === anchor else { return }
            self.show(tooltip, at: anchor)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0.05 : delay), execute: work)
    }

    func leave(_ anchor: TooltipAnchor) {
        guard current === anchor else { return }
        pending?.cancel()
        current = nil
        hide()
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    private func show(_ tooltip: Tooltip, at anchor: TooltipAnchor) {
        guard let rect = anchor.screenRect, let window = anchor.view?.window else { return }
        let panel = self.panel ?? makePanel()
        let view = TooltipView(tooltip: tooltip)
        if let host { host.rootView = view } else {
            let h = NSHostingView(rootView: view)
            panel.contentView = h
            host = h
        }
        panel.appearance = window.effectiveAppearance
        let size = host!.fittingSize
        // Above the control, centered on it; below when there's no room
        // above in the window (a control near the top). Kept inside the
        // window's edges.
        let gap: CGFloat = 6 - TooltipView.shadowRoom
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + gap)
        if origin.y + size.height - TooltipView.shadowRoom > window.frame.maxY - 28 {
            origin.y = rect.minY - gap - size.height
        }
        let margin: CGFloat = 8 - TooltipView.shadowRoom
        origin.x = min(max(origin.x, window.frame.minX + margin), window.frame.maxX - margin - size.width)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        p.collectionBehavior = [.transient, .ignoresCycle]
        panel = p
        return p
    }
}

struct TooltipView: View {
    let tooltip: Tooltip
    /// Transparent room around the box for its shadow.
    static let shadowRoom: CGFloat = 14

    /// The text column's width: as wide as the title row or the detail
    /// needs, up to the maximum (then the detail wraps). Measured here so
    /// the panel's size matches how the text wraps.
    static func textWidth(_ t: Tooltip) -> CGFloat {
        func width(_ s: String, _ weight: NSFont.Weight) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Theme.Size.control, weight: weight)]).width)
        }
        var row = width(t.title, .bold)
        if let k = t.shortcut { row += Theme.Space.l + width(k, .semibold) }
        let detail = t.detail.map { width($0, .regular) } ?? 0
        return min(Theme.Tooltip.maxTextWidth, max(row, detail))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + Theme.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
                Text(tooltip.title)
                    .font(.toasty(Theme.Size.control, .bold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if let shortcut = tooltip.shortcut {
                    Text(shortcut)
                        .font(.toasty(Theme.Size.control, .semibold))
                        .foregroundStyle(Color.primary.opacity(Theme.Tooltip.secondaryOpacity))
                }
            }
            if let detail = tooltip.detail {
                Text(detail)
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(Color.primary.opacity(Theme.Tooltip.secondaryOpacity))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.textWidth(tooltip), alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + Theme.Space.xxs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.Tooltip.background))
        // A light inner edge and a dark outer hairline, like a popover.
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.Tooltip.innerBorder, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .stroke(Theme.Tooltip.outerBorder, lineWidth: 0.5))
        .popoverShadow()
        .padding(Self.shadowRoom)
    }
}
