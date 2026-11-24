import SwiftUI

// What edit mode offers a widget beside it (a click on it, or its menu):
// the pieces every widget's options popover is built from, and the
// options of the widgets that aren't big enough to say it all.

/// How a Small shows its one value.
enum WidgetGlanceStyle: String, Codable, CaseIterable, Identifiable {
    case number, ring
    var id: String { rawValue }
    var title: String { self == .number ? "Number" : "Ring" }
}

/// An options popover: its title, then its rows.
struct WidgetOptionsForm<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(.toasty(Theme.Size.control, .semibold))
                .padding(.bottom, Theme.Space.xs)
            content()
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 260, alignment: .leading)
    }
}

/// A row's name, right-aligned in the form's first column (inside a `Grid`).
struct WidgetOptionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.control))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// A row of choices: a segmented control.
struct WidgetOptionChoice<Value: Hashable & Identifiable>: View {
    let title: String
    let values: [Value]
    let name: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(values) { Text(name($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Usage

/// What a Small Usage widget shows.
enum UsageGlance: String, Codable, CaseIterable, Identifiable {
    case context, session, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .context: "Context"
        case .session: "Session"
        case .week: "Week"
        }
    }
    /// The plan limit it follows (`ClaudeConversation.RateLimit.type`).
    var limitType: String? {
        switch self {
        case .context: nil
        case .session: "five_hour"
        case .week: "seven_day"
        }
    }
}

/// A Usage widget's options (Small only), saved with it.
struct UsageOptions: Codable, Equatable {
    var glance: UsageGlance = .context
    var style: WidgetGlanceStyle = .ring

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glance = (try? c.decodeIfPresent(UsageGlance.self, forKey: .glance)) ?? .context
        style = (try? c.decodeIfPresent(WidgetGlanceStyle.self, forKey: .style)) ?? .ring
    }
}

struct UsageOptionsView: View {
    let item: WidgetItem
    let set: (UsageOptions) -> Void

    private var options: UsageOptions { item.usage }

    var body: some View {
        WidgetOptionsForm(title: "Small Usage Widget") {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                GridRow {
                    WidgetOptionLabel("Show")
                    WidgetOptionChoice(title: "Show", values: UsageGlance.allCases, name: \.title,
                                       selection: binding(\.glance))
                }
                GridRow {
                    WidgetOptionLabel("Style")
                    WidgetOptionChoice(title: "Style", values: WidgetGlanceStyle.allCases, name: \.title,
                                       selection: binding(\.style))
                }
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<UsageOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: key] }, set: { var o = options; o[keyPath: key] = $0; set(o) })
    }
}
