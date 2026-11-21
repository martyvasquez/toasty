import AppKit
import SwiftUI

/// The inspector's design system: one skeleton for every pane (Changes,
/// Tee-Up, Activity), built from these pieces only.
///
///     tab bar → summary row → sections → pinned section → footer
///
/// No pane titles (the selected tab says where you are). Sections are set
/// apart by space, never rules. One row. One empty state. Color means
/// status: change letters, meters and headings are neutral; orange only
/// when something needs you, red only for stopped; diff counts use the
/// soft green and pink.

// MARK: - Summary row

/// The pane's live state, always first: a 16pt lead (a spinner, a status
/// dot or the pane's glyph), the title, a trailing value or the pane's
/// controls, and one quiet line under it.
struct InspectorSummary<Lead: View, Trailing: View>: View {
    let title: String
    var detail: Text?
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            lead()
                .frame(width: Theme.Todo.box, height: 20)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.s) {
                    Text(title)
                        .font(.toasty(Theme.Size.body, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .frame(minHeight: 20)
                if let detail {
                    detail
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Theme.Inspector.edge)
        .padding(.top, Theme.Inspector.top)
        .accessibilityElement(children: .contain)
    }
}

extension InspectorSummary where Trailing == EmptyView {
    init(title: String, detail: Text? = nil, @ViewBuilder lead: @escaping () -> Lead) {
        self.init(title: title, detail: detail, lead: lead, trailing: { EmptyView() })
    }
}

/// A pane glyph in the summary's lead slot.
struct InspectorGlyph: View {
    let symbol: String
    var style: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        Image(systemName: symbol)
            .font(.toasty(Theme.Size.control))
            .foregroundStyle(style)
    }
}

/// A trailing value on the summary or a row: mono 12, secondary.
struct InspectorValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.meta, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A pane control at the summary's trailing edge (Auto-Send's play,
/// pause, stop): a 28pt slot that hangs past the row's edge so the glyph
/// lines up with the values under it.
struct InspectorControl: View {
    let symbol: String
    let tooltip: Tooltip
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: Theme.Control.height, height: Theme.Control.height)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(hovering && enabled ? Theme.Fill.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -Theme.Space.xs)
        .onHover { hovering = $0 }
        .tooltip(tooltip)
        .accessibilityLabel(tooltip.title)
    }
}

// MARK: - Sections

/// A section's heading: 12 semibold, secondary, Title Case, with an
/// optional count (or other small accessory) at the right. 24 tall.
struct InspectorSectionHeading<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(.toasty(Theme.Size.meta, .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            accessory()
        }
        .frame(height: Theme.Inspector.rowHeight)
        .padding(.horizontal, Theme.Inspector.edge)
        .accessibilityAddTraits(.isHeader)
    }
}

extension InspectorSectionHeading where Accessory == AnyView {
    init(title: String, count: Int? = nil) {
        self.title = title
        self.accessory = {
            AnyView(Group {
                if let count {
                    Text("\(count)")
                        .font(.toasty(Theme.Size.caption))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            })
        }
    }
}

/// A heading and its rows, `Theme.Inspector.sectionGap` under what's above.
struct InspectorListSection<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSectionHeading(title: title, count: count)
            content()
        }
        .padding(.top, Theme.Inspector.sectionGap)
    }
}

// MARK: - Row

