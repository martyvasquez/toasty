import AppKit
import Combine
import SwiftUI

/// A desktop page needs 1280 points to be drawn at its real size, and beside
/// the workspaces and the conversation a laptop's screen doesn't have them.
/// So when they don't all fit, the page takes the whole window and the
/// workspaces and conversation become a drawer over its left side: ⇧⌘S (or
/// the button at the left of the preview's controls) slides it out and puts
/// it away. Nothing else does: no timer, no hovering, and clicking in the
/// page leaves it where it is.
///
/// In a window with room for everything (and at phone size, which always
/// fits) nothing changes: the page is beside the conversation.
///
/// `MainContainerController` does the moving; this is the state everything
/// else reads.
@MainActor
final class PreviewDrawer: ObservableObject {
    static let shared = PreviewDrawer()

    /// The page has the whole window, and the conversation is a drawer.
    @Published private(set) var active = false
    /// The drawer is out. Kept while the page isn't using the whole window,
    /// so it comes back as it was left.
    @Published private(set) var open = true
    /// Something that decides `active` changed (the page's size).
    let changed = PassthroughSubject<Void, Never>()

    /// The conversation is put away: nobody is looking at it.
    var hidesConversation: Bool { active && !open }

    /// Whether the page takes the whole window: the workspace is showing a
    /// desktop page, and `width` (the window's) hasn't room for it at full
    /// size beside the workspaces and the conversation. The workspaces count
    /// whether or not they're showing, so hiding them doesn't change which
    /// way a window works.
    static func wanted(for workspace: Workspace?, width: CGFloat, sidebar: CGFloat) -> Bool {
        guard let workspace, workspace.previewShowing,
              PreviewStore.shared.session(for: workspace).viewport == .desktop else { return false }
        return !fits(width: width, sidebar: sidebar)
    }

    static func fits(width: CGFloat, sidebar: CGFloat) -> Bool {
        width >= sidebar + MainSplitViewController.minConversation + PreviewViewport.desktop.nominal.width + 1
    }

    func setActive(_ on: Bool) {
        if active != on { active = on }
    }

    func setOpen(_ on: Bool) {
        if open != on { open = on }
    }

    /// Something was asked of the conversation (a new tab, a notification
    /// clicked): bring it out if it's put away.
    func reveal() {
        if hidesConversation { open = true }
    }
}

// MARK: - The page, under the drawer

/// The active workspace's page across the whole window (below the titlebar),
/// while the drawer is how the conversation is reached. Otherwise empty: the
/// page is in the right column (`PreviewColumn`).
struct PreviewDrawerPage: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var drawer = PreviewDrawer.shared

    var body: some View {
        ZStack {
            if drawer.active, let workspace = store.active {
                Color.claudeChrome
                PreviewDrawerPageWorkspace(workspace: workspace)
            }
        }
    }
}

private struct PreviewDrawerPageWorkspace: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if workspace.previewShowing { PreviewPane(workspace: workspace, overWindow: true) }
    }
}

/// The drawer's right edge: a hairline and a soft shadow on the page, so the
/// drawer reads as over the page and not beside it. Takes no clicks.
final class PreviewDrawerEdge: NSView {
    static let width: CGFloat = 14

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSGradient(colors: [NSColor.black.withAlphaComponent(dark ? 0.38 : 0.14),
                            NSColor.black.withAlphaComponent(dark ? 0.12 : 0.04),
                            NSColor.black.withAlphaComponent(0)],
                   atLocations: [0, 0.35, 1], colorSpace: .deviceRGB)?
            .draw(in: bounds, angle: 0)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 0.5, height: bounds.height).fill(using: .sourceOver)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Titlebar

/// At the left of the preview's controls while the drawer is how the
/// conversation is reached: the button that slides it out or puts it away,
/// and, while it's away, the conversation's status.
struct PreviewDrawerControls: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var drawer = PreviewDrawer.shared

    var body: some View {
        if drawer.active {
            PreviewIconButton(symbol: "sidebar.left",
                              help: drawer.open ? "Hide Workspaces and Conversation (⇧⌘S)"
                                                : "Show Workspaces and Conversation (⇧⌘S)",
                              selected: drawer.open) {
                AppDelegate.shared.windowController?.toggleWorkspaces(nil)
            }
            if !drawer.open, let conversation = workspace.selected {
                PreviewDrawerStatus(conversation: conversation)
                    .id(conversation.id)
            }
        }
    }
}

/// The open conversation while the drawer is away, as its tab shows it: the
/// same status (working, waiting for you, finished) and its name, which is
/// also where a comment on the page goes. Clicking it brings the drawer out.
private struct PreviewDrawerStatus: View {
    @ObservedObject var conversation: ClaudeConversation
    @State private var hovering = false

    var body: some View {
        Button { PreviewDrawer.shared.setOpen(true) } label: {
            HStack(spacing: 6) {
                ConversationStatusIcon(conversation: conversation, selected: false)
                    .frame(width: 12)
                Text(conversation.title)
                    .font(.system(size: TabStyle.fontSize))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .frame(maxWidth: 200)
            .fixedSize(horizontal: true, vertical: false)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .onHover { hovering = $0 }
        .help("\(statusWord)\(conversation.title). Click to show the conversation (⇧⌘S).")
        .accessibilityLabel("\(statusWord)\(conversation.title)")
        .accessibilityHint("Shows the conversation")
    }

    private var statusWord: String {
        if !conversation.requests.isEmpty { return "Waiting for you: " }
        if conversation.phase != .idle { return "Working: " }
        if conversation.attention { return "Finished: " }
        return ""
    }
}
