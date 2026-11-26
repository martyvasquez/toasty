import AppKit
import SwiftUI

/// Column widths of the split view, mirrored by the titlebar row so each
/// column's tabs sit over it.
final class WindowLayout: ObservableObject {
    /// Width of the right column (0 when hidden); animated along with the
    /// column when it slides open or closed.
    @Published var terminalWidth: CGFloat = 0
    /// The right column's width when open: its bar is laid out at this
    /// width and uncovered as `terminalWidth` grows (not squeezed).
    @Published var terminalOpenWidth: CGFloat = 0
    /// Room for the window buttons when the workspaces sidebar is hidden.
    @Published var leadingInset: CGFloat = 0
    /// The window buttons' center, from the titlebar's top: the row's
    /// controls share their line (as Things' toolbar does).
    @Published var buttonsMidY: CGFloat = 0
}

/// The titlebar row right of the workspaces sidebar: the conversation tabs
/// over the conversation; over the widget column, the spaces' dots and the
/// edit button (in edit mode, the spaces as thumbnails, + and Done); and at the window's right, the
/// browser and the widgets button. One page-colored bar: the widgets float
/// under it, as they float on the page. Hosted in the window's titlebar
/// view (views under a transparent titlebar don't get clicks).
struct TitlebarRow: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout

    /// The bar's margin at each end (Things' toolbar: 12).
    static let edge: CGFloat = 12

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = store.active {
                TitlebarContent(store: store, layout: layout, workspace: workspace)
            } else {
                Spacer()
            }
        }
        // The bar is the window buttons' band (centered on their line, as
        // Things' toolbar); the titlebar's extra height below it belongs to
        // the content.
        .frame(height: layout.buttonsMidY > 0 ? layout.buttonsMidY * 2 : nil)
        .background(ZStack { Color.claudeBackground; WindowDragArea() })
        .overlay(alignment: .bottom) {
            if store.active != nil { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WindowDragArea())
    }
}

private struct TitlebarContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout
    @ObservedObject var workspace: Workspace
    /// The browser's indicator comes and goes with its setting.
    @ObservedObject private var preview = PreviewSettings.shared

    var body: some View {
        let column = layout.terminalWidth
        let editing = store.editingWidgets && column > 0
        HStack(spacing: 0) {
            ConversationTabBar(workspace: workspace)
                .id(workspace.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, layout.leadingInset)
            // The browser belongs to the conversation: its indicator ends
            // the conversation's row, just outside the widgets (at the
            // window's edge when they're hidden).
            // The terminal drawer under the conversation (an experiment).
            BarIconButton(symbol: "rectangle.bottomthird.inset.filled",
                          tooltip: Tooltip(title: workspace.drawerOpen ? "Close Terminal Drawer" : "Open Terminal Drawer", shortcut: "⌘J",
                                           detail: "A terminal under the conversation, with its own tabs."),
                          size: CGSize(width: 28, height: TabStyle.height)) {
                AppDelegate.shared.windowController?.setTerminalDrawer(open: !workspace.drawerOpen)
            }
            .padding(.trailing, column > 1 ? Theme.Space.s : TitlebarRow.edge - Theme.Space.xs)
            // Over the column (at its open width, uncovered from its edge as
            // it slides): the dots, centered, and Edit Widgets in its
            // corner; editing, the spaces' thumbnails and Done. (The
            // widgets show and hide by the handle at the conversation's
            // edge, as the workspaces do, and ⌃⌘I.)
            ZStack {
                if editing {
                    SpaceEditBar(store: store, workspace: workspace)
                        .padding(.horizontal, TitlebarRow.edge)
                } else {
                    SpaceDots(store: store, workspace: workspace)
                    EditWidgetsButton()
                        .padding(.trailing, TitlebarRow.edge - Theme.Space.xs)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: max(layout.terminalOpenWidth, column))
            .frame(width: column, alignment: .leading)
            .clipped()
            .opacity(column > 1 ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: editing)
    }
}

// MARK: - Tab style (shared by conversation and terminal tabs)

enum TabStyle {
    static let height: CGFloat = 28
    static let radius: CGFloat = 8
    static let gap: CGFloat = 4
    static let fontSize = Theme.Size.control

    /// The end of a hovered tab, for its close button.
    static let closeRoom: CGFloat = 28

    /// Whether a conversation's tab shows a status mark.
    @MainActor static func hasStatus(_ c: ClaudeConversation) -> Bool {
        !c.requests.isEmpty || c.phase != .idle || c.attention
    }

    /// A title's width at the selected tab's weight (so selecting a tab
    /// never changes its size).
    static func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width)
    }
}

