import AppKit
import SwiftUI

/// Whether the preview browser exists at all (Settings ▸ Preview, off by
/// default). Experimental, and the one place Toasty gives Claude tools of its
/// own (BUILD_PLAN §1), so off means off: no titlebar button, no menu item or
/// shortcut, no web view, and conversations start without the `preview` MCP
/// server, exactly as Claude Code is by itself.
///
/// Everything the feature is lives in `Toasty/Preview/`. To remove it,
/// delete that folder, `Debug/PreviewDebug.swift` and `Tests/PreviewTests`,
/// then what's outside them: the preview's turn in the right column
/// (`previewVisible` in `Workspace.swift`, `MainSplitViewController`,
/// `TitlebarTabs`, `MainWindowController`, `MainMenu`; `applySidebar` and
/// `sidebarHiddenForPreview` there hide the workspaces sidebar), local links clicked
/// in a terminal (`TerminalView.open`), the settings pane
/// (`SettingsWindow`), the bridge's MCP relay
/// (`toasty-agent.mjs`; `ClaudeConversation`: `mcpServers`, `mcp_call`),
/// App Transport Security in `project.yml`, and the two exceptions in
/// `BUILD_PLAN.md` §1.
@MainActor
final class PreviewSettings: ObservableObject {
    static let shared = PreviewSettings()
    private static let key = "PreviewEnabled"

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.key)
            if !enabled { PreviewStore.shared.turnedOff() }
        }
    }

    /// While the preview is open, the workspaces sidebar gets out of its way
    /// (on unless the user turned it off).
    @Published var collapsesSidebar: Bool {
        didSet { UserDefaults.standard.set(collapsesSidebar, forKey: Self.sidebarKey) }
    }
    private static let sidebarKey = "PreviewCollapsesSidebar"

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.key)
        collapsesSidebar = UserDefaults.standard.object(forKey: Self.sidebarKey) as? Bool ?? true
    }
}

/// Settings ▸ Preview.
struct PreviewSettingsView: View {
    @ObservedObject private var settings = PreviewSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Preview browser", isOn: $settings.enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Experimental. A browser beside the conversation (⌃⌘P) for the site you're developing, at phone or desktop size. Comment on anything in the page to send it to the conversation you have open, and Claude can open pages, take screenshots and read the console there instead of in your own browser.")
                    Text("Claude gets the preview's tools in conversations started after you turn this on. While it's off, the preview isn't in Toasty at all and Claude Code runs exactly as it does by itself.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Hide the workspaces sidebar while the preview is open", isOn: $settings.collapsesSidebar)
                    .disabled(!settings.enabled)
            } footer: {
                Text("Gives the page the sidebar's room, which matters most for the desktop size on a small screen. ⌃⌘S shows your workspaces over the conversation until you pick one or press Esc.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 325)
    }
}
