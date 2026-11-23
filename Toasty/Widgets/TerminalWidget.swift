import AppKit
import Combine
import SwiftUI

// MARK: - Terminal widget (an experiment)
//
// A shell on the grid, Large only. Everything it needs is here; the rest of
// the app knows it by `WidgetKind.terminal` alone (the gallery, its size
// limits, `WidgetContent`). To remove it: take `.terminal` out of
// `WidgetKind.gallery` (saved spaces then drop it on load, as kinds the
// gallery doesn't offer), its case in `WidgetContent`, and this file.

/// The widget: its tabs over the selected shell in its own well, as the
/// column's terminal. Each tab is a shell in the workspace's folder; there
/// is always one (closing the last starts a fresh one). In the gallery, a
/// still picture of one.
struct TerminalWidget: View {
    @ObservedObject var workspace: Workspace
    let item: WidgetItem
    @Environment(\.widgetPreview) private var preview

    var body: some View {
        if preview {
            VStack(spacing: 0) {
                WidgetHeader(kind: .terminal)
                well { TerminalWidgetPlaceholder() }
            }
        } else {
            TerminalWidgetBody(tabs: TerminalWidgetSessions.shared.tabs(for: item.id, in: workspace))
        }
    }
}

/// The terminal's well: its own background, rounded, inset in the card.
private func well<Inside: View>(@ViewBuilder _ inside: () -> Inside) -> some View {
    ZStack {
        TerminalBackdrop()
        inside()
    }
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .padding([.horizontal, .bottom], Theme.Widget.rowInset)
}

private struct TerminalWidgetBody: View {
    @ObservedObject var tabs: TerminalWidgetTabs

    var body: some View {
        VStack(spacing: 0) {
            // The widgets' header, + where the others show their status.
            WidgetHeader(kind: .terminal) {
                NewTabButton(tooltip: Tooltip(title: "New Terminal", detail: "Another shell in this widget, in this workspace's folder.")) {
                    tabs.add()
                }
                .padding(.trailing, -Theme.Space.xs)
            }
            // Its tabs, once there's more than one shell.
            if tabs.sessions.count > 1 {
                TerminalWidgetTabBar(tabs: tabs)
                    .frame(height: TabStyle.height)
                    .padding(.horizontal, Theme.Widget.rowInset)
                    .padding(.bottom, Theme.Space.xs)
            }
            well {
                if let session = tabs.selected {
                    TerminalHost(session: session)
                        .id(session.id)
                        .padding(.vertical, Theme.Space.xs)
                }
            }
        }
    }
}

private struct TerminalWidgetTabBar: View {
    @ObservedObject var tabs: TerminalWidgetTabs

    var body: some View {
        FittingTabStrip(items: tabs.sessions, selectedID: tabs.selectedID,
                        minWidth: 72, maxWidth: 160,
                        naturalWidth: { t in TabStyle.titleWidth(t.displayTitle) + Theme.Space.m * 2 + 1 },
                        pick: { tabs.select($0.id) },
                        move: { tabs.move($0, to: $1) },
                        trailingWidth: 0) { t in
            TerminalWidgetTab(session: t, selected: t.id == tabs.selectedID, tabs: tabs)
        } trailing: {
            EmptyView()
        }
    }
}

