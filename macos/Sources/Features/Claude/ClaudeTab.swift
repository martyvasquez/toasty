import AppKit
import SwiftUI

/// mostty: A workspace window: Claude conversations as tabs along the top,
/// the selected conversation, and the workspace's terminals in a panel on
/// the right (Ghostty's own terminal view, one terminal tab at a time).
struct ClaudeWorkspaceContainer<Terminal: View>: View {
    @ObservedObject var controller: TerminalController
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        if let workspace = controller.workspace {
            ClaudeWorkspaceView(workspace: workspace, terminal: terminal)
        } else {
            terminal()
        }
    }
}

private struct ClaudeWorkspaceView<Terminal: View>: View {
    @ObservedObject var workspace: ClaudeWorkspace
    @ObservedObject var manager: WorkspaceManager = .shared
    @ViewBuilder let terminal: () -> Terminal
    @State private var dragStart: CGFloat?

    static var minTerminal: CGFloat { 280 }
    static var minConversation: CGFloat { 440 }

    var body: some View {
        GeometryReader { outer in
            // The window's content runs under its transparent titlebar. Each
            // column reserves the titlebar row for its own strip of tabs,
            // which is drawn in the titlebar itself (ClaudeTitlebarRow).
            let barHeight = outer.safeAreaInsets.top > 1 ? outer.safeAreaInsets.top : 38
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.claudeChrome.frame(height: barHeight)
                    Group {
                        if let conversation = workspace.selected {
                            ClaudeConversationView(
                                conversation: conversation,
                                terminalVisible: workspace.terminalVisible,
                                onRunInTerminal: { [weak workspace] in workspace?.runInTerminal($0) },
                                onToggleTerminal: { [weak workspace] in workspace?.toggleTerminal() })
                                .id(conversation.id)
                        } else {
                            ClaudeNoConversations(workspace: workspace)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // The terminal sidebar: a full-height column of its own.
                if workspace.terminalVisible {
                    VStack(spacing: 0) {
                        Color.claudeChrome.frame(height: barHeight)
                        terminal()
                    }
                    .frame(width: workspace.panelWidth)
                    .overlay(alignment: .leading) { divider(total: outer.size.width) }
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: workspace.terminalVisible)
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { workspace.panelWidth = clampedWidth(outer.size.width) }
            .onChange(of: outer.size.width) { w in workspace.panelWidth = clampedWidth(w) }
            .onChange(of: workspace.terminalWidth) { _ in workspace.panelWidth = clampedWidth(outer.size.width) }
        }
        .background(Color.claudeBackground)
    }

    private func clampedWidth(_ total: CGFloat) -> CGFloat {
        let maxWidth = max(Self.minTerminal, total - Self.minConversation)
        return min(maxWidth, max(Self.minTerminal, workspace.terminalWidth))
    }

    /// A hairline with a wider invisible grab area, like NSSplitView's thin divider.
    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.claudeSeparator)
            .frame(width: 0.5)
            .frame(width: 9)
            .offset(x: -4.5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? clampedWidth(total)
                        if dragStart == nil { dragStart = start }
                        let maxWidth = max(Self.minTerminal, total - Self.minConversation)
                        workspace.terminalWidth = min(maxWidth, max(Self.minTerminal, start - value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil })
    }
}

// MARK: - Conversation tabs

/// Safari-style compact tabs in the titlebar: one per Claude conversation.
/// Hosted in the window's titlebar view (see installTabBar).
struct ClaudeTabBarHost: View {
    @ObservedObject var manager: WorkspaceManager = .shared
    @ObservedObject var workspace: ClaudeWorkspace