/// Tabs share the bar buttons' states (`BarButtonStyle`, as Things'
/// toolbar): the selected tab is a filled capsule, a hovered one gets a
/// hairline capsule, the rest are bare.
struct TabBackground: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        Capsule()
            .fill(selected ? Theme.Fill.selected : Color.clear)
            .overlay(Capsule().strokeBorder(hovering && !selected ? Theme.Stroke.hover : Color.clear, lineWidth: 1))
    }
}

struct TabCloseButton: View {
    let visible: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.toasty(Theme.Glyph.small, .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Theme.Space.s)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .tooltipText(help)
        .accessibilityLabel("Close")
    }
}

struct NewTabButton: View {
    let tooltip: Tooltip
    let action: () -> Void

    var body: some View {
        BarIconButton(symbol: "plus", tooltip: tooltip, size: CGSize(width: 28, height: TabStyle.height), action: action)
    }
}

/// The tab row's + (a new conversation) with the new-terminal button
/// tucked behind it: hovering the + slides the terminal button out to its
/// right, so clicking where the + sits still starts a conversation and a
/// terminal is one step over. It folds back shortly after the pointer
/// leaves, so sliding across doesn't lose it. The strip reserves both
/// buttons' room, so opening it never moves the tabs.
struct ExpandingNewTabButton: View {
    let newConversation: () -> Void
    /// The workspace's browser (its tab, or its window), while it's on.
    var newBrowser: (() -> Void)? = nil
    let newTerminal: () -> Void
    @State private var open = false
    @State private var collapse: DispatchWorkItem?
    private let size = CGSize(width: 28, height: TabStyle.height)

    var body: some View {
        HStack(spacing: 0) {
            NewTabButton(tooltip: Tooltip(title: "New Tab", shortcut: "⌘T",
                                          detail: "Another conversation in this workspace."),
                         action: newConversation)
                .onHover(perform: hover)
            BarIconButton(symbol: "apple.terminal",
                          tooltip: Tooltip(title: "New Terminal Tab", shortcut: "⇧⌘T",
                                           detail: "A shell in this workspace's folder, as a tab."),
                          size: size, action: newTerminal)
                .onHover(perform: hover)
                .opacity(open ? 1 : 0)
                .offset(x: open ? 0 : -10)
                .allowsHitTesting(open)
                .frame(width: open ? size.width : 0, alignment: .leading)
                .clipped()
            if let newBrowser {
                BarIconButton(symbol: "safari",
                              tooltip: Tooltip(title: "New Browser Tab", detail: "A page in this workspace's browser (its logins and storage), for the site you're building."),
                              size: size, action: newBrowser)
                    .onHover(perform: hover)
                    .opacity(open ? 1 : 0)
                    .offset(x: open ? 0 : -10)
                    .allowsHitTesting(open)
                    .frame(width: open ? size.width : 0, alignment: .leading)
                    .clipped()
            }
        }
        .frame(width: size.width * (newBrowser == nil ? 2 : 3), alignment: .leading)
    }

    private func hover(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            withAnimation(.easeOut(duration: 0.16)) { open = true }
        } else {
            let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.16)) { open = false } }
            collapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}

// MARK: - Tab strip