private struct TerminalWidgetTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let tabs: TerminalWidgetTabs
    @State private var hovering = false

    var body: some View {
        Text(session.displayTitle)
            .font(.toasty(TabStyle.fontSize, selected ? .medium : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.Space.m)
            .padding(.trailing, hovering ? TabStyle.closeRoom : Theme.Space.m)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .frame(height: TabStyle.height)
            .background(TabBackground(selected: selected, hovering: hovering))
            .contentShape(Rectangle())
            .onTapGesture { tabs.select(session.id, focus: true) }
            .overlay(alignment: .trailing) {
                TabCloseButton(visible: hovering, help: "Close Terminal") { tabs.close(session.id) }
            }
            .onHover { hovering = $0 }
            .tooltipText("\(session.displayTitle)\n\((session.directory as NSString).abbreviatingWithTildeInPath)")
            .contextMenu {
                Button("Close Terminal") { tabs.close(session.id) }
                Button("Close Other Terminals") {
                    tabs.sessions.filter { $0.id != session.id }.forEach { tabs.close($0.id) }
                }
                .disabled(tabs.sessions.count < 2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("Terminal: \(session.displayTitle)")
    }
}

/// The gallery's picture: a prompt, no shell.
private struct TerminalWidgetPlaceholder: View {
    var body: some View {
        Text("~ % ")
            .font(.system(size: Theme.Size.meta, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Theme.Space.s)
    }
}

/// One widget's shells, in one workspace: its tabs and the selected one.
/// Never empty: closing the last tab (or its shell exiting) starts a fresh
/// shell in its place.
@MainActor
final class TerminalWidgetTabs: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var selectedID: UUID?
    private let folder: String

    init(folder: String) {
        self.folder = folder
        add(focus: false)
    }

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    /// A new shell, after the selected tab, selected and focused.
    func add(focus: Bool = true) {
        let s = TerminalSession(cwd: folder)
        s.onExit = { [weak self, weak s] in
            guard let self, let s else { return }
            self.close(s.id)
        }
        var list = sessions
        if let i = list.firstIndex(where: { $0.id == selectedID }) { list.insert(s, at: i + 1) } else { list.append(s) }
        sessions = list
        select(s.id, focus: focus)
    }

    func select(_ id: UUID, focus: Bool = false) {
        if selectedID != id { selectedID = id }
        if focus, let s = selected { Self.focus(s) }
    }

    /// Its shell ends; the tab beside it is selected. The last one is
    /// replaced by a fresh shell.
    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[i]
        s.onExit = nil
        s.terminate()
        var list = sessions
        list.remove(at: i)
        sessions = list
        if list.isEmpty { add(focus: selectedID == id); return }
        if selectedID == id { select(list[min(i, list.count - 1)].id) }
    }

    func move(_ id: UUID, to index: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        var list = sessions
        let s = list.remove(at: from)
        list.insert(s, at: min(max(index, 0), list.count))
        if list.map(\.id) != sessions.map(\.id) { sessions = list }
    }

    /// Every shell ends (the widget was removed, or its workspace closed).
    func terminateAll() {
        for s in sessions {
            s.onExit = nil
            s.terminate()
        }
        sessions = []
    }

    /// Focus the shell once its view is in the window (its host makes it a
    /// moment after it's selected).
    private static func focus(_ s: TerminalSession, tries: Int = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            if let v = s.terminalView, let window = v.window {
                window.makeFirstResponder(v)
            } else if tries > 0 {
                focus(s, tries: tries - 1)
            }
        }
    }
}

/// Every terminal widget's tabs, by workspace and widget. A removed
/// widget's (or a closed workspace's) shells end.
@MainActor
final class TerminalWidgetSessions {
    static let shared = TerminalWidgetSessions()

    private struct Key: Hashable {
        let workspace: UUID
        let widget: UUID
    }

    private var all: [Key: TerminalWidgetTabs] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let store = WorkspaceStore.shared
        store.$spaces
            .combineLatest(store.$workspaces)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces, workspaces in self?.prune(spaces: spaces, workspaces: workspaces) }
            .store(in: &cancellables)
    }

    func tabs(for widget: UUID, in workspace: Workspace) -> TerminalWidgetTabs {
        let key = Key(workspace: workspace.id, widget: widget)
        if let t = all[key] { return t }
        let t = TerminalWidgetTabs(folder: workspace.folder)
        all[key] = t
        return t
    }

    private func prune(spaces: [WidgetSpace], workspaces: [Workspace]) {
        let widgets = Set(spaces.flatMap(\.widgets).filter { $0.kind == .terminal }.map(\.id))
        let open = Set(workspaces.map(\.id))
        for (key, t) in all where !widgets.contains(key.widget) || !open.contains(key.workspace) {
            all[key] = nil
            t.terminateAll()
        }
    }
}