    var body: some View {
        // Mirrors the columns below: the conversation's tabs over the
        // conversation, the terminals' tabs over the terminal sidebar, and
        // the sidebar toggle in the window's top-right corner.
        HStack(spacing: 0) {
            ClaudeTabBar(workspace: workspace, leadingInset: manager.sidebarVisible ? 0 : 76)
            if workspace.terminalVisible {
                Rectangle().fill(Color.claudeSeparator).frame(width: 0.5)
                ClaudeTerminalStrip(workspace: workspace)
                    .frame(width: max(0, workspace.panelWidth - 0.5 - 40))
            }
            Button { workspace.toggleTerminal() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundStyle(workspace.terminalVisible ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .help(workspace.terminalVisible ? "Hide Terminal (⌃⌘T)" : "Show Terminal (⌃⌘T)")
        }
        .background(ZStack { Color.claudeChrome; WindowDragArea() })
        .overlay(alignment: .bottom) { Rectangle().fill(Color.claudeSeparator).frame(height: 0.5) }
        .animation(.easeInOut(duration: 0.22), value: workspace.terminalVisible)
    }
}

private struct ClaudeTabBar: View {
    @ObservedObject var workspace: ClaudeWorkspace
    var leadingInset: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(workspace.conversations.enumerated()), id: \.element.id) { i, c in
                ClaudeTabItem(conversation: c, index: i,
                              selected: c.id == workspace.selected?.id,
                              workspace: workspace)
                    .frame(minWidth: 110, maxWidth: 240)
            }
            Button { workspace.newConversation() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Claude Tab (⌘T)")
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + leadingInset)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
    }
}

private struct ClaudeTabItem: View {
    @ObservedObject var conversation: ClaudeConversation
    let index: Int
    let selected: Bool
    let workspace: ClaudeWorkspace
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Button { if !renaming { workspace.select(conversation) } } label: {
            HStack(spacing: 6) {
                status.frame(width: 12)
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { renaming = false }
                        .onAppear { draft = conversation.title; DispatchQueue.main.async { fieldFocused = true } }
                        .onChange(of: fieldFocused) { focused in if !focused && renaming { commit() } }
                } else {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 22)
            }
            .padding(.leading, 10)
            .frame(height: 28)
            .background {
                // The selected tab is the page itself, raised out of the bar.
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.claudeBackground)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button { workspace.close(conversation) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .opacity(hovering ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .onHover { hovering = $0 }
        .help(index < 9 ? "\(conversation.title)  ⌘\(index + 1)" : conversation.title)
        .contextMenu {
            Button("Rename…") { renaming = true }
            Button("Close Tab") { workspace.close(conversation) }
            Button("Close Other Tabs") {
                workspace.conversations.filter { $0.id != conversation.id }.forEach { workspace.close($0) }
            }
            .disabled(workspace.conversations.count < 2)
        }
    }

    @ViewBuilder private var status: some View {
        if !conversation.requests.isEmpty {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if conversation.phase != .idle {
            ProgressView().controlSize(.mini).scaleEffect(0.65)
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
        conversation.workspace?.controller?.window?.invalidateRestorableState()
        conversation.focusComposer()
    }
}

/// The workspace has no conversation open.
private struct ClaudeNoConversations: View {
    let workspace: ClaudeWorkspace

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text((workspace.cwd as NSString).lastPathComponent)
                .font(.system(size: 22, weight: .semibold))
            Button("New Claude Tab") { workspace.newConversation() }
                .controlSize(.large)
            Text("⌘T").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Terminal panel

/// The terminal sidebar's tabs, in the titlebar row above it (each terminal
/// can still be split with Ghostty's usual shortcuts).
private struct ClaudeTerminalStrip: View {
    @ObservedObject var workspace: ClaudeWorkspace

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.terminals) { tab in
                        ClaudeTerminalTabItem(
                            workspace: workspace,
                            tab: tab,
                            selected: tab.id == workspace.selectedTerminalID)
                    }
                }
            }
            Button { workspace.newTerminal() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal")
        }
        .padding(.leading, 8)
        .frame(maxHeight: .infinity)
    }
}

private struct ClaudeTerminalTabItem: View {
    @ObservedObject var workspace: ClaudeWorkspace
    let tab: ClaudeWorkspace.TerminalTab
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let surface = workspace.tree(of: tab).first
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TerminalTitle(surface: surface)
                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
            Button { workspace.closeTerminal(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Close Terminal")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .frame(maxWidth: 180)
        .background {
            // Same as a selected Claude tab: one tab style across the app.
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.claudeBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { workspace.selectTerminal(tab.id) })
    }

    /// The shell's title (e.g. the running command), live.
    private struct TerminalTitle: View {
        let surface: Ghostty.SurfaceView?
        var body: some View {
            if let surface { Live(surface: surface) } else { Text("Terminal") }
        }
        private struct Live: View {
            @ObservedObject var surface: Ghostty.SurfaceView
            var body: some View {
                let pwd = surface.pwd.map { ($0 as NSString).lastPathComponent }
                Text(surface.title.isEmpty || surface.title.contains("@") ? (pwd ?? "Terminal") : surface.title)
            }
        }
    }
}

/// Lets the window be dragged (and zoomed with a double-click) from empty
/// parts of the tab bar, like a real titlebar.
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

// MARK: - TerminalController

extension TerminalController {
    /// The conversation shown in this workspace window.
    var claude: ClaudeConversation? { workspace?.selected }