/// A row of tabs that never grows past the room it's given: tabs share the
/// width evenly (up to `maxWidth`), shrink to `minWidth`, and past that the
/// row scrolls sideways, keeping the selected tab in view. `trailing` (the
/// + button) follows the last tab and always stays visible; with no tabs
/// it's where the first one would be.
///
/// Tabs are dragged along the row to reorder them (`move`): the dragged tab
/// follows the pointer, the others step aside, and the order changes when
/// it's let go.
struct FittingTabStrip<Item: Identifiable, Tab: View, Trailing: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedID: Item.ID?
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// A tab's natural width (what its title needs). With room, each tab
    /// is that wide (within min…max); without, the widest shrink first.
    /// Nil: the tabs share the row evenly.
    var naturalWidth: ((Item) -> CGFloat)? = nil
    /// A drag began on this tab (it becomes the selected one, as in Safari).
    var pick: ((Item) -> Void)?
    /// Put the tab at this index.
    var move: ((Item.ID, Int) -> Void)?
    /// The trailing buttons' width.
    var trailingWidth: CGFloat = 28
    /// A tab that takes the room the others leave, from `expandedMin` to
    /// `expandedMax` (the browser's tab while selected: it's the address
    /// bar, as Safari's compact tabs). Not dragged by its body.
    var expandedID: Item.ID? = nil
    var expandedMin: CGFloat = 0
    var expandedMax: CGFloat = .infinity
    @ViewBuilder let tab: (Item) -> Tab
    @ViewBuilder let trailing: () -> Trailing

    /// A tab being dragged along the row.
    private struct Drag {
        let id: Item.ID
        /// Where it was picked up.
        let from: Int
        /// How far it is from its own place.
        var x: CGFloat = 0
        /// Let go: it has its new place, and is sliding the rest of the way.
        var settling = false
    }

    @State private var dragState: Drag?

    /// The drag, while its tab is still in the row.
    private var drag: Drag? {
        dragState.flatMap { d in items.contains { $0.id == d.id } ? d : nil }
    }

    /// The trailing buttons' width plus its gap.
    private var trailingRoom: CGFloat { trailingWidth + TabStyle.gap }

    var body: some View {
        GeometryReader { geo in
            let room = max(0, geo.size.width - trailingRoom)
            let widths = layout(room: room)
            let xs = positions(widths)
            let content = widths.isEmpty ? 0 : (xs.last ?? 0) + (widths.last ?? 0)
            HStack(spacing: TabStyle.gap) {
                if !items.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: TabStyle.gap) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                    let dragged = drag?.id == item.id
                                    tab(item).frame(width: widths[i]).id(item.id)
                                        .offset(x: offset(of: i, widths: widths, xs: xs))
                                        .zIndex(dragged ? 1 : 0)
                                        // The dragged tab stays under the pointer
                                        // while the others slide.
                                        .transaction { if dragged, drag?.settling == false { $0.animation = nil } }
                                        .gesture(reorder(item, at: i, widths: widths, xs: xs),
                                                 including: move == nil || item.id == expandedID ? .subviews : .all)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollIndicators(.never)
                        .scrollDisabled(content <= room)
                        .frame(width: min(content, room))
                        .onAppear { reveal(selectedID, proxy) }
                        .onChange(of: selectedID) { _, id in reveal(id, proxy) }
                        .onChange(of: items.count) { reveal(selectedID, proxy) }
                    }
                }
                trailing()
                Spacer(minLength: 0)
            }
            .frame(height: geo.size.height)
        }
    }

    /// Each tab's width in `room`.
    private func layout(room: CGFloat) -> [CGFloat] {
        if let id = expandedID, let i = items.firstIndex(where: { $0.id == id }) {
            let rest = FittingTabStrip(items: items.filter { $0.id != id }, selectedID: selectedID, minWidth: minWidth,
                                       maxWidth: maxWidth, naturalWidth: naturalWidth, tab: tab, trailing: trailing)
            let gap = items.count > 1 ? TabStyle.gap : 0
            var widths = rest.layout(room: max(0, room - expandedMin - gap))
            let used = widths.reduce(0, +) + TabStyle.gap * CGFloat(max(0, widths.count - 1)) + gap
            widths.insert(max(expandedMin, min(expandedMax, (room - used).rounded(.down))), at: i)
            return widths
        }
        let n = CGFloat(items.count)
        guard n > 0 else { return [] }
        let gaps = TabStyle.gap * (n - 1)
        guard let naturalWidth else {
            let even = min(maxWidth, max(minWidth, (room - gaps) / n))
            return Array(repeating: even, count: items.count)
        }
        let natural = items.map { min(maxWidth, max(minWidth, naturalWidth($0).rounded(.up))) }
        if natural.reduce(0, +) + gaps <= room { return natural }
        // Too wide: cap every tab at the width that fits (the widest give
        // way first), never below the minimum (then the row scrolls).
        func total(_ cap: CGFloat) -> CGFloat { natural.reduce(0) { $0 + min($1, cap) } + gaps }
        var lo = minWidth, hi = maxWidth
        for _ in 0..<24 { let mid = (lo + hi) / 2; if total(mid) > room { hi = mid } else { lo = mid } }
        return natural.map { min($0, lo).rounded(.down) }
    }

    /// Each tab's leading edge.
    private func positions(_ widths: [CGFloat]) -> [CGFloat] {
        var x: CGFloat = 0
        return widths.map { w in defer { x += w + TabStyle.gap }; return x }
    }

    private func reveal(_ id: Item.ID?, _ proxy: ScrollViewProxy) {
        guard let id, drag == nil else { return }
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) } }
    }

    // MARK: Reordering

    /// The place the dragged tab would take if let go now: past every tab
    /// whose middle its middle has crossed.
    private func target(_ drag: Drag, widths: [CGFloat], xs: [CGFloat]) -> Int {
        let f = drag.from
        let mid = xs[f] + drag.x + widths[f] / 2
        var to = f
        for j in items.indices where j != f {
            let center = xs[j] + widths[j] / 2
            if j > f, mid > center { to = max(to, j) }
            if j < f, mid < center { to = min(to, j) }
        }
        return to
    }

    /// How far the tab at `i` is drawn from its place: the dragged tab by
    /// the drag, the tabs it has passed by its width the other way.
    private func offset(of i: Int, widths: [CGFloat], xs: [CGFloat]) -> CGFloat {
        guard let drag, items.indices.contains(drag.from) else { return 0 }
        if items[i].id == drag.id { return drag.x }
        guard !drag.settling else { return 0 }
        let to = target(drag, widths: widths, xs: xs)
        let step = widths[drag.from] + TabStyle.gap
        if drag.from < i, i <= to { return -step }
        if to <= i, i < drag.from { return step }
        return 0
    }

    private func reorder(_ item: Item, at i: Int, widths: [CGFloat], xs: [CGFloat]) -> some Gesture {
        // Global: the tab moves with the drag, so its own coordinates do too.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                var d = drag ?? Drag(id: item.id, from: i)
                guard d.id == item.id, !d.settling, widths.indices.contains(d.from) else { return }
                if drag == nil { pick?(item) }
                let before = target(d, widths: widths, xs: xs)
                // Never past either end of the row.
                let lo = -xs[d.from]
                let hi = (xs.last ?? 0) + (widths.last ?? 0) - widths[d.from] - xs[d.from]
                d.x = max(lo, min(hi, value.translation.width))
                if target(d, widths: widths, xs: xs) != before {
                    withAnimation(.easeInOut(duration: 0.15)) { dragState = d }
                } else {
                    dragState = d
                }
            }
            .onEnded { _ in
                guard var d = drag, d.id == item.id, !d.settling, widths.indices.contains(d.from) else { return }
                let to = target(d, widths: widths, xs: xs)
                // Where it lands in the new order; the others are already
                // drawn there, so that happens at once and the dragged tab
                // slides from where it was let go.
                var order = Array(widths.indices)
                order.remove(at: d.from)
                order.insert(d.from, at: to)
                let landX = order.prefix(to).reduce(0) { $0 + widths[$1] + TabStyle.gap }
                d.x -= landX - xs[d.from]
                d.settling = true
                var now = Transaction()
                now.disablesAnimations = true
                withTransaction(now) {
                    dragState = d
                    move?(item.id, to)
                }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { dragState = nil }
                }
            }
    }
}

