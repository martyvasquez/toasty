import AppKit
import Combine
import SwiftUI

/// The middle column: the active workspace's selected conversation.
struct ConversationColumn: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            Color.claudeBackground.ignoresSafeArea()
            if let workspace = store.active {
                WorkspaceConversation(workspace: workspace)
            } else {
                EmptyState(symbol: "folder", title: "No Workspace",
                           button: "New Workspace…", shortcut: "⌘N") { store.createWithFolderPicker() }
            }
        }
    }
}

private struct WorkspaceConversation: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let file = workspace.diffFile {
            DiffPage(file: file) { workspace.diffFile = nil }
                .id(file.id)
        } else if workspace.selected != nil {
            // Shown by `ConversationColumnController`, above this view.
            Color.clear
        } else {
            EmptyState(symbol: "sparkle", title: workspace.name,
                       button: "New Tab", shortcut: "⌘T") { workspace.newConversation() }
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
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(title)
                .font(.system(size: 22, weight: .semibold))
            Button(button, action: action)
                .controlSize(.large)
            Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary)
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

    init(store: WorkspaceStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSHostingView(rootView: ConversationColumn(store: store))
        column.sizingOptions = []
        view = NSView()
        for v in [column, host] as [NSView] {
            v.frame = view.bounds
            v.autoresizingMask = [.width, .height]
            view.addSubview(v)
        }
        // Published values arrive before they're set: use the new ones.
        store.$activeID
            .sink { [weak self] id in self?.follow(self?.store.workspaces.first { $0.id == id }) }
            .store(in: &cancellables)
    }

    private func follow(_ w: Workspace?) {
        guard let w else {
            workspaceCancellable = nil
            host.show(nil)
            return
        }
        workspaceCancellable = w.$selectedID.combineLatest(w.$conversations, w.$diffFile)
            .sink { [weak self] id, conversations, diff in
                let c = diff == nil ? conversations.first { $0.id == id } : nil
                self?.host.show(c.map { ConversationViews.shared.view(for: $0) })
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