    /// Make this window a workspace (conversations + terminal panel).
    func enableWorkspace(_ workspace: ClaudeWorkspace) {
        self.workspace = workspace
        workspace.attach(to: self)
        window?.tabbingMode = .disallowed
        installTabBar(workspace)
        mosttyRefreshTitle()
        window?.invalidateRestorableState()
    }

    /// Put the conversation tabs in the titlebar, right of the workspace
    /// sidebar (which runs under the window buttons). Views in the titlebar
    /// get clicks; content under a transparent titlebar doesn't.
    private func installTabBar(_ workspace: ClaudeWorkspace) {
        guard let window else { return }
        // An empty compact toolbar gives the titlebar the standard height of
        // a Mac app with tabs in its toolbar (Safari, Xcode).
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "mosttyWorkspace")
            window.toolbarStyle = .unifiedCompact
        }
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        titlebar.subviews.filter { $0.identifier?.rawValue == "mosttyTabBar" }.forEach { $0.removeFromSuperview() }
        let host = NSHostingView(rootView: ClaudeTabBarHost(workspace: workspace))
        host.identifier = NSUserInterfaceItemIdentifier("mosttyTabBar")
        host.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(host)
        let leading = host.leadingAnchor.constraint(
            equalTo: titlebar.leadingAnchor,
            constant: WorkspaceManager.shared.sidebarVisible ? WorkspaceManager.sidebarWidth + 1 : 0)
        NSLayoutConstraint.activate([
            leading,
            host.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            host.topAnchor.constraint(equalTo: titlebar.topAnchor),
            host.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),
        ])
        tabBarSidebarObservation = WorkspaceManager.shared.$sidebarVisible
            .receive(on: DispatchQueue.main)
            .sink { visible in
                leading.constant = visible ? WorkspaceManager.sidebarWidth + 1 : 0
            }
    }

    /// The window's title (Mission Control, Window menu): the workspace.
    var claudeTitle: String? {
        guard workspace != nil else { return nil }
        let name = WorkspaceManager.shared.name(for: workspaceID)
        if let c = workspace?.selected { return "\(name) — \(c.title)" }
        return name
    }
}

// MARK: - WorkspaceManager

extension WorkspaceManager {
    /// New Claude tab in the active workspace (⌘T, ⌘⇧T).
    func newNativeClaudeTab(cwd: String? = nil, resume sessionID: String? = nil) {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController)
            ?? activeTerminalWindow.flatMap { $0.windowController as? TerminalController }
        guard let workspace = controller?.workspace else {
            create(name: nil)
            return
        }
        workspace.newConversation(cwd: cwd, resume: sessionID)
    }

    fileprivate var activeTerminalWindow: NSWindow? {
        guard let id = items.first(where: \.isActive)?.id,
              let w = TerminalController.all.first(where: { $0.workspaceID == id })?.window else { return nil }
        return w.tabGroup?.selectedWindow ?? w
    }

    /// The workspace the user is looking at, if any.
    var activeWorkspace: ClaudeWorkspace? {
        let c = (NSApp.keyWindow?.windowController as? TerminalController)
            ?? (activeTerminalWindow?.windowController as? TerminalController)
        return c?.workspace
    }

    /// Show a conversation: its workspace, its tab.
    func show(_ conversation: ClaudeConversation) {
        guard let workspace = conversation.workspace, let controller = workspace.controller else { return }
        activate(controller.workspaceID)
        workspace.select(conversation)
    }
}