// MARK: - Conversation tabs

private struct ConversationTabBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = PreviewSettings.shared

    var body: some View {
        FittingTabStrip(items: workspace.topTabs, selectedID: workspace.shownTopTabID,
                        minWidth: 90, maxWidth: 240,
                        naturalWidth: { tab in
                            switch tab {
                            case .conversation(let c):
                                // Title, a fork's mark, a status mark, and room
                                // at the end for the close button.
                                // (12 each side; see ConversationTabItem).
                                return TabStyle.titleWidth(c.title) + Theme.Space.m * 2 + 1
                                    + (c.forkOrigin != nil ? 15 : 0)
                                    + (TabStyle.hasStatus(c) ? 18 : 0)  // a gap, a dot or spinner (12)
                            case .terminal(let t):
                                // The terminal mark, its gap, and the title.
                                return TabStyle.titleWidth(workspace.tabTerminalLabel(t)) + Theme.Space.m * 2 + 1 + 18
                            case .browser(let id):
                                // A pseudo-tab (in its window) has the ≡ too.
                                let session = PreviewStore.shared.page(id, in: workspace)
                                return TabStyle.titleWidth(BrowserTabItem.title(session)) + Theme.Space.m * 2 + 1 + 18
                                    + (workspace.browserTab(id)?.isDetached == true ? 26 : 0)
                            }
                        },
                        pick: { if $0.id != workspace.shownTopTabID { workspace.selectTopTab($0) } },
                        move: { workspace.moveTopTab($0, to: $1) },
                        trailingWidth: 28 * (settings.enabled ? 3 : 2),
                        expandedID: settings.enabled ? workspace.shownBrowserTabID : nil,
                        expandedMin: BrowserTabItem.expandedMin,
                        expandedMax: BrowserTabItem.expandedMax) { tab in
            switch tab {
            case .conversation(let c):
                ConversationTabItem(conversation: c, selected: c.id == workspace.shownTopTabID, workspace: workspace)
            case .terminal(let t):
                TopTerminalTabItem(session: t, selected: t.id == workspace.shownTopTabID, workspace: workspace)
            case .browser(let id):
                BrowserTabItem(session: PreviewStore.shared.page(id, in: workspace), id: id,
                               selected: id == workspace.shownTopTabID, workspace: workspace)
            }
        } trailing: {
            ExpandingNewTabButton(newConversation: { workspace.newConversation() },
                                  newBrowser: settings.enabled ? { workspace.newBrowserTab() } : nil,
                                  newTerminal: {
                                      workspace.newTabTerminal()
                                      AppDelegate.shared.windowController?.focusTabTerminal()
                                  })
        }
        .padding(.leading, TitlebarRow.edge)
        .padding(.trailing, 6)
    }
}

