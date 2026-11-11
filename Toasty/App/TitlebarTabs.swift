import AppKit
import SwiftUI

/// Column widths of the split view, mirrored by the titlebar row so each
/// column's tabs sit over it.
final class WindowLayout: ObservableObject {
    /// Width of the right column (0 when hidden).
    @Published var terminalWidth: CGFloat = 0
    /// Room for the window buttons when the workspaces sidebar is hidden.
    @Published var leadingInset: CGFloat = 0
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

    static let toggleWidth: CGFloat = 40
    /// The preview's button, left of the column toggle (when it's turned on).
    static let previewToggleWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = store.active, drawer.hidesConversation {
                RightColumnBar(workspace: workspace)
                    .padding(.leading, layout.leadingInset)
                    .frame(maxWidth: .infinity)
                PreviewToggle(workspace: workspace)
                ColumnToggle(workspace: workspace)
            } else if let workspace = store.active {
                ConversationTabBar(workspace: workspace)
                    .padding(.leading, layout.leadingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if layout.terminalWidth > 0 {
                    Rectangle().fill(Color.claudeSeparator).frame(width: 0.5)
                    RightColumnBar(workspace: workspace)
                        .frame(width: max(0, layout.terminalWidth - 0.5 - Self.toggleWidth
                                             - (preview.enabled ? Self.previewToggleWidth : 0)))
                }
                if preview.enabled { PreviewToggle(workspace: workspace) }
                ColumnToggle(workspace: workspace)
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
        .background(ZStack { Color.claudeChrome; WindowDragArea() })
        .overlay(alignment: .bottom) { Rectangle().fill(Color.claudeSeparator).frame(height: 0.5) }
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
        Button { AppDelegate.shared.windowController?.toggleRightColumn(nil) } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14))
                .foregroundStyle(shown ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: TitlebarRow.toggleWidth)
        .help(shown ? "Hide Inspector and Terminal (⇧⌘D)" : "Show Inspector (⇧⌘D)")
        .accessibilityLabel(shown ? "Hide Inspector and Terminal" : "Show Inspector")
    }
}

/// Shows or hides the preview (experimental; only while it's turned on).
private struct PreviewToggle: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button { AppDelegate.shared.windowController?.togglePreview(nil) } label: {
            Image(systemName: "safari")
                .font(.system(size: 14))
                .foregroundStyle(workspace.previewShowing ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: TitlebarRow.previewToggleWidth)
        .help(workspace.previewShowing ? "Hide Preview (⇧⌘B)" : "Show Preview (⇧⌘B)")
        .accessibilityLabel(workspace.previewShowing ? "Hide Preview" : "Show Preview")
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
        .padding(.leading, 8)
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                if selected {
                    Text(tab.title)
                        .font(.system(size: TabStyle.fontSize, weight: .medium))
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, selected ? 10 : 8)
            .frame(height: TabStyle.height)
            .background(TabBackground(selected: selected, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(tab.title)  ⌃⌘\(tab.shortcut)")
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Tab style (shared by conversation and terminal tabs)

enum TabStyle {
    static let height: CGFloat = 28
    static let radius: CGFloat = 8
    static let gap: CGFloat = 6
    static let fontSize: CGFloat = 12
}

/// The selected tab is the page itself, raised out of the bar; others are
/// bare until hovered.
struct TabBackground: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TabStyle.radius, style: .continuous)
        if selected {
            shape.fill(Color.claudeBackground)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
    }
}

struct TabCloseButton: View {
    let visible: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .help(help)
        .accessibilityLabel("Close")
    }
}

struct NewTabButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Tab strip

