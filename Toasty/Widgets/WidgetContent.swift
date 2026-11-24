import AppKit
import SwiftUI

/// A widget's inside, by kind and size. Every widget follows the same
/// grammar (`WidgetSize`):
///
/// - **Small** (one track): a glance. One value, what it is, one footer
///   fact, bottom-aligned.
/// - **Medium** (two tracks, up to three units): a short list of rows, no
///   buttons.
/// - **Large** (two tracks, four units and up): a one-line summary, the
///   full list, and at most one action bar.
///
/// Heights between the presets show more rows, never another layout. Each
/// widget reads the workspace's state; the same widget on two spaces shows
/// the same thing.
struct WidgetContent: View {
    @ObservedObject var workspace: Workspace
    let item: WidgetItem
    /// Units it's drawn at.
    let units: Int
    /// Collapsed: its header alone.
    var headerOnly = false

    var body: some View {
        let size = WidgetSize(span: item.span, units: units)
        VStack(spacing: 0) {
            if item.collapsed || headerOnly {
                WidgetHeader(kind: item.kind)
            } else {
                switch item.kind {
                case .git: GitWidget(workspace: workspace, changes: workspace.changes, size: size)
                case .usage: UsageWidget(workspace: workspace, size: size, options: item.usage)
                case .teeUp: TeeUpWidget(workspace: workspace, size: size)
                case .activity: ActivityWidget(workspace: workspace, size: size)
                case .system: SystemWidget(workspace: workspace, item: item, size: size)
                case .files: FilesWidget(workspace: workspace, item: item)
                case .terminal: TerminalWidget(workspace: workspace, item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Small, Medium or Large, and how many rows a list has room for.
struct WidgetSize {
    enum Kind { case small, medium, large }
    let kind: Kind
    let units: Int

    init(span: Int, units: Int) {
        self.units = units
        kind = span == 1 ? .small : units >= 4 ? .large : .medium
    }

    /// Rows that fit under the header (and whatever else is `reserved`).
    func rows(reserving extra: CGFloat = 0) -> Int {
        let room = WidgetGrid.height(units) - WidgetGrid.headerHeight - Theme.Space.s - extra
        return max(1, Int(room / Theme.Widget.rowHeight))
    }

    /// Fit: the height a list of `count` rows takes at this size, with
    /// `above` (a summary line) and `below` (Git's commits) around it; an
    /// empty list's line takes two rows. Never taller than the size.
    func fitHeight(count: Int, above: CGFloat = 0, below: CGFloat = 0) -> CGFloat? {
        guard kind != .small else { return nil }
        let row = Theme.Widget.rowHeight
        let room = rows(reserving: above + below)
        let list = count == 0 ? row * 2 : count > room ? CGFloat(max(1, room - 1)) * row + 20 : CGFloat(count) * row
        return min(WidgetGrid.headerHeight + above + list + below + Theme.Space.s, WidgetGrid.height(units))
    }

    /// Fit: a header over measured content (nil, not measured yet).
    func fitHeight(content: CGFloat?, above: CGFloat = 0) -> CGFloat? {
        guard kind != .small, let content else { return nil }
        return min(WidgetGrid.headerHeight + above + content, WidgetGrid.height(units))
    }

    /// Fit: a header and a one-line message (not a repository, no conversation).
    var fitMessage: CGFloat? { fitHeight(count: 0) }
}

// MARK: - The kit every widget is built from

/// The body of a Small: one value (a number or a word, or the Usage ring),
/// what it is, and one footer fact, bottom-aligned on the 14pt edge.
struct WidgetGlance<Value: View, Footer: View>: View {
    @ViewBuilder var value: () -> Value
    var caption: () -> String
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer(minLength: 0)
            value()
            Text(caption())
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            footer()
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Space.xs)
        }
        .padding(.horizontal, Theme.Widget.edge)
        .padding(.bottom, Theme.Space.m + 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// A Small's value: a number or a word.
struct GlanceValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.display, .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// The one row every list uses: a leading mark (none for an `EmptyView`:
/// the label then starts on the widget's edge), a label (and a quieter
/// detail after it), and a trailing value.
struct WidgetRow<Lead: View, Trailing: View>: View {
    let label: String
    var detail: String?
    var mono = false
    var quiet = false
    /// Middle for file names; tail for sentences (a commit's subject).
    var truncation: Text.TruncationMode = .middle
    var action: (() -> Void)?
    @ViewBuilder var lead: () -> Lead
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if Lead.self != EmptyView.self { lead().frame(width: Theme.Todo.box) }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs + Theme.Space.xxs) {
                Text(label)
                    .font(mono ? .toasty(Theme.Size.meta, design: .monospaced) : .toasty(Theme.Size.control))
                    .foregroundStyle(quiet ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(truncation)
                    .layoutPriority(1)
                if let detail {
                    Text(detail)
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            trailing()
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Widget.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(hovering && action != nil ? Theme.Fill.hover : Color.clear))
        .padding(.horizontal, Theme.Widget.rowInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
    }
}

/// A row's glyph, quiet.
struct RowGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.toasty(Theme.Size.meta))
            .foregroundStyle(.secondary)
    }
}

/// A row's (or a header's) value: mono 12, secondary.
struct RowValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.meta, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// "+2 more", under a list cut short.
private struct MoreLine: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count) more")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.Widget.edge)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
    }
}

/// A list with nothing in it: one plain line in the widget's own voice.
struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.control))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Widget.edge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Large's one-line summary, under its header.
struct SummaryLine<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing

    static var height: CGFloat { 28 }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(text)
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            trailing()
        }
        .padding(.horizontal, Theme.Widget.edge)
        .frame(height: Self.height)
    }
}

