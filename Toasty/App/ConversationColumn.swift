import AppKit
import Combine
import SwiftUI

/// The middle column: the active workspace's selected conversation.
struct ConversationColumn: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout

    var body: some View {
        ZStack {
            Color.claudeBackground.ignoresSafeArea()
            if let workspace = store.active {
                WorkspaceConversation(workspace: workspace, layout: layout)
            } else {
                WelcomeView(store: store)
            }
        }
    }
}

private struct WorkspaceConversation: View {
    @ObservedObject var workspace: Workspace
    let layout: WindowLayout

    var body: some View {
        if let page = workspace.shownBrowserTabID, PreviewSettings.shared.enabled {
            // The tab row's band, from the window's top; the page starts
            // right under its divider.
            let bar = layout.buttonsMidY > 0 ? layout.buttonsMidY * 2 : 38
            BrowserTabPage(workspace: workspace, session: PreviewStore.shared.page(page, in: workspace), barHeight: bar)
                .id(page)
                .padding(.top, bar)
                .ignoresSafeArea(edges: .top)
        } else if let file = workspace.diffFile {
            DiffPage(file: file, files: workspace.changes.files, select: { workspace.diffFile = $0 }) { workspace.diffFile = nil }
                .id(file.id)
        } else if let url = workspace.viewedFile {
            FilePage(workspace: workspace, changes: workspace.changes, url: url) { workspace.viewedFile = nil }
                .id(url)
        } else if let terminal = workspace.shownTabTerminal {
            TerminalTabPage(session: terminal)
        } else if workspace.selected != nil {
            // Shown by `ConversationColumnController`, above this view.
            Color.clear
        } else {
            EmptyState(symbol: "sparkle", title: workspace.name,
                       button: "New Tab", shortcut: "⌘T") { workspace.newConversation() }
        }
    }
}

/// A terminal tab: the shell fills the column, on the terminal's own
/// background from the tab row's divider to the window's edges.
private struct TerminalTabPage: View {
    let session: TerminalSession
    @ObservedObject private var settings = TerminalLayoutSettings.shared

    var body: some View {
        ZStack {
            Color.claudeBackground.ignoresSafeArea()
            // Exactly the conversation's width and edges (its transcript
            // and composer), centered in the column the same way.
            TerminalHost(session: session)
                .terminalColumn(settings.tabWidth)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, 16)
        }
    }
}

private struct EmptyState: View {
    let symbol: String
    let title: String
    let button: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Glyph.hero, .light))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(title)
                .font(.toasty(Theme.Size.display, .semibold))
            Button(button, action: action)
                .controlSize(.large)
            Text(shortcut).font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Kept views

/// The middle column. Conversations are shown in AppKit, above the
/// SwiftUI column (which has the empty states and diffs), from views kept
/// in `ConversationViews`: switching workspaces or tabs swaps an already
/// laid out view in instead of building the whole transcript again. Being
/// outside the column's SwiftUI view also keeps SwiftUI from walking every
/// kept transcript when anything in the column changes.
final class ConversationColumnController: NSViewController {
    let store: WorkspaceStore
    private let host = ConversationHostView()
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceCancellable: AnyCancellable?
    private var drawerCancellable: AnyCancellable?
    private var container: ColumnContainerView!
    /// The window's column (for the terminal drawer's commands).
    static weak var current: ConversationColumnController?

    let layout: WindowLayout

    init(store: WorkspaceStore, layout: WindowLayout) {
        self.store = store
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSHostingView(rootView: ConversationColumn(store: store, layout: layout))
        column.sizingOptions = []
        let drawer = NSHostingView(rootView: TerminalDrawerView(store: store, window: layout))
        drawer.sizingOptions = []
        container = ColumnContainerView(drawer: drawer)
        view = container
        Self.current = self
        for v in [column, host] as [NSView] {
            v.frame = container.top.bounds
            v.autoresizingMask = [.width, .height]
            container.top.addSubview(v)
        }
        // Published values arrive before they're set: use the new ones.
        store.$activeID
            .sink { [weak self] id in self?.follow(self?.store.workspaces.first { $0.id == id }) }
            .store(in: &cancellables)
    }

    private func follow(_ w: Workspace?) {
        // Another workspace: its drawer as it was, without sliding.
        container.setOpen(w?.drawerOpen ?? false, animated: false)
        drawerCancellable = w?.$drawerOpen.dropFirst().removeDuplicates()
            .sink { [weak self] open in self?.drawerChanged(open) }
        guard let w else {
            workspaceCancellable = nil
            host.show(nil)
            return
        }
        let page = w.$diffFile.combineLatest(w.$viewedFile).map { $0 != nil || $1 != nil }
        let other = w.$shownTabTerminalID.combineLatest(w.$shownBrowserTabID).map { $0 != nil || $1 != nil }
        workspaceCancellable = w.$selectedID.combineLatest(w.$conversations, page, other)
            .sink { [weak self] id, conversations, page, other in
                let c = !page && !other ? conversations.first { $0.id == id } : nil
                self?.host.show(c.map { ConversationViews.shared.view(for: $0) })
            }
    }
}

