import AppKit
import SwiftUI

/// Column widths of the split view, mirrored by the titlebar row so each
/// column's tabs sit over it.
final class WindowLayout: ObservableObject {
    /// Width of the terminal column (0 when hidden).
    @Published var terminalWidth: CGFloat = 0
    /// Room for the window buttons when the workspaces sidebar is hidden.
    @Published var leadingInset: CGFloat = 0
}

/// The titlebar row right of the workspaces sidebar: the conversation tabs
/// over the conversation, the terminal tabs over the terminal, and the
/// terminal toggle in the window's top-right corner. Hosted in the window's
/// titlebar view (views under a transparent titlebar don't get clicks).
struct TitlebarRow: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout

    static let toggleWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            if let workspace = store.active {
                ConversationTabBar(workspace: workspace)
                    .padding(.leading, layout.leadingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if layout.terminalWidth > 0 {
                    Rectangle().fill(Color.claudeSeparator).frame(width: 0.5)
                    TerminalTabBar(workspace: workspace)
                        .frame(width: max(0, layout.terminalWidth - 0.5 - Self.toggleWidth))
                }
                TerminalToggle(workspace: workspace)
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
        .background(ZStack { Color.claudeChrome; WindowDragArea() })
        .overlay(alignment: .bottom) { Rectangle().fill(Color.claudeSeparator).frame(height: 0.5) }
    }
}

private struct TerminalToggle: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Button { AppDelegate.shared.windowController?.toggleTerminal(nil) } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14))
                .foregroundStyle(workspace.terminalVisible ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: TitlebarRow.toggleWidth)
        .help(workspace.terminalVisible ? "Hide Terminal (⌃⌘T)" : "Show Terminal (⌃⌘T)")
        .accessibilityLabel(workspace.terminalVisible ? "Hide Terminal" : "Show Terminal")
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
private struct TabBackground: View {
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

private struct TabCloseButton: View {
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

private struct NewTabButton: View {
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

// MARK: - Conversation tabs

private struct ConversationTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: TabStyle.gap) {
            ForEach(Array(workspace.conversations.enumerated()), id: \.element.id) { i, c in
                ConversationTabItem(conversation: c, index: i,
                                    selected: c.id == workspace.selectedID,
                                    workspace: workspace)
                    .frame(minWidth: 110, maxWidth: 240)
            }
            NewTabButton(help: "New Tab (⌘T)") { workspace.newConversation() }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
    }
}

private struct ConversationTabItem: View {
    @ObservedObject var conversation: ClaudeConversation
    let index: Int
    let selected: Bool
    let workspace: Workspace
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            status.frame(width: 12)
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
        .help(index < 9 ? "\(conversation.title)  ⌘\(index + 1)" : conversation.title)
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

    /// Orange dot: waiting for you. Spinner: working. Accent dot: finished
    /// while you weren't looking. Otherwise Claude's sparkle.
    @ViewBuilder private var status: some View {
        if !conversation.requests.isEmpty {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if conversation.phase != .idle {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
        } else if conversation.attention {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(selected ? Color(nsColor: .systemOrange) : Color.secondary.opacity(0.6))
        }
    }

    private func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.customTitle = t.isEmpty ? nil : t
        renaming = false
        workspace.renamed()
    }
}

// MARK: - Terminal tabs

private struct TerminalTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: TabStyle.gap) {
            ForEach(workspace.terminals) { t in
                TerminalTabItem(session: t, selected: t.id == workspace.selectedTerminalID, workspace: workspace)
                    .frame(minWidth: 90, maxWidth: 180)
            }
            NewTabButton(help: "New Terminal") {
                workspace.newTerminal()
                AppDelegate.shared.windowController?.focusTerminal()
            }
            Spacer(minLength: 0)
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
