import AppKit
import Combine
import SwiftUI

// MARK: - Terminal drawer (an experiment)
//
// A terminal under the conversation: opened (⌘J, or the titlebar button),
// the conversation slides up and the drawer slides in from below it, as
// the sidebars slide. It has its own tabs, and its top edge drags to set
// how much of the column it takes (the same height in every workspace).

/// The drawer's height when open, as the user dragged it.
@MainActor
final class DrawerLayout: ObservableObject {
    static let shared = DrawerLayout()
    private static let key = "ToastyTerminalDrawerHeight"
    static let minHeight: CGFloat = 140
    /// Always leaves this much of the column to the conversation.
    static let conversationMin: CGFloat = 220

    @Published var height: CGFloat
    /// How much of the drawer is on screen now (0 closed), through its
    /// slide: the edge handles end above it.
    @Published var shown: CGFloat = 0

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        height = stored > 0 ? stored : 300
    }

    func save() { UserDefaults.standard.set(Double(height), forKey: Self.key) }

    /// The open height in a column `room` tall.
    func openHeight(in room: CGFloat) -> CGFloat {
        max(Self.minHeight, min(height, room - Self.conversationMin))
    }
}

/// The middle column's view: the conversation (and everything else the
/// column shows) above, the drawer below. `reveal` (0 closed, 1 open) is
/// animated, so the conversation's bottom edge and the drawer move together.
final class ColumnContainerView: NSView {
    let top = NSView()
    let drawer: NSView
    private let edge = DrawerEdgeView()
    private var cancellables: Set<AnyCancellable> = []

    @objc dynamic var reveal: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    init(drawer: NSView) {
        self.drawer = drawer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(top)
        addSubview(drawer)
        addSubview(edge)
        DrawerLayout.shared.$height
            .sink { [weak self] _ in DispatchQueue.main.async { self?.needsLayout = true } }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "reveal" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    override func layout() {
        super.layout()
        let open = DrawerLayout.shared.openHeight(in: bounds.height)
        let shown = (open * reveal).rounded()
        top.frame = NSRect(x: 0, y: shown, width: bounds.width, height: bounds.height - shown)
        // The drawer keeps its open height and slides: what's below the
        // column's edge is cut off.
        drawer.frame = NSRect(x: 0, y: shown - open, width: bounds.width, height: open)
        drawer.isHidden = reveal <= 0
        // The top 8pt of the drawer, under its divider.
        edge.frame = NSRect(x: 0, y: shown - 8, width: bounds.width, height: 8)
        edge.isHidden = reveal < 1
        if DrawerLayout.shared.shown != shown { DrawerLayout.shared.shown = shown }
        window?.invalidateCursorRects(for: edge)
    }

    /// Open or close it, sliding unless `animated` is false.
    func setOpen(_ open: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        let target: CGFloat = open ? 1 : 0
        guard reveal != target else { completion?(); return }
        guard animated, window != nil else {
            reveal = target
            layoutSubtreeIfNeeded()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().reveal = target
        } completionHandler: {
            completion?()
        }
    }
}

/// The drawer: a header exactly like the window's tab row (full width,
/// its height, margins, tabs and buttons) over the selected terminal at
/// the conversation's width and edges, on the page. A hairline over it and
/// one under its tabs, each fading out at its right end (beside the
/// floating widgets, where a line would stop in the gap).
struct TerminalDrawerView: View {
    @ObservedObject var store: WorkspaceStore
    let window: WindowLayout

    var body: some View {
        ZStack {
            Color.claudeBackground
            if let workspace = store.active {
                DrawerContent(workspace: workspace, window: window)
            }
        }
    }
}

private struct DrawerContent: View {
    @ObservedObject var workspace: Workspace
    /// The tab row's height comes from the window buttons' line.
    @ObservedObject var window: WindowLayout
    @ObservedObject private var settings = TerminalLayoutSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // The tab row's twin.
            HStack(spacing: 0) {
                DrawerTabBar(workspace: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                BarIconButton(symbol: "chevron.down",
                              tooltip: Tooltip(title: "Close Terminal Drawer", shortcut: "⌘J",
                                               detail: "Its terminals keep running."),
                              glyphSize: Theme.Size.body,
                              size: CGSize(width: 32, height: TabStyle.height)) {
                    AppDelegate.shared.windowController?.setTerminalDrawer(open: false)
                }
                .padding(.trailing, TitlebarRow.edge - Theme.Space.xs)
            }
            .frame(height: window.buttonsMidY > 0 ? window.buttonsMidY * 2 : 52)
            .overlay(alignment: .bottom) { DrawerHairline(widgets: window.terminalWidth) }
            Group {
                if let session = workspace.selectedDrawerTerminal {
                    TerminalHost(session: session)
                        .id(session.id)
                } else {
                    Spacer()
                }
            }
            .terminalColumn(settings.drawerWidth)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
        }
        // Its top edge: the column's divider (dragged to resize).
        .overlay(alignment: .top) { DrawerHairline(widgets: window.terminalWidth) }
    }
}

