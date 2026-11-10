import SwiftUI

/// Settings ▸ General ▸ Default model: the model conversations start with.
/// Claude Code picks its own default (and changes it between releases)
/// unless one of its other models is chosen here.
///
/// The choices are Claude Code's own list (what /model offers), kept from
/// the last conversation that received it. A chosen model that leaves the
/// list goes back to Claude Code's default, and the user is told.
@MainActor
final class DefaultModel: ObservableObject {
    static let shared = DefaultModel()

    /// Claude Code's default, as its model list names it.
    static let claudeCode = "default"

    private static let key = "DefaultModel"
    private static let listKey = "DefaultModelChoices"
    private static let removedKey = "DefaultModelRemoved"

    @Published var value: String {
        didSet {
            guard value != oldValue else { return }
            UserDefaults.standard.set(value, forKey: Self.key)
            removed = nil
        }
    }

    /// Claude Code's models, as last reported.
    @Published private(set) var models: [ClaudeConversation.ModelOption]

    /// The model that was chosen here until Claude Code stopped offering it
    /// (shown in Settings until another choice is made).
    @Published private(set) var removed: String? {
        didSet { UserDefaults.standard.set(removed, forKey: Self.removedKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        value = defaults.string(forKey: Self.key) ?? Self.claudeCode
        models = (defaults.array(forKey: Self.listKey) as? [[String: String]] ?? []).compactMap { m in
            guard let value = m["value"] else { return nil }
            return .init(value: value, name: m["name"] ?? value, detail: m["detail"] ?? "")
        }
        removed = defaults.string(forKey: Self.removedKey)
    }

    /// The model to start a conversation with; nil leaves it to Claude Code.
    var startModel: String? { value == Self.claudeCode ? nil : value }

    /// The models to choose from, besides Claude Code's default.
    var choices: [ClaudeConversation.ModelOption] { models.filter { $0.value != Self.claudeCode } }

    /// What Claude Code's default is right now ("Opus 5.5"), if known. Its
    /// default entry names the model first ("Opus 5.5 · Best for …").
    var claudeCodeModelName: String? {
        models.first { $0.value == Self.claudeCode }
            .flatMap { $0.detail.components(separatedBy: " · ").first }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func name(of value: String) -> String {
        models.first { $0.value == value }?.name ?? ClaudeConversation.prettyModel(value)
    }

    /// Claude Code's list, from a conversation that just received it. If
    /// the chosen model isn't offered anymore, the setting goes back to
    /// Claude Code's default and the user is told (once: the next
    /// conversation finds the setting already changed).
    func update(_ list: [ClaudeConversation.ModelOption]) {
        guard !list.isEmpty else { return }
        let chosen = value
        let chosenName = name(of: chosen)
        if list != models {
            models = list
            UserDefaults.standard.set(list.map { ["value": $0.value, "name": $0.name, "detail": $0.detail] },
                                      forKey: Self.listKey)
        }
        // Still offered under the same name counts: Claude Code lists a
        // model by its alias ("fable") or its full id depending on the session.
        guard chosen != Self.claudeCode,
              !list.contains(where: { $0.value == chosen || $0.name == chosenName }) else { return }
        value = Self.claudeCode
        removed = chosenName
        Activity.shared.announce(
            title: "\(chosenName) is no longer available",
            body: "Your default model is back to Claude Code's default\(claudeCodeModelName.map { " (\($0))" } ?? "").",
            action: { SettingsWindowController.shared.show(pane: "general") })
    }
}

/// Settings ▸ General.
struct GeneralSettingsView: View {
    @ObservedObject private var settings = DefaultModel.shared

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: $settings.value) {
                    Text(settings.claudeCodeModelName.map { "Claude Code Default (\($0))" } ?? "Claude Code Default")
                        .tag(DefaultModel.claudeCode)
                    if !settings.choices.isEmpty {
                        Divider()
                        ForEach(settings.choices) { Text($0.name).tag($0.value) }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if let removed = settings.removed {
                        Text("\(removed) is no longer available in Claude Code, so this went back to Claude Code's default.")
                            .foregroundStyle(.orange)
                    }
                    Text("The model conversations start with. Claude Code's default changes as Claude Code does; choose a model to keep starting with that one. You can still switch models in any conversation.")
                    if settings.models.isEmpty {
                        Text("Claude Code's models appear here once a conversation has started.")
                    }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 118 + (settings.removed != nil ? 28 : 0) + (settings.models.isEmpty ? 24 : 0))
    }
}