private struct ConversationTabItem: View {
    @ObservedObject var conversation: ClaudeConversation
    let selected: Bool
    let workspace: Workspace
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
            // A fork's branch mark (its title, "… (fork)", is often cut off).
            if conversation.forkOrigin != nil {
                Image(systemName: "arrow.triangle.branch")
                    .font(.toasty(Theme.Glyph.small, .semibold))
                    .foregroundStyle(.secondary)
            }
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.toasty(TabStyle.fontSize, .medium))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { renaming = false }
                    .onAppear { draft = conversation.title; DispatchQueue.main.async { fieldFocused = true } }
                    .onChange(of: fieldFocused) { _, focused in if !focused && renaming { commit() } }
            } else {
                Text(conversation.title)
                    .font(.toasty(TabStyle.fontSize, selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Status right after the title, so it stays with its name.
            if !renaming, TabStyle.hasStatus(conversation) {
                ConversationStatusIcon(conversation: conversation, selected: selected)
                    .frame(height: 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Even padding at rest; on hover the close button takes the end and
        // the title makes room for it.
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, hovering && !renaming ? TabStyle.closeRoom : Theme.Space.m)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .frame(height: TabStyle.height)
        .background(TabBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { workspace.select(conversation) } }
        .overlay(alignment: .trailing) {
            TabCloseButton(visible: hovering && !renaming, help: "Close Tab (⌘W)") { workspace.requestClose(conversation) }
        }
        .onHover { hovering = $0 }
        .tooltipText(conversation.title)
        .contextMenu {
            let index = workspace.topTabs.firstIndex { $0.id == conversation.id } ?? 0
            Button("Rename…") { renaming = true }
            Divider()
            Button("Move Left") { workspace.moveTopTab(conversation.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { workspace.moveTopTab(conversation.id, to: index + 1) }
                .disabled(index >= workspace.topTabs.count - 1)
            Divider()
            Button("Close Tab") { workspace.requestClose(conversation) }
            Button("Close Other Tabs") { workspace.requestCloseOthers(than: conversation) }
                .disabled(workspace.conversations.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(conversation.title)
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.customTitle = t.isEmpty ? nil : t
        renaming = false
        workspace.renamed()
    }
}

/// A terminal tab in the top row: the terminal mark and what's running
/// (or the folder), styled exactly as a conversation's tab.
private struct TopTerminalTabItem: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
            Image(systemName: "apple.terminal")
                .font(.toasty(Theme.Glyph.small, .semibold))
                .foregroundStyle(.secondary)
            Text(workspace.tabTerminalLabel(session))
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
            workspace.showTabTerminal(session.id)
            AppDelegate.shared.windowController?.focusTabTerminal()
        }
        .overlay(alignment: .trailing) {
            TabCloseButton(visible: hovering, help: "Close Tab (⌘W)") { workspace.requestCloseTabTerminal(session.id) }
        }
        .onHover { hovering = $0 }
        .tooltipText("\(session.displayTitle)\n\((session.directory as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            let index = workspace.topTabs.firstIndex { $0.id == session.id } ?? 0
            Button("Move Left") { workspace.moveTopTab(session.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { workspace.moveTopTab(session.id, to: index + 1) }
                .disabled(index >= workspace.topTabs.count - 1)
            Divider()
            Button("Close Tab") { workspace.requestCloseTabTerminal(session.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Terminal: \(session.displayTitle)")
    }
}

/// The browser's tab (the experiment): the compass and the page's
/// address, styled exactly as the other tabs. The compass is accent-colored
/// and pulses while Claude is using the page, as the titlebar's.
private struct BrowserTabItem: View {
    @ObservedObject var session: PreviewSession
    let id: UUID
    let selected: Bool
    let workspace: Workspace
    @ObservedObject private var settings = PreviewSettings.shared
    @State private var hovering = false

    /// Selected, the tab is the address bar (as Safari's compact tabs):
    /// a little wider than a tab, never the whole row.
    static let expandedMin: CGFloat = 260
    static let expandedMax: CGFloat = 400

    static func title(_ session: PreviewSession) -> String {
        session.url.map { PreviewSession.display($0) } ?? (session.address.isEmpty ? "Browser" : session.address)
    }

    private var expanded: Bool { selected && workspace.shownBrowserTabID == id && settings.enabled }
    /// In a window of its own: a pseudo-tab (dashed, never selected) that
    /// brings the window forward.
    private var detached: Bool { workspace.browserTab(id)?.isDetached == true }
    /// Claude's tab: the conversation whose Claude drives it.
    private var owner: ClaudeConversation? {
        workspace.browserTab(id)?.owner.flatMap { o in workspace.conversations.first { $0.id == o } }
    }

    var body: some View {
        Group {
            if detached { pseudo } else if expanded { bar } else { tab }
        }
        .frame(height: TabStyle.height)
        .background {
            // Claude's tab is blue (the user, 2026-11-26, instead of a
            // mark): an accent outline, the whole tab blue when shown.
            if detached {
                // Never filled (it isn't the shown tab): a dashed outline,
                // the tab that left the row for its window (blue for
                // Claude's).
                Capsule().strokeBorder(isClaude ? Color.accentColor.opacity(hovering ? 0.9 : 0.7)
                                                : (hovering ? Theme.Stroke.dashedHover : Theme.Stroke.dashed),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else if isClaude {
                Capsule().fill(Color.accentColor.opacity(selected ? 0.24 : (hovering ? 0.08 : 0)))
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(selected ? 0 : 0.75), lineWidth: 1))
            } else {
                TabBackground(selected: selected, hovering: hovering)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            let index = workspace.topTabs.firstIndex { $0.id == id } ?? 0
            Button("Move Left") { workspace.moveTopTab(id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { workspace.moveTopTab(id, to: index + 1) }
                .disabled(index >= workspace.topTabs.count - 1)
            Divider()
            if detached {
                Button("Show Window") { PreviewStore.shared.showWindow(page: id, in: workspace) }
                Button("Move Back to Tab") { PreviewStore.shared.attach(id, in: workspace) }
            } else {
                Button("Move to Window") { PreviewStore.shared.detach(id, in: workspace) }
            }
            Divider()
            Button(detached ? "Close Browser" : "Close Tab") { PreviewStore.shared.closeBrowserTab(id, in: workspace) }
        }
        .accessibilityElement(children: expanded ? .contain : .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Browser: \(Self.title(session))")
    }

    /// Claude's tab (its conversation may be closed since).
    private var isClaude: Bool { workspace.browserTab(id)?.owner != nil }

    /// The compass: accent and pulsing while Claude uses the page.
    private var compass: some View {
        Image(systemName: "safari")
            .font(.toasty(Theme.Glyph.small, .semibold))
            .foregroundStyle(session.agentActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .modifier(PulseWhile(active: session.agentActive))
    }

    /// In its own window: the compass and the address (a click brings the
    /// window forward) and ≡: Show Window, Move Back to Tab, Close.
    private var pseudo: some View {
        HStack(spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                compass
                Text(Self.title(session))
                    .font(.toasty(TabStyle.fontSize))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { PreviewStore.shared.showWindow(page: id, in: workspace) }
            ClaudePopUp(items: [], makeItems: {
                [.init(title: "Show Window", symbol: "macwindow") { PreviewStore.shared.showWindow(page: id, in: workspace) },
                 .init(title: "Move Back to Tab", symbol: "rectangle.topthird.inset.filled") { PreviewStore.shared.attach(id, in: workspace) },
                 .init(title: "Close Browser", symbol: "xmark") { PreviewStore.shared.closeBrowserTab(id, in: workspace) }]
            }) { over in
                Image(systemName: "line.3.horizontal")
                    .font(.toasty(Theme.Size.meta, .medium))
                    .foregroundStyle(over ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(over ? Theme.Fill.subtle : Color.clear))
            }
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .tooltipText((owner.map { "Claude's browser, for “\($0.title)”, in its own window" } ?? "Browser, in its own window")
                     + (session.url.map { "\n\($0.absoluteString)" } ?? ""))
    }

    /// Not selected: a tab like the others (the compass and the address).
    private var tab: some View {
        HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
            compass
            Text(Self.title(session))
                .font(.toasty(TabStyle.fontSize, selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, hovering ? TabStyle.closeRoom : Theme.Space.m)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { workspace.showBrowserTab(id) }
        .overlay(alignment: .trailing) {
            TabCloseButton(visible: hovering, help: "Close Tab (⌘W)") { PreviewStore.shared.closeBrowserTab(id, in: workspace) }
        }
        .tooltipText((owner.map { "Claude's browser tab, for “\($0.title)”" } ?? "Browser")
                     + (session.url.map { "\n\($0.absoluteString)" } ?? ""))
    }

    /// Selected: the address bar (`BrowserAddressBar`, the window's too),
    /// its ≡ menu with what a tab can do.
    private var bar: some View {
        BrowserAddressBar(session: session) {
            [.init(title: settings.fillsWindow ? "Show Workspaces and Widgets" : "Fill the Window",
                   symbol: settings.fillsWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                 settings.fillsWindow.toggle()
             },
             .init(title: "Move to Window", symbol: "macwindow") { PreviewStore.shared.detach(id, in: workspace) },
             .init(title: "Close Tab", symbol: "xmark") { PreviewStore.shared.closeBrowserTab(id, in: workspace) }]
        }
    }
}

/// A conversation's status, by the sidebar's rules (see `StatusColor`,
/// `StatusDot`): an orange dot when it needs you, the spinner while it
/// works, a blue dot when it finished while you weren't looking, a red one
/// when it stopped on a problem (orange and red pulse for their first
/// minute); nothing when idle.
struct ConversationStatusIcon: View {
    @ObservedObject var conversation: ClaudeConversation
    let selected: Bool

    var body: some View {
        if !conversation.requests.isEmpty {
            StatusDot(color: StatusColor.needsInput, pulses: true)
        } else if conversation.phase != .idle {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
        } else if conversation.attention {
            let stopped = Activity.shared.isStopped(conversation)
            StatusDot(color: stopped ? StatusColor.stopped : StatusColor.ready, pulses: stopped)
        }
    }
}

// MARK: - Terminal tabs

struct TerminalTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        // Never narrower than a whole "Terminal N" (past that the strip
        // scrolls, keeping the selected one in view).
        let whole = TabStyle.titleWidth("Terminal \(max(9, workspace.terminals.count))") + Theme.Space.m * 2 + 1
        FittingTabStrip(items: workspace.terminals, selectedID: workspace.selectedTerminalID,
                        minWidth: whole, maxWidth: 180,
                        naturalWidth: { t in TabStyle.titleWidth(workspace.terminalLabel(t)) + Theme.Space.m * 2 + 1 },
                        pick: { if $0.id != workspace.selectedTerminalID { workspace.selectTerminal($0.id) } },
                        move: { workspace.moveTerminal($0, to: $1) }) { t in
            TerminalTabItem(session: t, selected: t.id == workspace.selectedTerminalID, workspace: workspace)
        } trailing: {
            NewTabButton(tooltip: Tooltip(title: "New Terminal", shortcut: "⌥⌘T",
                                          detail: "A shell in this workspace's folder.")) {
                workspace.newTerminal()
                AppDelegate.shared.windowController?.focusTerminal()
            }
        }
        .padding(.leading, TitlebarRow.edge)
    }
}

private struct TerminalTabItem: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(workspace.terminalLabel(session))
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
            workspace.selectTerminal(session.id)
            AppDelegate.shared.windowController?.focusTerminal()
        }
        .overlay(alignment: .trailing) {
            TabCloseButton(visible: hovering, help: "Close Terminal") { workspace.requestCloseTerminal(session.id) }
        }
        .onHover { hovering = $0 }
        .tooltipText("\(session.displayTitle)\n\((session.directory as NSString).abbreviatingWithTildeInPath)")
        .contextMenu {
            let index = workspace.terminals.firstIndex { $0.id == session.id } ?? 0
            Button("Move Left") { workspace.moveTerminal(session.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { workspace.moveTerminal(session.id, to: index + 1) }
                .disabled(index >= workspace.terminals.count - 1)
            Divider()
            Button("Close Terminal") { workspace.requestCloseTerminal(session.id) }
            Button("Close Other Terminals") {
                workspace.terminals.filter { $0.id != session.id }.forEach { workspace.requestCloseTerminal($0.id) }
            }
            .disabled(workspace.terminals.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(workspace.terminalLabel(session)): \(session.displayTitle)")
    }
}

/// Lets the window be dragged (and zoomed with a double-click) from empty
/// parts of the tab row, like a real titlebar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Handles the drag and the double-click itself. It doesn't also claim
    /// `mouseDownCanMoveWindow`: then the titlebar runs its own double-click
    /// as well, and the window zooms and straight back.
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                // System Settings › Desktop & Dock › "Double-click a window's
                // title bar to": zoom (the default), minimize, or nothing.
                let defaults = UserDefaults.standard
                switch defaults.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                case "Maximize", "Fill": window.performZoom(nil)
                default:
                    if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") { window.performMiniaturize(nil) }
                    else { window.performZoom(nil) }
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