extension ConversationColumnController {
    var columnHeight: CGFloat { view.bounds.height }

    private func drawerChanged(_ open: Bool) {
        let window = view.window
        // Closing with the focus in it: give it back to the conversation.
        if !open, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: container.drawer) {
            window?.makeFirstResponder(nil)
        }
        container.setOpen(open, animated: true) {
            if open { AppDelegate.shared.windowController?.focusDrawerTerminal() }
        }
    }
}

/// Holds the kept conversation views; all but the shown one hidden (moving
/// a big SwiftUI view in and out of the window is slow, hiding it isn't).
private final class ConversationHostView: NSView {
    private weak var shown: NSView?

    // Clicks pass through to the SwiftUI column when no conversation shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        shown == nil ? nil : super.hitTest(point)
    }

    func show(_ v: NSView?) {
        // Views the cache let go of.
        for sub in subviews where !ConversationViews.shared.keeps(sub) { sub.removeFromSuperview() }
        guard v !== shown else { return }
        // Hiding the view with the focus makes AppKit search the whole
        // window for another key view; let go of it first instead.
        if let old = shown, let window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: old) {
            window.makeFirstResponder(nil)
        }
        // Only the shown view follows the column's size (resizing the
        // window lays out one transcript, not every kept one).
        shown?.isHidden = true
        shown?.autoresizingMask = []
        shown = v
        guard let v else { return }
        if v.superview !== self {
            v.isHidden = true
            addSubview(v)
        }
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        v.isHidden = false
        // Focus the composer, as when the view was first built (directly:
        // a change to the conversation would redraw its whole view).
        DispatchQueue.main.async { [weak self, weak v] in
            guard let self, let v, self.shown === v, let window = self.window,
                  let composer = Self.composer(in: v) else { return }
            window.makeFirstResponder(composer)
        }
    }

    private static func composer(in view: NSView) -> ComposerTextView? {
        if let c = view as? ComposerTextView { return c }
        for sub in view.subviews where !sub.isHidden {
            if let c = composer(in: sub) { return c }
        }
        return nil
    }
}

/// The views of recently shown conversations, most recent last. Hidden
/// views cost little: they draw only when shown.
@MainActor
final class ConversationViews {
    static let shared = ConversationViews()
    static let limit = 8

    final class Hosting: NSHostingView<ClaudeConversationView> {
        weak var conversation: ClaudeConversation?

        /// ⌘V while something in the conversation that isn't a text field
        /// has focus (text selected in a reply or a tool's output, say)
        /// pastes into its composer: a picture or file is attached, text
        /// goes in at the composer's cursor. Fields keep their own paste,
        /// and the terminal is outside this view.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "v",
               let window, let focus = window.firstResponder as? NSView, focus.isDescendant(of: self),
               !Self.isEditable(focus),
               let id = conversation?.id, let composer = ComposerTextView.find(id, in: self) {
                if let reply = focus as? ClaudeOutputTextView {
                    reply.paste(nil)   // also puts its Quote pill away
                } else {
                    window.makeFirstResponder(composer)
                    composer.paste(nil)
                }
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        private static func isEditable(_ view: NSView) -> Bool {
            if let text = view as? NSTextView { return text.isEditable }
            if let field = view as? NSTextField { return field.isEditable }
            return false
        }

        /// The top safe area ends at the tab row's divider. The row is only
        /// the window buttons' band (`TitlebarRow`); the titlebar's extra
        /// height under it belongs to the conversation, so the transcript
        /// scrolls (and fades) right up to the divider.
        override var safeAreaInsets: NSEdgeInsets {
            var insets = super.safeAreaInsets
            // (In full screen the buttons live in another window: leave it be.)
            guard let window, let button = window.standardWindowButton(.closeButton), button.window === window
            else { return insets }
            let height = window.frame.height
            let barBottom = 2 * (height - button.convert(button.bounds, to: nil).midY)
            let top = height - convert(bounds, to: nil).maxY
            insets.top = min(insets.top, max(0, barBottom - top))
            return insets
        }
    }

    private var views: [(id: UUID, view: Hosting)] = []

    func keeps(_ view: NSView) -> Bool { views.contains { $0.view === view } }

    func view(for conversation: ClaudeConversation) -> Hosting {
        purge()
        if let i = views.firstIndex(where: { $0.id == conversation.id }) {
            let entry = views.remove(at: i)
            views.append(entry)
            return entry.view
        }
        let view = Hosting(rootView: ClaudeConversationView(
            conversation: conversation,
            onRunInTerminal: { [weak conversation] in conversation?.workspace?.runInTerminal($0) }))
        view.sizingOptions = []
        view.conversation = conversation
        views.append((conversation.id, view))
        if views.count > Self.limit { views.removeFirst(views.count - Self.limit) }
        return view
    }

    /// Drop closed conversations' views.
    private func purge() {
        let open = Set(WorkspaceStore.shared.workspaces.flatMap { $0.conversations.map(\.id) })
        views.removeAll { !open.contains($0.id) }
    }
}
