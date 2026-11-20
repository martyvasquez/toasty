import AppKit
import SwiftUI

/// Column widths of the split view, mirrored by the titlebar row so each
/// column's tabs sit over it.
final class WindowLayout: ObservableObject {
    /// Width of the right column (0 when hidden).
    @Published var terminalWidth: CGFloat = 0
    /// Room for the window buttons when the workspaces sidebar is hidden.
    @Published var leadingInset: CGFloat = 0
    /// The window buttons' center, from the titlebar's top: the row's
    /// controls share their line (as Things' toolbar does).
    @Published var buttonsMidY: CGFloat = 0
}

/// The titlebar row right of the workspaces sidebar: the conversation tabs
/// over the conversation, the inspector's tabs over the right column, and
/// the column toggle in the window's top-right corner. Hosted in the
/// window's titlebar view (views under a transparent titlebar don't get
/// clicks).
struct TitlebarRow: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout
    /// The preview's button comes and goes with its setting.
    @ObservedObject private var preview = PreviewSettings.shared
    /// While the conversation is put away for the page (`PreviewDrawer`),
    /// the preview's controls have the whole row.
    @ObservedObject private var drawer = PreviewDrawer.shared

    /// The bar's margin at each end (Things' toolbar: 12).
    static let edge: CGFloat = 12
    /// The column toggle with its gap before it and the bar's margin after
    /// (only while the page has the window: otherwise the inspector's
    /// handle, at the conversation's right edge, shows and hides it).
    static let toggleWidth: CGFloat = 32 + 4 + edge
    /// The preview's button, left of the column toggle (when it's turned on).
    static let previewToggleWidth: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = store.active, drawer.hidesConversation {
                RightColumnBar(workspace: workspace)
                    .padding(.leading, layout.leadingInset)
                    .frame(maxWidth: .infinity)
                PreviewToggle(workspace: workspace)
                ColumnToggle(workspace: workspace)
            } else if let workspace = store.active {
                // Each part of the bar is its column's color, so the bar
                // reads as the top of the page and of the inspector, not a
                // strip of its own (as Things' toolbar over its list).
                ConversationTabBar(workspace: workspace)
                    .padding(.leading, layout.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(ZStack { Color.claudeBackground; WindowDragArea() })
                let right = layout.terminalWidth > 0
                HStack(spacing: 0) {
                    if right {
                        Rectangle().fill(Color.claudeSeparator).frame(width: 0.5)
                        RightColumnBar(workspace: workspace)
                            .frame(width: max(0, layout.terminalWidth - 0.5 - Self.edge
                                                 - (preview.enabled ? Self.previewToggleWidth : 0)))
                    }
                    if preview.enabled { PreviewToggle(workspace: workspace) }
                    if right || preview.enabled { Color.clear.frame(width: Self.edge) }
                }
                .frame(maxHeight: .infinity)
                .background(ZStack { right ? Color.claudeChrome : Color.claudeBackground; WindowDragArea() })
            } else {
                Spacer()
            }
        }
        // The bar is the window buttons' band (centered on their line, as
        // Things' toolbar); the titlebar's extra height below it belongs to
        // the content.
        .frame(height: layout.buttonsMidY > 0 ? layout.buttonsMidY * 2 : nil)
        .background(ZStack { Color.claudeChrome; WindowDragArea() })  // the preview drawer's row
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WindowDragArea())
    }
}

/// Over the right column: the inspector's tabs, or the preview's controls
/// while the preview has the column.
private struct RightColumnBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if workspace.previewShowing {
            PreviewToolbar(workspace: workspace, session: PreviewStore.shared.session(for: workspace))
                .id(workspace.id)
        } else {
            InspectorTabBar(workspace: workspace)
        }
    }
}

/// Shows or hides the inspector and terminal (from the preview: swaps to them).
private struct ColumnToggle: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let shown = workspace.rightColumnVisible && !workspace.previewShowing
        BarIconButton(symbol: "sidebar.right",
                      tooltip: Tooltip(title: shown ? "Hide Inspector and Terminal" : "Show Inspector", shortcut: "⇧⌘D",
                                       detail: "Changes, usage, teed-up prompts and activity, beside the conversation."),
                      active: shown, glyphSize: Theme.Size.body, size: CGSize(width: 32, height: TabStyle.height)) {
            AppDelegate.shared.windowController?.toggleRightColumn(nil)
        }
        .padding(.leading, 4)
        .padding(.trailing, TitlebarRow.edge)
    }
}