extension SummaryLine where Trailing == EmptyView {
    init(text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// A list cut to the rows there's room for, and how many more there are.
private func cut<T>(_ list: [T], to room: Int) -> (shown: ArraySlice<T>, more: Int) {
    guard list.count > room else { return (list[...], 0) }
    // Room for the "more" line too.
    let shown = max(1, room - 1)
    return (list.prefix(shown), list.count - shown)
}

// MARK: - Git

private struct GitWidget: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var changes: GitChanges
    let size: WidgetSize

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(kind: .git) { status }
            content
        }
        .reportsFit(Self.fittedHeight(changes, size: size), workspace: workspace.id)
        // Kept current while it's on screen: git status is cheap and
        // takes no locks. Also right after each turn (ClaudeConversation).
        .task(id: workspace.folder) {
            changes.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if NSApp.isActive { changes.refresh() }
            }
        }
    }

    /// The header's status: the branch and its arrows; in Large, whether
    /// it's pushed (the branch is in the summary).
    @ViewBuilder private var status: some View {
        if changes.state == .loaded {
            if size.kind == .large {
                if let sync = syncText { InspectorChip(text: sync) }
            } else if size.kind == .medium {
                BranchLabel(changes: changes)
            }
        }
    }

    private var syncText: String? {
        guard changes.branch != nil else { return nil }
        if changes.upstream == nil { return "Not Pushed" }
        if changes.ahead > 0 { return "\(changes.ahead) to Push" }
        if changes.behind > 0 { return "\(changes.behind) to Pull" }
        return "Pushed"
    }

    @ViewBuilder private var content: some View {
        switch changes.state {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository:
            EmptyLine(text: "Not a git repository")
        case .failed:
            EmptyLine(text: "Couldn't read git")
        case .loaded:
            switch size.kind {
            case .small: small
            case .medium: list(room: size.rows())
            case .large: large
            }
        }
    }

    private var small: some View {
        WidgetGlance {
            GlanceValue(text: "\(changes.files.count)")
        } caption: {
            changes.files.count == 1 ? "file changed" : "files changed"
        } footer: {
            HStack(spacing: Theme.Space.xs) {
                Text(changes.branch ?? "detached").font(.toasty(Theme.Size.meta, design: .monospaced))
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                if !changes.files.isEmpty {
                    DiffCounts(added: changes.totalAdded, removed: changes.totalRemoved)
                }
            }
        }
    }

    /// The changed files, as rows (a click shows the diff).
    @ViewBuilder private func list(room: Int) -> some View {
        if changes.files.isEmpty {
            EmptyLine(text: "No changes")
        } else {
            let (shown, more) = cut(changes.files, to: room)
            VStack(spacing: 0) {
                ForEach(shown) { file in
                    GitFileRow(workspace: workspace, file: file)
                }
                MoreLine(count: more)
                Spacer(minLength: 0)
            }
        }
    }

    private var large: some View {
        VStack(spacing: 0) {
            SummaryLine(text: summary) {
                HStack(spacing: Theme.Space.xxs) {
                    InspectorControl(symbol: "arrow.down",
                                     tooltip: Tooltip(title: "Pull", detail: "Bring in the remote's commits (fast-forward only).")) {
                        changes.pull()
                    }
                    .disabled(changes.busy != nil || changes.upstream == nil)
                    InspectorControl(symbol: "arrow.up",
                                     tooltip: Tooltip(title: "Push", detail: changes.upstream == nil
                                                      ? "Put this branch on origin." : "Send this branch's commits to \(changes.upstream ?? "its remote").")) {
                        changes.push()
                    }
                    .disabled(changes.busy != nil || changes.branch == nil)
                }
            }
            // The commits take up to half the rows (at least 3), the files the rest.
            let room = max(3, size.rows(reserving: SummaryLine<EmptyView>.height) / 2)
            list(room: size.rows(reserving: SummaryLine<EmptyView>.height
                                 + UnpushedList.height(changes.unpushedCount, room: room)))
            UnpushedList(changes: changes, room: room)
        }
    }

    /// Fit: how tall it needs to be to show what it has (loading: small,
    /// so it grows into its list rather than shrinking onto it).
    static func fittedHeight(_ changes: GitChanges, size: WidgetSize) -> CGFloat? {
        switch changes.state {
        case .loading, .notRepository, .failed: return size.fitMessage
        case .loaded: break
        }
        switch size.kind {
        case .small: return nil
        case .medium: return size.fitHeight(count: changes.files.count)
        case .large:
            let summary = SummaryLine<EmptyView>.height
            let room = max(3, size.rows(reserving: summary) / 2)
            let unpushed = changes.unpushed.isEmpty ? 0 : UnpushedList.height(changes.unpushedCount, room: room)
            return size.fitHeight(count: changes.files.count, above: summary, below: unpushed)
        }
    }

    /// The branch and how it stands with its remote; what's under way, or
    /// what went wrong.
    private var summary: String {
        if let busy = changes.busy { return busy }
        if let error = changes.actionError { return error }
        let branch = changes.branch ?? "Detached HEAD"
        guard let upstream = changes.upstream else { return "\(branch) · not on a remote yet" }
        var parts: [String] = []
        if changes.ahead > 0 { parts.append("\(changes.ahead) ahead") }
        if changes.behind > 0 { parts.append("\(changes.behind) behind") }
        return parts.isEmpty ? "\(branch) · up to date with \(upstream)" : "\(branch) · " + parts.joined(separator: ", ") + " of \(upstream)"
    }
}