/// The one row: 28 tall, a 16pt icon box on the 20pt edge (13 outside +
/// 7 inside, as the sidebar), the label 13, its detail 12 inline after it
/// (truncating first), a trailing value. A second line only when it
/// carries live progress (then 46 tall).
struct InspectorRow<Icon: View, Trailing: View>: View {
    let label: Text
    var detail: String?
    var progress: String?
    var selected = false
    var hoverable = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        Group {
            if let progress {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    icon().frame(width: Theme.Todo.box, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Space.s) {
                            firstLine.frame(maxWidth: .infinity, alignment: .leading)
                            trailing()
                        }
                        .frame(height: 18)
                        Text(progress)
                            .font(.toasty(Theme.Size.meta))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(height: 16)
                    }
                }
                .padding(.vertical, 5)
            } else {
                HStack(spacing: Theme.Space.s) {
                    icon().frame(width: Theme.Todo.box, height: Theme.Todo.box)
                    firstLine
                    Spacer(minLength: 0)
                    trailing()
                }
                .frame(height: Theme.Control.height)
            }
        }
        .padding(.leading, Theme.Sidebar.rowLeading)
        .padding(.trailing, Theme.Sidebar.rowTrailing)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(selected ? Theme.Fill.selected : (hovering && hoverable ? Theme.Fill.hover : Color.clear)))
        .padding(.horizontal, Theme.Sidebar.inset)
        .contentShape(Rectangle())
        .onHover { if hoverable { hovering = $0 } }
    }

    private var firstLine: some View {
        HStack(spacing: Theme.Space.s) {
            label
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

extension InspectorRow {
    /// A label in the row's text style: 13, or mono 12 for a command.
    static func label(_ text: String, code: Bool = false, quiet: Bool = false) -> Text {
        Text(text)
            .font(code ? .toasty(Theme.Size.meta, design: .monospaced) : .toasty(Theme.Size.control))
            .foregroundColor(quiet ? .secondary : .primary)
    }
}

/// A row's icon: a 16pt glyph, secondary.
struct InspectorRowIcon: View {
    let symbol: String
    var style: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        Image(systemName: symbol)
            .font(.toasty(Theme.Size.control))
            .foregroundStyle(style)
    }
}

// MARK: - Marks

/// A file's change as a letter in a 16pt square: neutral (the letter, not
/// its color, says what happened).
struct ChangeLetter: View {
    let status: GitChanges.Status

    var body: some View {
        Text(status.mark)
            .font(.toasty(10, .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: Theme.Todo.box, height: Theme.Todo.box)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.Fill.subtle))
            .accessibilityLabel(status.label)
    }
}

/// Lines added and removed: mono 12, the soft heading green and pink.
struct DiffCounts: View {
    let added: Int?
    let removed: Int?
    /// Show "+0" / "−0" rather than leaving a side out.
    var showZero = false

    var body: some View {
        HStack(spacing: 6) {
            if let added, added > 0 || showZero {
                Text("+\(added)").foregroundStyle(Theme.Inspector.added)
            }
            if let removed, removed > 0 || showZero {
                Text("−\(removed)").foregroundStyle(Theme.Inspector.removed)
            }
        }
        .font(.toasty(Theme.Size.meta, design: .monospaced))
        .fixedSize()
    }
}

/// A small label in a rounded box: 18 tall, 11 medium, secondary.
struct InspectorChip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.toasty(Theme.Glyph.small, .semibold)) }
            Text(text).font(.toasty(Theme.Size.caption, .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.Fill.subtle))
    }
}

// MARK: - Meter

/// A label and its value over a 4pt bar: neutral, orange from 90%.
struct InspectorMeter: View {
    let title: String
    let value: String
    let fraction: Double
    /// Over the limit: orange whatever the fraction.
    var warns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(title)
                    .font(.toasty(Theme.Size.control))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text(value)
                    .font(.toasty(Theme.Size.meta))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(height: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Fill.subtle)
                    Capsule()
                        .fill(warns || fraction >= 0.9 ? AnyShapeStyle(StatusColor.needsInput) : AnyShapeStyle(.secondary))
                        .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, Theme.Inspector.edge)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((fraction * 100).rounded()))% used")
    }
}

// MARK: - Empty state

/// The one empty state: a 28pt light glyph, a 17 semibold title, one 13
/// line, centered in the space it's given.
struct InspectorEmpty: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Glyph.hero, .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.toasty(Theme.Size.title, .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Space.xs)
            if let detail {
                Text(detail)
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