/// The drawer's lines: the bar divider. Beside the widgets it fades out
/// over its last stretch (a line would stop in the gap by them); with them
/// closed it runs to the window's edge. The fade follows the widget
/// column's width as it slides.
private struct DrawerHairline: View {
    static let fade: CGFloat = 100
    /// The widget column's width now (0 when closed).
    let widgets: CGFloat

    var body: some View {
        Rectangle().fill(Theme.Stroke.barDivider)
            .frame(height: 1)
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: min(Self.fade, max(0, widgets)))
                }
            }
            .allowsHitTesting(false)
    }
}

/// The drawer's top edge, dragged to set its height (the resize cursor
/// over it, a line while it's held). Over the drawer's own top strip.
final class DrawerEdgeView: NSView {
    private var startY: CGFloat = 0
    private var startHeight: CGFloat = 0
    private var held = false { didSet { needsDisplay = true } }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func mouseDown(with event: NSEvent) {
        startY = event.locationInWindow.y
        startHeight = superview.map { DrawerLayout.shared.openHeight(in: $0.bounds.height) } ?? DrawerLayout.shared.height
        held = true
    }

    override func mouseDragged(with event: NSEvent) {
        // Up (window y grows upward) makes it taller.
        let wanted = startHeight + (event.locationInWindow.y - startY)
        let room = superview?.bounds.height ?? .greatestFiniteMagnitude
        DrawerLayout.shared.height = max(DrawerLayout.minHeight, min(wanted, room - DrawerLayout.conversationMin))
    }

    override func mouseUp(with event: NSEvent) {
        held = false
        DrawerLayout.shared.save()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard held else { return }
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: bounds.maxY - 1.5, width: bounds.width, height: 1.5).fill()
    }
}

private struct DrawerTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        FittingTabStrip(items: workspace.drawerTerminals, selectedID: workspace.selectedDrawerTerminalID,
                        minWidth: 90, maxWidth: 240,
                        naturalWidth: { t in TabStyle.titleWidth(t.displayTitle) + Theme.Space.m * 2 + 1 + 18 },
                        pick: { if $0.id != workspace.selectedDrawerTerminalID { workspace.selectDrawerTerminal($0.id) } },
                        move: { workspace.moveDrawerTerminal($0, to: $1) }) { t in
            DrawerTabItem(session: t, selected: t.id == workspace.selectedDrawerTerminalID, workspace: workspace)
        } trailing: {
            NewTabButton(tooltip: Tooltip(title: "New Terminal", shortcut: "⌘T",
                                          detail: "Another shell in the drawer, in this workspace's folder.")) {
                workspace.newDrawerTerminal()
                AppDelegate.shared.windowController?.focusDrawerTerminal()
            }
        }
        // The tab row's margins (ConversationTabBar).
        .padding(.leading, TitlebarRow.edge)
        .padding(.trailing, 6)
    }
}

private struct DrawerTabItem: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
            Image(systemName: "apple.terminal")
                .font(.toasty(Theme.Glyph.small, .semibold))
                .foregroundStyle(.secondary)
            Text(session.displayTitle)
                .font(.toasty(TabStyle.fontSize, selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, hovering ? TabStyle.closeRoom : Theme.Space.m)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .frame(height: TabStyle.height)
        .background(TabBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.selectDrawerTerminal(session.id)
            AppDelegate.shared.windowController?.focusDrawerTerminal()
        }
        .overlay(alignment: .trailing) {
            TabCloseButton(visible: hovering, help: "Close Terminal (⌘W)") { workspace.requestCloseDrawerTerminal(session.id) }
        }
        .onHover { hovering = $0 }
        .tooltipText("\(session.displayTitle)\n\((session.directory as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            Button("Close Terminal") { workspace.requestCloseDrawerTerminal(session.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Terminal: \(session.displayTitle)")
    }
}