/// The commits a push would send, under a heading at a Large's bottom,
/// below a hairline; nothing when there are none. (Committing is left to Claude.)
private struct UnpushedList: View {
    @ObservedObject var changes: GitChanges
    /// At most this many rows, the last one "+N more" when there are more.
    let room: Int

    static let padding = Theme.Space.xs

    /// Its height for `count` commits, for the files above to leave room.
    static func height(_ count: Int, room: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = min(count, room)
        let more: CGFloat = count > room ? 20 - Theme.Widget.rowHeight : 0
        return 1 + padding * 2 + SummaryLine<EmptyView>.height + CGFloat(rows) * Theme.Widget.rowHeight + more
    }

    var body: some View {
        let count = changes.unpushedCount
        if count > 0, !changes.unpushed.isEmpty {
            let shown = changes.unpushed.prefix(count > room ? room - 1 : room)
            VStack(spacing: 0) {
                SummaryLine(text: "Commits to Push").accessibilityAddTraits(.isHeader)
                ForEach(shown) { commit in
                    WidgetRow(label: commit.subject, truncation: .tail) {
                        EmptyView()
                    } trailing: {
                        RowValue(text: commit.hash)
                    }
                    .tooltip(Tooltip(title: commit.subject, detail: "\(commit.hash) · committed "
                                     + ActivityTab.ago(Date().timeIntervalSince(commit.date)) + ", not pushed yet"))
                }
                MoreLine(count: count - shown.count)
            }
            .padding(.vertical, Self.padding)
            .overlay(alignment: .top) { Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1) }
        }
    }
}

