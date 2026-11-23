import AppKit
import SwiftUI

/// Settings ▸ Terminal: how the terminals sit in the window (the
/// experiments: terminal tabs, the drawer under the conversation, and the
/// one at the bottom of the widget column).
@MainActor
final class TerminalLayoutSettings: ObservableObject {
    static let shared = TerminalLayoutSettings()

    enum Width: String, CaseIterable, Identifiable {
        /// The conversation's width and edges, centered.
        case constrained
        /// The whole column, edge to edge.
        case fullWidth

        var id: String { rawValue }
        var title: String {
            switch self {
            case .constrained: "Constrained"
            case .fullWidth: "Full Width"
            }
        }
    }

    private static let tabWidthKey = "ToastyTerminalTabWidth"
    private static let drawerWidthKey = "ToastyTerminalDrawerWidth"
    private static let sidebarKey = "ToastySidebarTerminal"

    /// A terminal tab's terminal.
    @Published var tabWidth: Width {
        didSet { UserDefaults.standard.set(tabWidth.rawValue, forKey: Self.tabWidthKey) }
    }

    /// The drawer's terminal (its header is always full width).
    @Published var drawerWidth: Width {
        didSet { UserDefaults.standard.set(drawerWidth.rawValue, forKey: Self.drawerWidthKey) }
    }

    /// The terminal at the bottom of the widget column. Off, it's gone:
    /// the widgets have the column, and its commands use the drawer.
    @Published var sidebarTerminal: Bool {
        didSet { UserDefaults.standard.set(sidebarTerminal, forKey: Self.sidebarKey) }
    }

    private init() {
        let d = UserDefaults.standard
        tabWidth = d.string(forKey: Self.tabWidthKey).flatMap(Width.init) ?? .fullWidth
        drawerWidth = d.string(forKey: Self.drawerWidthKey).flatMap(Width.init) ?? .fullWidth
        sidebarTerminal = d.object(forKey: Self.sidebarKey) as? Bool ?? true
    }
}

extension View {
    /// A terminal in the conversation column, at `width`: the
    /// conversation's width and edges, or the whole column.
    @ViewBuilder func terminalColumn(_ width: TerminalLayoutSettings.Width) -> some View {
        switch width {
        case .constrained:
            self.frame(maxWidth: ClaudeTypography.composerWidth)
                .padding(.horizontal, ClaudeStyle.horizontalPadding - 12)
                .frame(maxWidth: .infinity)
        case .fullWidth:
            self.padding(.horizontal, TitlebarRow.edge)
        }
    }
}

struct TerminalSettingsView: View {
    @ObservedObject private var layout = TerminalLayoutSettings.shared
    @ObservedObject private var cursor = TerminalCursorSetting.shared

    var body: some View {
        Form {
            Section {
                Picker("Width", selection: $layout.tabWidth) {
                    ForEach(TerminalLayoutSettings.Width.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Terminal Tabs")
            } footer: {
                Text("A terminal tab (⇧⌘T) in the row with your conversations. Constrained keeps it to the conversation's width; Full Width uses the whole column.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Width", selection: $layout.drawerWidth) {
                    ForEach(TerminalLayoutSettings.Width.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Terminal Drawer")
            } footer: {
                Text("The terminal that slides up under the conversation (⌘J). Its tabs always span the column; this sets the terminal under them.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Terminal under the widgets", isOn: $layout.sidebarTerminal)
            } header: {
                Text("Sidebar Terminal")
            } footer: {
                Text("Off, the terminal at the bottom of the widget column goes away and the widgets get the whole column. Open Terminal, New Terminal and Run in Terminal use the drawer instead. Its shells keep running and come back when you turn it on.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Blink the cursor", isOn: $cursor.blink)
            } footer: {
                Text("While a terminal has focus, as in Terminal and Ghostty. Off, it blinks only when the program in it asks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 520)
    }
}
