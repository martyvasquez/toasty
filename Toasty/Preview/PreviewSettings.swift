import Combine
import AppKit
import SwiftUI

/// Whether the browser exists at all (Settings ▸ Browser, on by default
/// since 2026-11-21; turning it off is kept).
/// The one place Toasty gives Claude tools of its own
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

    /// The browser tab fills the window: while it shows, the workspaces
    /// and the widgets step aside (they come back with any other tab).
    @Published var fillsWindow: Bool {
        didSet { if fillsWindow != oldValue { UserDefaults.standard.set(fillsWindow, forKey: Self.fillsKey) } }
    }
    private static let fillsKey = "PreviewTabFillsWindow"

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

    /// Which links clicked in a terminal open here instead of in the
    /// default browser: localhost names, IP addresses, and the user's sites.
    /// Every http(s) link, whatever its address (the rest are then moot).
    @Published var opensEveryLink: Bool {
        didSet { UserDefaults.standard.set(opensEveryLink, forKey: Self.everyLinkKey) }
    }
    @Published var opensLocalhost: Bool {
        didSet { UserDefaults.standard.set(opensLocalhost, forKey: Self.localhostKey) }
    }
    @Published var opensIPAddresses: Bool {
        didSet { UserDefaults.standard.set(opensIPAddresses, forKey: Self.ipKey) }
    }
    /// As typed in Settings (blank rows included, so a new row stays).
    @Published var siteRows: [SiteRow] {
        didSet { UserDefaults.standard.set(siteRows.map(\.text), forKey: Self.sitesKey) }
    }
    /// The sites, each a bare host: "https://Staging.example.com/x" is
    /// "staging.example.com". Its subdomains open here too.
    var sites: [String] { siteRows.compactMap { Self.host(of: $0.text) } }
    private static let everyLinkKey = "PreviewOpensEveryLink"
    private static let localhostKey = "PreviewOpensLocalhost"
    private static let ipKey = "PreviewOpensIPAddresses"
    private static let sitesKey = "PreviewOpenSites"

    struct SiteRow: Identifiable {
        let id = UUID()
        var text = ""
    }

    nonisolated static func host(of typed: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if t.hasPrefix("*.") { t.removeFirst(2) }
        t = String(t.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" })
        return t.isEmpty ? nil : t
    }

    private init() {
        // On unless the user turned it off.
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
        fillsWindow = UserDefaults.standard.bool(forKey: Self.fillsKey)
        commentsTo = UserDefaults.standard.string(forKey: Self.commentsKey).flatMap(CommentDestination.init(rawValue:)) ?? .conversation
        opensEveryLink = UserDefaults.standard.bool(forKey: Self.everyLinkKey)
        opensLocalhost = UserDefaults.standard.object(forKey: Self.localhostKey) as? Bool ?? true
        opensIPAddresses = UserDefaults.standard.object(forKey: Self.ipKey) as? Bool ?? true
        siteRows = (UserDefaults.standard.stringArray(forKey: Self.sitesKey) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { SiteRow(text: $0) }
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
    @State private var selectedSites = Set<PreviewSettings.SiteRow.ID>()
    @FocusState private var focusedSite: PreviewSettings.SiteRow.ID?

    var body: some View {
        Form {
            Section {
                Toggle("Browser", isOn: $settings.enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A browser for the site you're developing, one per workspace with its own logins and storage, that Claude can use to open pages, click, type, take screenshots and read the console, instead of your own browser.")
                    Text("It's browser tabs beside your conversations (+ opens one; ⇧⌘B goes to it and back), each of which can move to a window of its own (its ≡ menu). Each conversation's Claude gets a tab of its own, blue, that never comes forward by itself; it pulses while Claude uses it, and you can watch or use the same page yourself. The page is at phone or desktop size (⇧⌘M switches). Comment on anything in it to send it to the conversation you have open\(teeUpWidget.active ? " (or to Tee-Up, with the switch in the comment)" : "").")
                    Text("Claude gets the browser's tools as soon as you turn this on, in every conversation. While it's off, the browser isn't in Toasty at all and Claude Code runs exactly as it does by itself.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Every link", isOn: $settings.opensEveryLink)
                if !settings.opensEveryLink {
                    Toggle("localhost", isOn: $settings.opensLocalhost)
                    Toggle("IP addresses", isOn: $settings.opensIPAddresses)
                }
            } header: {
                Text("Links That Open Here")
            } footer: {
                Text(settings.opensEveryLink
                     ? "Every web link you click in a terminal opens in this browser."
                     : "A link you click in a terminal opens in this browser when it's one of these, and in your default browser otherwise. localhost includes *.localhost and *.local.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.enabled)
            if !settings.opensEveryLink {
                Section {
                    Table($settings.siteRows, selection: $selectedSites) {
                        TableColumn("Site") { $row in
                            TextField("staging.example.com", text: $row.text).labelsHidden()
                                .focused($focusedSite, equals: row.id)
                        }
                    }
                    .tableColumnHeaders(.hidden)
                    .frame(height: 96)
                    AddRemove(add: {
                                  // Empty, it can't be seen: the cursor goes in it.
                                  let row = PreviewSettings.SiteRow()
                                  settings.siteRows.append(row)
                                  selectedSites = [row.id]
                                  DispatchQueue.main.async { focusedSite = row.id }
                              },
                              remove: { settings.siteRows.removeAll { selectedSites.contains($0.id) } },
                              canRemove: !selectedSites.isEmpty)
                } header: {
                    Text("Your Sites")
                } footer: {
                    Text("These open here too, each with its subdomains (example.com includes staging.example.com).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!settings.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: settings.opensEveryLink ? 365 : 665)
    }
}
