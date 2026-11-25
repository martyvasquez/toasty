import Combine
import AppKit
import SwiftUI

/// Whether the browser exists at all (Settings ▸ Browser, on by default
/// since 2026-11-21; turning it off is kept).
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

    /// Where a comment goes when it's finished with Return (the send key).
    enum CommentDestination: String, CaseIterable, Identifiable {
        /// Sent to the open conversation at once, as its own prompt.
        case conversation
        /// Added to the workspace's Tee-Up list, to send later.
        case teeUp

        var id: String { rawValue }
    }

    /// Where a comment goes now: Tee-Up only while its widget is in a space
    /// (its list is nowhere to be seen otherwise). The choice is kept, for
    /// when the widget comes back.
    var commentDestination: CommentDestination {
        TeeUpWidgetPresence.shared.active ? commentsTo : .conversation
    }

    @Published var commentsTo: CommentDestination {
        didSet { if commentsTo != oldValue { UserDefaults.standard.set(commentsTo.rawValue, forKey: Self.commentsKey) } }
    }
    private static let commentsKey = "PreviewCommentsTo"

    private init() {
        // On unless the user turned it off.
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        commentsTo = UserDefaults.standard.string(forKey: Self.commentsKey).flatMap(CommentDestination.init(rawValue:)) ?? .conversation
    }
}

/// Whether the Tee-Up widget is in any space: while it isn't, Tee-Up isn't
/// offered as a place for comments (what went there couldn't be seen).
@MainActor
final class TeeUpWidgetPresence: ObservableObject {
    static let shared = TeeUpWidgetPresence()
    @Published private(set) var active: Bool
    private var observer: AnyCancellable?

    private init() {
        let store = WorkspaceStore.shared
        active = Self.present(in: store.spaces)
        observer = store.$spaces
            .map(Self.present(in:))
            .removeDuplicates()
            .sink { [weak self] in self?.active = $0 }
    }

    private static func present(in spaces: [WidgetSpace]) -> Bool {
        spaces.contains { $0.widgets.contains { $0.kind == .teeUp } }
    }
}

/// Settings ▸ Browser.
struct PreviewSettingsView: View {
    @ObservedObject private var settings = PreviewSettings.shared
    @ObservedObject private var teeUpWidget = TeeUpWidgetPresence.shared

    var body: some View {
        Form {
            Section {
                Toggle("Browser", isOn: $settings.enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Experimental. A browser for the site you're developing, one per workspace with its own logins and storage, that Claude can use to open pages, click, type, take screenshots and read the console, instead of your own browser.")
                    Text("It runs in the background. One browser window, which never opens or comes forward by itself, shows the selected workspace's page. The compass at the end of the tabs shows when Claude is using it; click it (or press ⇧⌘B) to watch, or to use the same page yourself. The page is at phone or desktop size (⇧⌘M switches). Comment on anything in it to send it to the conversation you have open\(teeUpWidget.active ? " (or to Tee-Up, with the switch in the comment)" : "").")
                    Text("Claude gets the browser's tools as soon as you turn this on, in every conversation. While it's off, the browser isn't in Toasty at all and Claude Code runs exactly as it does by itself.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 240)
    }
}