/// A row of tabs that never grows past the room it's given: tabs share the
/// width evenly (up to `maxWidth`), shrink to `minWidth`, and past that the
/// row scrolls sideways, keeping the selected tab in view. `trailing` (the
/// + button) follows the last tab and always stays visible.
struct FittingTabStrip<Item: Identifiable, Tab: View, Trailing: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedID: Item.ID?
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @ViewBuilder let tab: (Item) -> Tab
    @ViewBuilder let trailing: () -> Trailing

    /// The + button's width plus its gap.
    private static var trailingRoom: CGFloat { 28 + TabStyle.gap }

    var body: some View {
        GeometryReader { geo in
            let room = max(0, geo.size.width - Self.trailingRoom)
            let n = CGFloat(max(items.count, 1))
            let width = min(maxWidth, max(minWidth, (room - TabStyle.gap * (n - 1)) / n))
            let content = width * n + TabStyle.gap * (n - 1)
            HStack(spacing: TabStyle.gap) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: TabStyle.gap) {
                            ForEach(items) { item in
                                tab(item).frame(width: width).id(item.id)
                            }
                        }
                        // Room for the selected tab's shadow.
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(content <= room)
                    .frame(width: min(content, room))
                    .onAppear { reveal(selectedID, proxy) }
                    .onChange(of: selectedID) { _, id in reveal(id, proxy) }
                    .onChange(of: items.count) { reveal(selectedID, proxy) }
                }
                trailing()
                Spacer(minLength: 0)
            }
            .frame(height: geo.size.height)
        }
    }

    private func reveal(_ id: Item.ID?, _ proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) } }
    }
}

// MARK: - Conversation tabs

private struct ConversationTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        FittingTabStrip(items: workspace.conversations, selectedID: workspace.selectedID,
                        minWidth: 110, maxWidth: 240) { c in
            ConversationTabItem(conversation: c, selected: c.id == workspace.selectedID, workspace: workspace)
        } trailing: {
            NewTabButton(help: "New Tab (⌘T)") { workspace.newConversation() }
        }
        .padding(.leading, 8)
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
        HStack(spacing: 6) {
            ConversationStatusIcon(conversation: conversation, selected: selected).frame(width: 12)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: TabStyle.fontSize, weight: .medium))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { renaming = false }
                    .onAppear { draft = conversation.title; DispatchQueue.main.async { fieldFocused = true } }
                    .onChange(of: fieldFocused) { _, focused in if !focused && renaming { commit() } }
            } else {
                Text(conversation.title)
                    .font(.system(size: TabStyle.fontSize, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 22)
        }
        .padding(.leading, 10)
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
            Button("Rename…") { renaming = true }
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
/// spinner working, blue/red dot finished/stopped while you weren't looking.
/// Otherwise a gray sparkle, or a branch for a fork (its title,
/// "… (fork)", is usually cut off).
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
        } else {
            Image(systemName: conversation.forkOrigin != nil ? "arrow.triangle.branch" : "sparkle")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(selected ? Color.secondary : Color.secondary.opacity(0.6))
        }
    }
}

// MARK: - Terminal tabs

struct TerminalTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        FittingTabStrip(items: workspace.terminals, selectedID: workspace.selectedTerminalID,
                        minWidth: 90, maxWidth: 180) { t in
            TerminalTabItem(session: t, selected: t.id == workspace.selectedTerminalID, workspace: workspace)
        } trailing: {
            NewTabButton(help: "New Terminal") {
                workspace.newTerminal()
                AppDelegate.shared.windowController?.focusTerminal()
            }
        }
        .padding(.leading, 8)
    }
}

private struct TerminalTabItem: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(session.displayTitle)
                .font(.system(size: TabStyle.fontSize, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 22)
        }
        .padding(.leading, 10)
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
        .help(session.directory)
        .contextMenu {
            Button("Close Terminal") { workspace.requestCloseTerminal(session.id) }
            Button("Close Other Terminals") {
                workspace.terminals.filter { $0.id != session.id }.forEach { workspace.requestCloseTerminal($0.id) }
            }
            .disabled(workspace.terminals.count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("Terminal: \(session.displayTitle)")
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
