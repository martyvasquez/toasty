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
/// `TitlebarTabs`, `MainWindowController`, `MainMenu`), the drawer the
/// conversation becomes when a desktop page needs the whole window
/// (`PreviewDrawer`: `MainContainerController`, `drawerMode` in
/// `MainSplitViewController`, and its uses in `TitlebarTabs`,
/// `MainWindowController` and `Activity`), local links clicked
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

    /// The preview's column at phone size: the phone and a little room
    /// either side, until the user drags it to another width. (A desktop
    /// page takes all the room there is instead.)
    var phoneColumnWidth: CGFloat {
        get { (UserDefaults.standard.object(forKey: Self.phoneWidthKey) as? Double).map { CGFloat($0) } ?? Self.defaultPhoneColumnWidth }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.phoneWidthKey) }
    }
    static let defaultPhoneColumnWidth: CGFloat = 430
    private static let phoneWidthKey = "PreviewPhoneColumnWidth"

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.key)
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
                    Text("Experimental. A browser beside the conversation (⇧⌘B) for the site you're developing, at phone or desktop size (⇧⌘M switches). Comment on anything in the page to send it to the conversation you have open, and Claude can open pages, take screenshots and read the console there instead of in your own browser.")
                    Text("A desktop page is shown at its real size. In a window too narrow for that beside the conversation, the page takes the whole window and ⇧⌘S slides your workspaces and the conversation over it.")
                    Text("Claude gets the preview's tools in conversations started after you turn this on. While it's off, the preview isn't in Toasty at all and Claude Code runs exactly as it does by itself.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 265)
    }
}
