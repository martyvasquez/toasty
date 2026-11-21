import SwiftUI

extension SidebarHandle {
    /// The handles' strips start this far from a column's divider, leaving
    /// its grab area (4pt either side) to the divider; the pill is drawn
    /// this much nearer the edge, so it stays where it was.
    static let dividerClearance: CGFloat = 5
}

/// The sidebar's handle, as Things': a small pill just inside the
/// conversation's left edge that appears when the pointer comes near and
/// hides or shows the workspaces when clicked. With the sidebar hidden it
/// waits at the window's edge.
struct SidebarHandle: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        EdgeHandle(edge: .leading,
                   tooltip: Tooltip(title: store.sidebarVisible ? "Hide Workspaces" : "Show Workspaces", shortcut: "⇧⌘S")) {
            AppDelegate.shared.windowController?.toggleWorkspaces(nil)
        }
    }
}

/// The inspector's handle: the sidebar's, mirrored, just inside the
/// conversation's right edge. It hides or shows the inspector and
/// terminal; with them hidden it waits at the window's edge.
struct InspectorHandle: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if let workspace = store.active {
            Content(workspace: workspace)
        }
    }

    private struct Content: View {
        @ObservedObject var workspace: Workspace

        var body: some View {
            let shown = workspace.rightColumnVisible
            EdgeHandle(edge: .trailing,
                       tooltip: Tooltip(title: shown ? "Hide Inspector and Terminal" : "Show Inspector", shortcut: "⇧⌘D")) {
                AppDelegate.shared.windowController?.toggleRightColumn(nil)
            }
        }
    }
}

/// A pill along one of the conversation's edges, shown while the pointer
/// is near it.
private struct EdgeHandle: View {
    let edge: HorizontalEdge
    let tooltip: Tooltip
    let action: () -> Void
    @State private var hovering = false
    @State private var pill = TooltipAnchor()

    var body: some View {
        Button(action: action) {
            ZStack(alignment: edge == .leading ? .leading : .trailing) {
                Color.clear
                Capsule()
                    .fill(Theme.Sidebar.handle)
                    .frame(width: 8, height: 38)
                    .tooltipAnchor(pill)
                    .padding(edge == .leading ? .leading : .trailing, 7.5 - SidebarHandle.dividerClearance)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(EdgeHandleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        // The label shows beside the pill, toward the conversation (not at
        // the top of the tall hover strip).
        .tooltip(tooltip, placement: edge == .leading ? .trailing : .leading, at: pill)
        .accessibilityLabel(tooltip.title)
    }
}

/// Brighter while pressed (Things: white 18% → 47%).
private struct EdgeHandleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? 0.25 : 0)
    }
}
