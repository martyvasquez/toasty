import SwiftUI

/// The middle column: the active workspace's selected conversation.
/// (Phase 3 puts `ClaudeConversationView` here.)
struct ConversationColumn: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            Color.claudeBackground
                // Clicking the page takes focus away from the terminal.
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
            if let workspace = store.active {
                WorkspaceConversation(workspace: workspace)
            } else {
                EmptyState(symbol: "folder", title: "No Workspace",
                           button: "New Workspace…", shortcut: "⌘N") { store.createWithFolderPicker() }
            }
        }
        .ignoresSafeArea()
    }
}

private struct WorkspaceConversation: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let conversation = workspace.selected {
            ConversationPlaceholder(conversation: conversation)
                .id(conversation.id)
        } else {
            EmptyState(symbol: "sparkle", title: workspace.name,
                       button: "New Tab", shortcut: "⌘T") { workspace.newConversation() }
        }
    }
}

/// Phase 2 stand-in for the transcript and composer.
private struct ConversationPlaceholder: View {
    @ObservedObject var conversation: ClaudeConversation

    var body: some View {
        VStack(spacing: 6) {
            Text(conversation.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text((conversation.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
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
