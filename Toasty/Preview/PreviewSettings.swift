import AppKit
import SwiftUI

/// Whether the browser exists at all (Settings ▸ Browser, off by default).
/// Experimental, and the one place Toasty gives Claude tools of its own
/// (BUILD_PLAN §1), so off means off: no titlebar indicator, no menu item or
/// shortcut, no web view, and conversations start without the `preview` MCP
/// server, exactly as Claude Code is by itself.
///
/// It's a browser per workspace that Claude drives in the background (each
/// with its own cookies, storage and page), and one window of its own that
/// shows the selected workspace's, which the user opens when they want to
/// look (it was a panel in the main window until 2026-11-20; the user: the
/// main window is for conversations, the browser is a tool beside it).
///
/// Everything the feature is lives in `Toasty/Preview/`. To remove it,
/// delete that folder, `Debug/PreviewDebug.swift` and `Tests/PreviewTests`,
/// then what's outside them: the indicator in the titlebar (`TitlebarTabs`),
/// its commands (`MainWindowController`, `MainMenu`, `KeyboardShortcuts`),
/// local links clicked in a terminal (`TerminalView.open`), the settings
/// pane (`SettingsWindow`), the bridge's MCP relay (`toasty-agent.mjs`;
/// `ClaudeConversation`: `mcpServers`, `mcp_call`, the reload at a turn's
/// end), App Transport Security in `project.yml`, and the two exceptions in
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

    /// Where a comment goes when it's finished with Return.
    /// (⇧Return sends it to the other one.)
    enum CommentDestination: String, CaseIterable, Identifiable {
        /// Sent to the open conversation at once, as its own prompt.
        case conversation
        /// Added to the workspace's Tee-Up list, to send later.
        case teeUp

        var id: String { rawValue }


        var title: String {
            switch self {
            case .conversation: "The conversation"
            case .teeUp: "Tee-Up"
            }
        }
    }

    @Published var commentsTo: CommentDestination {
        didSet { if commentsTo != oldValue { UserDefaults.standard.set(commentsTo.rawValue, forKey: Self.commentsKey) } }
    }
    private static let commentsKey = "PreviewCommentsTo"

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.key)
        commentsTo = UserDefaults.standard.string(forKey: Self.commentsKey).flatMap(CommentDestination.init(rawValue:)) ?? .conversation
    }
}

/// Settings ▸ Browser.
struct PreviewSettingsView: View {
    @ObservedObject private var settings = PreviewSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Browser", isOn: $settings.enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Experimental. A browser for the site you're developing, one per workspace with its own logins and storage, that Claude can use to open pages, click, type, take screenshots and read the console, instead of your own browser.")
                    Text("It runs in the background. One browser window, which never opens or comes forward by itself, shows the selected workspace's page. The compass at the end of the tabs shows when Claude is using it; click it (or press ⇧⌘B) to watch, or to use the same page yourself. The page is at phone or desktop size (⇧⌘M switches). Comment on anything in it to send it to the conversation you have open (or to Tee-Up, below).")
                    Text("Claude gets the browser's tools in conversations started after you turn this on. While it's off, the browser isn't in Toasty at all and Claude Code runs exactly as it does by itself.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("A comment goes to", selection: $settings.commentsTo) {
                    ForEach(PreviewSettings.CommentDestination.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(!settings.enabled)
            } header: {
                Text("Comments")
            } footer: {
                Text(commentsDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 390)
    }

    private var commentsDetail: String {
        switch settings.commentsTo {
        case .conversation:
            "Return sends a comment to the open conversation at once, with a screenshot of the page. You can also switch to Tee-Up in the comment itself."
        case .teeUp:
            "Return adds a comment to the workspace's Tee-Up list, with a screenshot of the page, and you can go on commenting. Send them when you're ready, one by one or with Auto-Send. You can also switch to Send in the comment itself."
        }
    }
}
