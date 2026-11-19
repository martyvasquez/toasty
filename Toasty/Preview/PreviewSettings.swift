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

    /// A desktop page beside the conversation, in the room that's left
    /// (drawn smaller in less than 1280 points), and not across the whole
    /// window with the conversation a drawer over it (`PreviewDrawer`). One
    /// choice for every workspace, made from the preview's controls or ⇧⌘L.
    @Published var desktopBeside: Bool {
        didSet {
            guard desktopBeside != oldValue else { return }
            UserDefaults.standard.set(desktopBeside, forKey: Self.besideKey)
            PreviewDrawer.shared.changed.send()
        }
    }
    private static let besideKey = "PreviewDesktopBeside"

    /// Where a comment goes when it's finished with Return.
    /// (⇧Return sends it to the other one.)
    enum CommentDestination: String, CaseIterable, Identifiable {
        /// Sent to the open conversation at once, as its own prompt.
        case conversation
        /// Added to the workspace's Tee-Up list, to send later.
        case teeUp

        var id: String { rawValue }

        var other: CommentDestination { self == .teeUp ? .conversation : .teeUp }

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
        desktopBeside = UserDefaults.standard.bool(forKey: Self.besideKey)
        commentsTo = UserDefaults.standard.string(forKey: Self.commentsKey).flatMap(CommentDestination.init(rawValue:)) ?? .conversation
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
                    Text("Experimental. A browser beside the conversation (⇧⌘B) for the site you're developing, at phone or desktop size (⇧⌘M switches). Comment on anything in the page to send it to the conversation you have open (or to Tee-Up, below), and Claude can open pages, take screenshots and read the console there instead of in your own browser.")
                    Text("A desktop page takes the whole window, and its left edge (or ⇧⌘S) slides your workspaces and the conversation over it. ⇧⌘L puts the page beside the conversation instead, drawn smaller when there isn't room for it.")
                    Text("Claude gets the preview's tools in conversations started after you turn this on. While it's off, the preview isn't in Toasty at all and Claude Code runs exactly as it does by itself.")
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
            "Return sends a comment to the open conversation at once, with a screenshot of the page. Shift-Return adds it to Tee-Up instead."
        case .teeUp:
            "Return adds a comment to the workspace's Tee-Up list, with a screenshot of the page, and you can go on commenting. Send them when you're ready, one by one or with Auto-Send. Shift-Return sends a comment to the conversation instead."
        }
    }
}