/// The branch with its arrows ("main ↑1"), mono.
private struct BranchLabel: View {
    @ObservedObject var changes: GitChanges

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "arrow.triangle.branch").font(.toasty(Theme.Glyph.small + 1)).foregroundStyle(.tertiary)
            Text(changes.branch ?? "detached").font(.toasty(Theme.Size.meta, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if changes.ahead > 0 {
                Text("↑\(changes.ahead)").font(.toasty(Theme.Size.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
            if changes.behind > 0 {
                Text("↓\(changes.behind)").font(.toasty(Theme.Size.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// A changed file: its letter, name and folder, line counts; a click shows
/// its diff in the conversation column.
private struct GitFileRow: View {
    @ObservedObject var workspace: Workspace
    let file: GitChanges.File

    var body: some View {
        let selected = workspace.diffFile?.id == file.id
        let deleted = file.status == .deleted
        WidgetRow(label: file.name, detail: file.directory.isEmpty ? nil : file.directory, quiet: deleted,
                  action: { workspace.diffFile = selected ? nil : file }) {
            ChangeLetter(status: file.status)
        } trailing: {
            if file.added == nil && file.removed == nil {
                RowValue(text: "binary")
            } else {
                DiffCounts(added: file.added, removed: file.removed)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(selected ? Theme.Fill.selected : Color.clear)
            .padding(.horizontal, Theme.Widget.rowInset))
        .tooltipText("\(file.status.label): \(file.path)")
        .contextMenu {
            Button(selected ? "Hide Diff" : "Show Diff") { workspace.diffFile = selected ? nil : file }
            Divider()
            Button("Open") { NSWorkspace.shared.open(file.url) }.disabled(deleted)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }.disabled(deleted)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
    }
}

// MARK: - Usage

private struct UsageWidget: View {
    @ObservedObject var workspace: Workspace
    let size: WidgetSize
    let options: UsageOptions

    var body: some View {
        if let c = workspace.selected {
            UsageContent(conversation: c, size: size, options: options).id(c.id)
        } else {
            VStack(spacing: 0) {
                WidgetHeader(kind: .usage)
                EmptyLine(text: "No conversation")
            }
        }
    }
}

private struct UsageContent: View {
    @ObservedObject var conversation: ClaudeConversation
    let size: WidgetSize
    let options: UsageOptions

    private var fraction: Double? {
        guard let c = conversation.context else { return nil }
        return c.maxTokens > 0 ? Double(c.totalTokens) / Double(c.maxTokens) : c.percentage / 100
    }

    private var tokens: String {
        guard let c = conversation.context else { return "Not measured yet" }
        return "\(Self.k(c.totalTokens)) of \(Self.k(c.maxTokens))"
    }

    /// The meters: the context window, then the plan's limits.
    private var meters: [Meter] {
        var out: [Meter] = []
        if let fraction { out.append(Meter(id: "context", title: "Context", fraction: fraction, value: tokens)) }
        for l in conversation.rateLimits where l.utilization != nil || l.status == "rejected" {
            let resets = l.resetsAt.map { r in
                "resets " + r.formatted(r.timeIntervalSinceNow < 86_400 ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated))
            }
            out.append(Meter(id: l.id, title: l.title, fraction: l.utilization ?? 1,
                             value: resets ?? "", warns: l.status == "rejected"))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(kind: .usage)
            switch size.kind {
            case .small: small
            case .medium: meterList(room: max(1, Int((WidgetGrid.height(size.units) - WidgetGrid.headerHeight) / MeterRow.height)))
            case .large: large
            }
        }
        .onAppear { conversation.refreshContextUsage() }
    }

    /// One value, as its options say: how full the context window is, or
    /// a plan limit (as a ring or a number).
    private var small: some View {
        let limit = options.glance.limitType.flatMap { t in conversation.rateLimits.first { $0.type == t } }
        let value: Double? = options.glance == .context ? fraction
            : limit.flatMap { $0.utilization ?? ($0.status == "rejected" ? 1 : nil) }
        let caption = limit?.title ?? (options.glance == .session ? "Current Session" : options.glance == .week ? "This Week" : "Context")
        let footer: String = switch options.glance {
        case .context: tokens
        case .session, .week: limit?.resetsAt.map { Self.resets($0) } ?? "Not measured yet"
        }
        return WidgetGlance {
            if options.style == .ring {
                ContextRing(fraction: value, name: caption)
                    .padding(.bottom, Theme.Space.xs)
            } else {
                GlanceValue(text: value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            }
        } caption: {
            caption
        } footer: {
            Text(footer).monospacedDigit()
        }
    }

    private static func resets(_ r: Date) -> String {
        "resets " + r.formatted(r.timeIntervalSinceNow < 86_400 ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated))
    }

    @ViewBuilder private func meterList(room: Int) -> some View {
        if meters.isEmpty {
            EmptyLine(text: "Shows after Claude's first reply")
        } else {
            VStack(spacing: 0) {
                ForEach(meters.prefix(room)) { MeterRow(meter: $0) }
                Spacer(minLength: 0)
            }
        }
    }

    private var large: some View {
        VStack(spacing: 0) {
            SummaryLine(text: "This conversation" + (conversation.usage.map { " · \(Self.k($0.inputTokens + $0.outputTokens)) tokens" } ?? ""))
            ForEach(meters) { MeterRow(meter: $0) }
            if let c = conversation.context {
                // What fills the context, largest first.
                let used = c.categories.filter { $0.kind == "used" && $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
                let room = max(0, Int((WidgetGrid.height(size.units) - WidgetGrid.headerHeight - SummaryLine<EmptyView>.height
                                       - CGFloat(meters.count) * MeterRow.height - Theme.Space.s) / Theme.Widget.rowHeight))
                ForEach(used.prefix(room)) { cat in
                    WidgetRow(label: cat.name) {
                        Circle().fill(Color.primary.opacity(0.3)).frame(width: 5, height: 5)
                    } trailing: {
                        RowValue(text: Self.k(cat.tokens))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    static func k(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1000...: "\(Int((Double(n) / 1000).rounded()))K"
        default: "\(n)"
        }
    }
}

struct Meter: Identifiable {
    let id: String
    let title: String
    let fraction: Double
    let value: String
    var warns = false
}

/// A meter: its name, how full (and what that means) at the right, a thin
/// bar under them.
struct MeterRow: View {
    let meter: Meter
    static let height: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(meter.title).font(.toasty(Theme.Size.control)).lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if !meter.value.isEmpty {
                    Text(meter.value).font(.toasty(Theme.Size.meta)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text("\(Int((meter.fraction * 100).rounded()))%")
                    .font(.toasty(Theme.Size.meta, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Fill.selected)
                    Capsule().fill(meter.warns || meter.fraction >= 0.9 ? StatusColor.needsInput : Color.accentColor)
                        .frame(width: max(meter.fraction > 0 ? 3 : 0, geo.size.width * min(1, max(0, meter.fraction))))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, Theme.Widget.edge)
        .frame(height: Self.height)
    }
}

/// A ring for how full something is (the context window, or a System
/// widget's metric): the accent, orange past 90%.
struct ContextRing: View {
    let fraction: Double?
    /// What it measures, for VoiceOver.
    var name = "Context"
    var size: CGFloat = 52
    var lineWidth: CGFloat = 6

    var body: some View {
        let f = min(1, max(0, fraction ?? 0))
        ZStack {
            Circle().stroke(Theme.Fill.selected, lineWidth: lineWidth)
            Circle().trim(from: 0, to: f)
                .stroke(f >= 0.9 ? StatusColor.needsInput : Color.accentColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.toasty(Theme.Size.control, .semibold)).monospacedDigit()
        }
        .frame(width: size - lineWidth, height: size - lineWidth)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "not measured")")
    }
}

// MARK: - Tee-Up

private struct TeeUpWidget: View {
    @ObservedObject var workspace: Workspace
    let size: WidgetSize

    /// Auto-Send, in a few words.
    private var sending: String {
        guard let feed = workspace.teeUpFeed else { return "Auto-send off" }
        if feed.paused != nil { return "Auto-send paused" }
        if let next = feed.nextAt { return "Next " + next.formatted(.relative(presentation: .named)) }
        return "Auto-sending"
    }

    /// Large: the queue's height as laid out (cards open to edit).
    @State private var queueHeight: CGFloat?

    private var fit: CGFloat? {
        switch size.kind {
        case .small: nil
        case .medium: size.fitHeight(count: workspace.teeUps.count)
        // (Until it's laid out: its prompts and New Prompt, as rows.)
        case .large: size.fitHeight(content: queueHeight, above: SummaryLine<EmptyView>.height)
            ?? size.fitHeight(count: workspace.teeUps.count + 1, above: SummaryLine<EmptyView>.height)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if size.kind == .large {
                // The full queue, written and sent from here.
                WidgetHeader(kind: .teeUp)
                SummaryLine(text: workspace.teeUps.isEmpty ? "Nothing teed up"
                                : "\(workspace.teeUps.count) teed up · \(sending)") { feedControls }
                TeeUpTab(workspace: workspace, compact: true, contentHeight: { queueHeight = $0 }).id(workspace.id)
            } else {
                WidgetHeader(kind: .teeUp) {
                    if size.kind == .medium { Text(sending).font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary) }
                }
                if size.kind == .small {
                    WidgetGlance {
                        GlanceValue(text: "\(workspace.teeUps.count)")
                    } caption: {
                        "teed up"
                    } footer: {
                        Text(sending)
                    }
                } else if workspace.teeUps.isEmpty {
                    EmptyLine(text: "Nothing teed up")
                } else {
                    let (shown, more) = cut(workspace.teeUps, to: size.rows())
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                            WidgetRow(label: Self.line(t), quiet: t.isHeld) {
                                RowValue(text: "\(i + 1)")
                            } trailing: {
                                if t.isHeld { RowGlyph(symbol: "pause") }
                            }
                        }
                        MoreLine(count: more)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .reportsFit(fit, workspace: workspace.id)
    }

    /// Auto-Send: start it; pause or stop it; resume or stop it.
    @ViewBuilder private var feedControls: some View {
        HStack(spacing: Theme.Space.xxs) {
            if let feed = workspace.teeUpFeed {
                if feed.paused != nil {
                    InspectorControl(symbol: "play.fill", tooltip: Tooltip(title: "Resume Auto-Send")) { workspace.resumeTeeUpFeed() }
                } else {
                    InspectorControl(symbol: "pause.fill", tooltip: Tooltip(title: "Pause Auto-Send")) { workspace.pauseTeeUpFeed() }
                }
                InspectorControl(symbol: "stop.fill", tooltip: Tooltip(title: "Stop Auto-Send")) { workspace.stopTeeUpFeed() }
            } else {
                InspectorControl(symbol: "play.fill",
                                 tooltip: Tooltip(title: "Auto-Send", detail: "Send each prompt to the open tab when Claude finishes the one before.")) {
                    workspace.startTeeUpFeed()
                }
                .disabled(workspace.teeUps.isEmpty)
            }
        }
    }

    /// A prompt's first line.
    static func line(_ t: TeeUp) -> String {
        let first = t.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.isEmpty ? (t.images.isEmpty && t.files.isEmpty ? "Empty prompt" : "Attachment") : first
    }
}

// MARK: - Activity

private struct ActivityWidget: View {
    @ObservedObject var workspace: Workspace
    let size: WidgetSize

    var body: some View {
        if let c = workspace.selected {
            ActivityContent(conversation: c, size: size, workspace: workspace.id).id(c.id)
        } else {
            VStack(spacing: 0) {
                WidgetHeader(kind: .activity)
                EmptyLine(text: "No conversation")
            }
            .reportsFit(size.fitMessage, workspace: workspace.id)
        }
    }
}

private struct ActivityContent: View {
    @ObservedObject var conversation: ClaudeConversation
    let size: WidgetSize
    /// Its workspace, for Fit's report.
    let workspace: UUID

    var body: some View {
        content
            .reportsFit(size.fitHeight(count: conversation.runningTools.count + conversation.backgroundTasks.count,
                                       above: size.kind == .large ? SummaryLine<EmptyView>.height : 0),
                        workspace: workspace)
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                WidgetHeader(kind: .activity) {
                    if size.kind != .small, let clock = clock(ctx.date) { RowValue(text: clock) }
                }
                switch size.kind {
                case .small:
                    WidgetGlance {
                        HStack(spacing: Theme.Space.s) {
                            StatusDot(color: dot)
                            GlanceValue(text: state)
                        }
                    } caption: {
                        clock(ctx.date) ?? caption
                    } footer: {
                        Text(step ?? lastTurn(ctx.date))
                    }
                case .medium:
                    list(room: size.rows(), now: ctx.date)
                case .large:
                    SummaryLine(text: "\(state) · \(step ?? lastTurn(ctx.date))")
                    list(room: size.rows(reserving: SummaryLine<EmptyView>.height), now: ctx.date)
                }
            }
        }
    }

    /// What's running now, then in the background; each with its time.
    @ViewBuilder private func list(room: Int, now: Date) -> some View {
        let rows = self.rows(now: now)
        if rows.isEmpty {
            EmptyLine(text: conversation.phase == .working ? "Thinking…" : "Nothing running")
        } else {
            let (shown, more) = cut(rows, to: room)
            VStack(spacing: 0) {
                ForEach(shown) { r in
                    WidgetRow(label: r.label, mono: r.mono, quiet: r.background) {
                        RowGlyph(symbol: r.symbol)
                    } trailing: {
                        RowValue(text: r.time)
                    }
                }
                MoreLine(count: more)
                Spacer(minLength: 0)
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let time: String
        var mono = false
        var background = false
    }

    private func rows(now: Date) -> [Row] {
        var out: [Row] = conversation.runningTools.map { item in
            let summary = ClaudeToolInfo.summary(item.toolName, item.input, cwd: conversation.cwd)
            let seconds = item.started.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
            return Row(id: "\(item.id)", symbol: ClaudeToolInfo.icon(item.toolName),
                       label: item.toolName == "Bash" && !summary.isEmpty ? summary
                           : ClaudeToolInfo.activeVerb(item.toolName) + (summary.isEmpty ? "" : " " + summary),
                       time: ClaudeToolInfo.duration(seconds), mono: item.toolName == "Bash")
        }
        out += conversation.backgroundTasks.map { task in
            Row(id: task.id, symbol: "clock.arrow.circlepath",
                label: task.description.isEmpty ? task.type : task.description,
                time: ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(task.started)))), background: true)
        }
        return out
    }

    private var state: String {
        if !conversation.requests.isEmpty { return "Waiting" }
        switch conversation.phase {
        case .starting: return "Starting"
        case .working: return "Working"
        case .idle: return conversation.stopped != nil ? "Stopped" : "Idle"
        }
    }

    private var dot: Color {
        if !conversation.requests.isEmpty { return StatusColor.needsInput }
        switch conversation.phase {
        case .starting, .working: return Color.accentColor
        case .idle: return conversation.stopped != nil ? StatusColor.stopped : Theme.Sidebar.restDot
        }
    }

    private var caption: String {
        if !conversation.requests.isEmpty { return "needs you" }
        return conversation.phase == .idle ? "ready" : "on this turn"
    }

    /// The running turn's clock.
    private func clock(_ now: Date) -> String? {
        guard conversation.phase == .working, let started = conversation.turnStarted else { return nil }
        return ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(started))))
    }

    /// The step under way, in a few words.
    private var step: String? {
        if let request = conversation.requests.first { return request.summary }
        guard conversation.phase == .working else { return nil }
        if let item = conversation.runningTools.first {
            let summary = ClaudeToolInfo.summary(item.toolName, item.input, cwd: conversation.cwd)
            return ClaudeToolInfo.activeVerb(item.toolName) + (summary.isEmpty ? "" : " " + summary)
        }
        return conversation.status ?? "Thinking…"
    }

    private func lastTurn(_ now: Date) -> String {
        guard let last = conversation.items.last(where: { $0.endsTurn && $0.finishedAt != nil }),
              let finished = last.finishedAt else { return "No turns yet" }
        return "Last turn " + ActivityTab.ago(now.timeIntervalSince(finished))
    }
}

// MARK: - Terminal (the dock's)

/// The terminal's own background, behind its view.
struct TerminalBackdrop: View {
    var body: some View {
        Color(nsColor: NSColor(name: nil) { a in
            NSColor(cgColor: TerminalTheme.current(for: a).background.cgColor) ?? .windowBackgroundColor
        })
    }
}

/// Hosts a terminal session's view. A session's view lives in one place:
/// the host that last showed it takes it.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalHostView {
        let v = TerminalHostView()
        v.show(session)
        return v
    }

    func updateNSView(_ v: TerminalHostView, context: Context) {
        if v.shownID != session.id { v.show(session) }
    }
}

final class TerminalHostView: NSView {
    private(set) var shownID: UUID?

    func show(_ session: TerminalSession) {
        shownID = session.id
        for sub in subviews { sub.removeFromSuperview() }
        let v = session.view
        let focused = v.window?.firstResponder === session.terminalView
        v.removeFromSuperview()
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        v.translatesAutoresizingMaskIntoConstraints = true
        addSubview(v)
        if focused { DispatchQueue.main.async { v.window?.makeFirstResponder(session.terminalView) } }
    }
}