/// Shows or hides the preview (experimental; only while it's turned on).
private struct PreviewToggle: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        BarIconButton(symbol: "safari",
                      tooltip: Tooltip(title: workspace.previewShowing ? "Hide Preview" : "Show Preview", shortcut: "⇧⌘B",
                                       detail: "The page you're building, beside the conversation."),
                      active: workspace.previewShowing, glyphSize: Theme.Size.body, size: CGSize(width: 32, height: TabStyle.height)) {
            AppDelegate.shared.windowController?.togglePreview(nil)
        }
        .padding(.leading, 4)
    }
}

// MARK: - Inspector tabs

/// The inspector's tabs, icon-only like Xcode's inspector selector; the
/// selected one is tinted while the inspector shows. Clicking a tab while
/// the inspector is hidden shows it.
private struct InspectorTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                InspectorTabButton(tab: tab,
                                   selected: workspace.inspectorVisible && workspace.inspectorTab == tab) {
                    if workspace.inspectorVisible && workspace.inspectorTab == tab {
                        workspace.hideInspector()
                    } else {
                        workspace.showInspector(tab)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, TitlebarRow.edge)
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                Image(systemName: tab.symbol)
                    .font(.toasty(tab.symbolSize, .medium))
                    .frame(width: 18)
                if selected {
                    Text(tab.title)
                        .font(.toasty(TabStyle.fontSize, .medium))
                }
            }
            .foregroundStyle(selected || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, selected ? Theme.Space.m : Theme.Space.s)
            .frame(minWidth: 32)
            .frame(height: TabStyle.height)
            .background(TabBackground(selected: selected, hovering: hovering))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(Tooltip(title: tab.title, shortcut: "⌃⌘\(tab.shortcut)", detail: tab.tooltipDetail))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
        .help(help)
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

    /// The + button's width plus its gap.
    private static var trailingRoom: CGFloat { 28 + TabStyle.gap }

    var body: some View {
        GeometryReader { geo in
            let room = max(0, geo.size.width - Self.trailingRoom)
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
                                        .gesture(reorder(item, at: i, widths: widths, xs: xs), including: move == nil ? .subviews : .all)
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

    var body: some View {
        FittingTabStrip(items: workspace.conversations, selectedID: workspace.selectedID,
                        minWidth: 90, maxWidth: 240,
                        naturalWidth: { c in
                            // Title, a fork's mark, a status mark, and room
                            // at the end for the close button.
                            // (12 each side; see ConversationTabItem).
                            TabStyle.titleWidth(c.title) + Theme.Space.m * 2 + 1
                                + (c.forkOrigin != nil ? 15 : 0)
                                + (TabStyle.hasStatus(c) ? 18 : 0)  // a gap, a dot or spinner (12)
                        },
                        pick: { if $0.id != workspace.selectedID { workspace.select($0) } },
                        move: { workspace.moveConversation($0, to: $1) }) { c in
            ConversationTabItem(conversation: c, selected: c.id == workspace.selectedID, workspace: workspace)
        } trailing: {
            NewTabButton(tooltip: Tooltip(title: "New Tab", shortcut: "⌘T",
                                          detail: "Another conversation in this workspace.")) { workspace.newConversation() }
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
        .help(conversation.title)
        .contextMenu {
            let index = workspace.conversations.firstIndex { $0.id == conversation.id } ?? 0
            Button("Rename…") { renaming = true }
            Divider()
            Button("Move Left") { workspace.moveConversation(conversation.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Right") { workspace.moveConversation(conversation.id, to: index + 1) }
                .disabled(index >= workspace.conversations.count - 1)
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

/// A conversation's status (see `StatusColor`): orange dot waiting for you,
/// spinner working, gray/red dot finished/stopped while you weren't
/// looking; nothing when idle.
struct ConversationStatusIcon: View {
    @ObservedObject var conversation: ClaudeConversation
    let selected: Bool

    var body: some View {
        if !conversation.requests.isEmpty {
            StatusDot(color: StatusColor.needsInput)
        } else if conversation.phase != .idle {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
        } else if conversation.attention {
            StatusDot(color: StatusColor.done(conversation))
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
        .help("\(session.displayTitle)\n\((session.directory as NSString).abbreviatingWithTildeInPath)")
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

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
