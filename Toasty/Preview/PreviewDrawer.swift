import AppKit
import Combine
import SwiftUI

/// A desktop page needs 1280 points to be drawn at its real size, and beside
/// the workspaces and the conversation a laptop's screen doesn't have them.
/// So a desktop page takes the whole window, and the workspaces and
/// conversation become a drawer over its left side: ⇧⌘S (or
/// its right edge, which is a button: `PreviewDrawerEdge`) slides it out and
/// puts it away. Nothing else does: no timer, no hovering, and clicking in the
/// page leaves it where it is.
///
/// The other way is the user's to choose (⇧⌘L, or the button in the preview's
/// controls; `PreviewSettings.desktopBeside`, one choice for every
/// workspace): the page beside the conversation, in whatever room is left,
/// drawn smaller when that's less than 1280 points. Nothing switches
/// between the two but the user (2026-11-11: the window's width used to,
/// and a layout that changed with it by itself was the worse surprise). A
/// phone is always beside the conversation.
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
    /// Something that decides `active` changed (the page's size, or which
    /// way the user wants a desktop page).
    let changed = PassthroughSubject<Void, Never>()

    /// The conversation is put away: nobody is looking at it.
    var hidesConversation: Bool { active && !open }

    /// Whether the page takes the whole window: the workspace is showing a
    /// desktop page, and the user hasn't asked for it beside the conversation.
    static func wanted(for workspace: Workspace?) -> Bool {
        guard let workspace, workspace.previewShowing, !PreviewSettings.shared.desktopBeside else { return false }
        return PreviewStore.shared.session(for: workspace).viewport == .desktop
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

/// The drawer's right edge, all of it a button: a flush strip the height of
/// the window with a chevron, nothing else (the user, 2026-11-11: ticks
/// beside it were clutter), which slides the drawer out
/// or puts it away. It stays at the window's left edge while the drawer is
/// away, so the way back is where the drawer went (the user, 2026-11-11: a
/// button among the preview's controls wasn't obvious enough).
struct PreviewDrawerEdge: View {
    static let width: CGFloat = 18

    @ObservedObject private var drawer = PreviewDrawer.shared
    @State private var hovering = false

    var body: some View {
        Button { AppDelegate.shared.windowController?.toggleWorkspaces(nil) } label: { Color.clear }
            .buttonStyle(PreviewDrawerEdgeStyle(open: drawer.open, hovering: hovering))
            .onHover { hovering = $0 }
            .help(drawer.open ? "Hide Workspaces and Conversation (⇧⌘S)"
                              : "Show Workspaces and Conversation (⇧⌘S)")
            .accessibilityLabel(drawer.open ? "Hide Workspaces and Conversation"
                                            : "Show Workspaces and Conversation")
    }
}

private struct PreviewDrawerEdgeStyle: ButtonStyle {
    let open: Bool
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let lit = hovering || configuration.isPressed
        Image(systemName: "chevron.left")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .rotationEffect(.degrees(open ? 0 : 180))
            .animation(.easeInOut(duration: 0.2), value: open)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ZStack {
                Color.claudeChrome
                Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.05 : 0)
            })
            // Out, it's between the conversation and the page; away, the
            // window's own edge is on its left.
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.claudeSeparator).frame(width: 0.5).opacity(open ? 1 : 0)
            }
            .overlay(alignment: .trailing) { Rectangle().fill(Color.claudeSeparator).frame(width: 0.5) }
            .contentShape(Rectangle())
    }
}

// MARK: - Titlebar

/// At the left of the preview's controls while the drawer is away: the
/// conversation's status. (The drawer's own edge is what moves it:
/// `PreviewDrawerEdge`.)
struct PreviewDrawerControls: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var drawer = PreviewDrawer.shared

    var body: some View {
        if drawer.hidesConversation, let conversation = workspace.selected {
            PreviewDrawerStatus(conversation: conversation)
                .id(conversation.id)
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
