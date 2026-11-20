import SwiftUI

/// The sidebar's handle, as Things': a small pill just inside the
/// conversation's left edge that appears when the pointer comes near and
/// hides or shows the workspaces when clicked. With the sidebar hidden it
/// waits at the window's edge.
struct SidebarHandle: View {
    @ObservedObject var store: WorkspaceStore
    @State private var hovering = false

    var body: some View {
        Button { AppDelegate.shared.windowController?.toggleWorkspaces(nil) } label: {
            ZStack(alignment: .leading) {
                Color.clear
                Capsule()
                    .fill(Theme.Sidebar.handle)
                    .frame(width: 8, height: 38)
                    .padding(.leading, 7.5)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHandleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .tooltip(Tooltip(title: store.sidebarVisible ? "Hide Workspaces" : "Show Workspaces", shortcut: "⇧⌘S"))
        .accessibilityLabel(store.sidebarVisible ? "Hide Workspaces" : "Show Workspaces")
    }
}

/// Brighter while pressed (Things: white 18% → 47%).
private struct SidebarHandleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.brightness(configuration.isPressed ? 0.25 : 0)
    }
}
