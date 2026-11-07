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
        if let conversation = workspace.selected {
            ClaudeConversationView(conversation: conversation,
                                   onRunInTerminal: { [weak workspace] in workspace?.runInTerminal($0) })
                .id(conversation.id)
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
