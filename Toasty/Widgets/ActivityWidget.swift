import SwiftUI

/// What the selected conversation's Claude is waiting on, for how long,
/// and whether it's still alive: what the conversation doesn't show on a
/// long run. Not the state word or the turn's clock and tokens (the
/// sidebar and the working line have those).
///
/// - **Small:** how long the current step has run, what it is, and a
///   pulse with when Claude was last heard from.
/// - **Slim:** the step and its time over a two-minute heartbeat: a tick
///   for each second Claude was heard from. A flat stretch is silence.
/// - **Medium:** what's running, each with its time; an agent shows what
///   its subagent is doing.
/// - **Large:** the heartbeat, then what's running with each agent's
///   steps under it, and what's in the background.
struct ActivityWidget: View {
    @ObservedObject var workspace: Workspace
    let size: WidgetSize

    var body: some View {
        if let c = workspace.selected {
            ActivityContent(conversation: c, activity: c.activity, size: size, workspace: workspace.id).id(c.id)
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
    @ObservedObject var activity: ClaudeTurnActivity
    let size: WidgetSize
    /// Its workspace, for Fit's report.
    let workspace: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = ctx.date
            VStack(spacing: 0) {
                if size.slim {
                    WidgetHeader(kind: .activity) { Liveness(life: life(now)) }
                    slim(now)
                } else {
                    switch size.kind {
                    case .small:
                        WidgetHeader(kind: .activity)
                        small(now)
                    case .medium:
                        WidgetHeader(kind: .activity) { Liveness(life: life(now)) }
                        list(room: size.rows(), now: now)
                    case .large:
                        WidgetHeader(kind: .activity) { Liveness(life: life(now)) }
                        // The heartbeat while a turn runs (idle, it's flat).
                        if working {
                            HeartbeatTrace(seconds: activity.heardSeconds, now: now, live: true)
                                .frame(height: 10)
                                .padding(.horizontal, Theme.Widget.edge)
                                .frame(height: Self.heartbeatRow)
                        }
                        list(room: size.rows(reserving: working ? Self.heartbeatRow : 0), now: now)
                    }
                }
            }
        }
        .reportsFit(size.fitHeight(count: rows(now: .now).count,
                                   above: size.kind == .large && working ? Self.heartbeatRow : 0),
                    workspace: workspace)
    }

    static let heartbeatRow: CGFloat = 28

    private var working: Bool { conversation.phase == .working }

    // MARK: Is it alive?

    /// Whether Claude Code is being heard from: the evidence for "it's not
    /// hung", in the header (Small: its footer).
    struct Life: Equatable {
        enum Kind { case live, quiet, idle }
        let kind: Kind
        /// Heard within the last second and a half: the pulse is lit.
        let fresh: Bool
        let text: String
    }

    private func life(_ now: Date) -> Life {
        guard conversation.phase == .working else {
            return Life(kind: .idle, fresh: false, text: "")
        }
        let silence = ActivityTab.silence(conversation, now: now)
        if silence >= ActivityTab.quietAfter {
            return Life(kind: .quiet, fresh: false, text: "Quiet \(ClaudeToolInfo.duration(Int(silence) / 60 * 60))")
        }
        return Life(kind: .live, fresh: silence < 1.5, text: silence < 5 ? "Heard just now" : "Heard \(ClaudeToolInfo.duration(Int(silence))) ago")
    }

    // MARK: What it's waiting on

    /// The one thing a Small or Slim shows: what's being waited on, how
    /// long, and in what color.
    private struct Focus {
        let value: String
        let caption: String
        var warns = false
        var stopped = false
    }

    private func focus(_ now: Date) -> Focus {
        func since(_ d: Date?) -> String { ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(d ?? now)))) }
        if let request = conversation.requests.first {
            return Focus(value: since(request.received), caption: "Waiting for you: \(request.summary)", warns: true)
        }
        switch conversation.phase {
        case .starting:
            return Focus(value: "—", caption: "Starting Claude Code")
        case .idle:
            if let stopped = conversation.stopped {
                return Focus(value: "Stopped", caption: "Claude Code ended \(ActivityTab.ago(now.timeIntervalSince(stopped.date)))",
                             stopped: true)
            }
            guard let last = conversation.items.last(where: { $0.endsTurn && $0.finishedAt != nil }),
                  let finished = last.finishedAt else { return Focus(value: "Ready", caption: "No turns yet") }
            let ended = "Ended \(ActivityTab.ago(now.timeIntervalSince(finished)))"
            if let took = last.turnDuration {
                return Focus(value: ClaudeToolInfo.duration(took), caption: "Last turn · \(ended.lowercased())")
            }
            return Focus(value: "Ready", caption: ended)
        case .working:
            if let tool = conversation.runningTools.first {
                return Focus(value: since(tool.started), caption: Self.label(tool, cwd: conversation.cwd))
            }
            let what = switch activity.step {
            case .thinking: "Thinking"
            case .writing: "Writing"
            // Between messages, nothing running: the next reply is on its way.
            case .working: "Waiting on the model"
            }
            return Focus(value: since(activity.stepStarted), caption: what)
        }
    }

    /// "Running npm test", "Agent: Audit callers of SyncQueue".
    static func label(_ tool: ClaudeItem, cwd: String) -> String {
        let summary = ClaudeToolInfo.summary(tool.toolName, tool.input, cwd: cwd)
        if isAgent(tool) { return summary.isEmpty ? "Agent" : "Agent: \(summary)" }
        return ClaudeToolInfo.activeVerb(tool.toolName) + (summary.isEmpty ? "" : " " + summary)
    }

    /// A list row's label: a command as typed, an agent's task (its glyph
    /// says it's an agent), other steps as `label`.
    static func rowLabel(_ tool: ClaudeItem, cwd: String) -> String {
        let summary = ClaudeToolInfo.summary(tool.toolName, tool.input, cwd: cwd)
        if tool.toolName == "Bash", !summary.isEmpty { return summary }
        if isAgent(tool), !summary.isEmpty { return summary }
        return label(tool, cwd: cwd)
    }

    static func isAgent(_ tool: ClaudeItem) -> Bool { tool.toolName == "Task" || tool.toolName == "Agent" }

    private var background: String? {
        let n = conversation.backgroundTasks.count
        return n == 0 ? nil : "\(n) in background"
    }

    // MARK: Small

    private func small(_ now: Date) -> some View {
        let f = focus(now)
        let l = life(now)
        return WidgetGlance {
            GlanceValue(text: f.value)
                .foregroundStyle(f.warns ? AnyShapeStyle(StatusColor.needsInput)
                                 : f.stopped ? AnyShapeStyle(StatusColor.stopped) : AnyShapeStyle(.primary))
        } caption: {
            f.caption
        } footer: {
            if l.kind == .idle {
                Text(background ?? " ")
            } else {
                Liveness(life: l)
            }
        }
    }

    // MARK: Slim

    private func slim(_ now: Date) -> some View {
        let f = focus(now)
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(f.caption)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(f.warns ? AnyShapeStyle(StatusColor.needsInput) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.xs)
                if let background { Text(background).font(.toasty(Theme.Size.meta)).foregroundStyle(.tertiary).lineLimit(1) }
                Text(f.value).font(.toasty(Theme.Size.meta, design: .monospaced)).foregroundStyle(.secondary)
            }
            HeartbeatTrace(seconds: activity.heardSeconds, now: now, live: conversation.phase == .working)
                .frame(height: 6)
        }
        .padding(.horizontal, Theme.Widget.edge)
        .padding(.bottom, Theme.Widget.edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: Medium and Large

    /// What's waiting, then what's running (each agent with its subagent's
    /// steps under it: on Medium the one it's on, on Large a few),
    /// then the background.
    @ViewBuilder private func list(room: Int, now: Date) -> some View {
        let rows = self.rows(now: now)
        if rows.isEmpty {
            let f = focus(now)
            EmptyLine(text: conversation.phase == .working ? "\(f.caption) · \(f.value)" : "Nothing running")
        } else {
            let (shown, more) = cut(rows, to: room)
            VStack(spacing: 0) {
                ForEach(shown) { r in
                    WidgetRow(label: r.label, detail: r.detail, mono: r.mono, quiet: r.quiet, indent: r.indent) {
                        RowGlyph(symbol: r.symbol)
                            .foregroundStyle(r.warns ? AnyShapeStyle(StatusColor.needsInput) : AnyShapeStyle(.secondary))
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
        var detail: String?
        let time: String
        var mono = false
        var quiet = false
        var warns = false
        var indent: CGFloat = 0
    }

    private func rows(now: Date) -> [Row] {
        func since(_ d: Date?) -> String { ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(d ?? now)))) }
        let cwd = conversation.cwd
        var out: [Row] = conversation.requests.map { r in
            Row(id: "request-\(r.id)", symbol: "hand.raised", label: "Waiting for you", detail: r.summary,
                time: since(r.received), warns: true)
        }
        for tool in conversation.runningTools {
            let agent = Self.isAgent(tool)
            let running = tool.children.filter { !$0.finalized }
            let current = running.last ?? tool.children.last
            out.append(Row(id: tool.id, symbol: ClaudeToolInfo.icon(tool.toolName), label: Self.rowLabel(tool, cwd: cwd),
                           time: since(tool.started), mono: tool.toolName == "Bash"))
            // Its subagent's steps under it. Medium: the one it's on.
            // Large: the last done, then what's running.
            if agent {
                let done = size.kind == .large ? Array(tool.children.filter(\.finalized).suffix(max(0, 2 - running.count))) : []
                let steps = size.kind == .large ? done + running : current.map { [$0] } ?? []
                for child in steps {
                    out.append(Row(id: child.id, symbol: ClaudeToolInfo.icon(child.toolName), label: Self.rowLabel(child, cwd: cwd),
                                   time: child.finalized ? "done" : since(child.started), mono: child.toolName == "Bash",
                                   quiet: child.finalized, indent: Theme.Space.l))
                }
            }
        }
        out += conversation.backgroundTasks.map { task in
            Row(id: task.id, symbol: "clock.arrow.circlepath",
                label: task.description.isEmpty ? task.type : task.description,
                time: since(task.started), quiet: true)
        }
        return out
    }
}

/// The pulse and when Claude was last heard from; orange once it's been
/// quiet for minutes. Nothing while idle.
private struct Liveness: View {
    let life: ActivityContent.Life

    var body: some View {
        switch life.kind {
        case .idle:
            EmptyView()
        case .live:
            HStack(spacing: Theme.Space.xs + 1) {
                Circle()
                    .fill(Color.accentColor.opacity(life.fresh ? 1 : 0.35))
                    .frame(width: StatusDot.size, height: StatusDot.size)
                    .animation(.easeOut(duration: 0.25), value: life.fresh)
                Text(life.text).font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        case .quiet:
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill").font(.toasty(Theme.Size.caption))
                Text(life.text + ", still running").font(.toasty(Theme.Size.meta)).lineLimit(1)
            }
            .foregroundStyle(StatusColor.needsInput)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The last two minutes, a tick for each second Claude Code was heard
/// from, newest at the right: steady ticks are a live turn, a flat stretch
/// is silence.
private struct HeartbeatTrace: View {
    let seconds: [Int]
    let now: Date
    /// A turn is running: ticks in the accent (gray otherwise).
    let live: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = ClaudeTurnActivity.heartbeatSeconds
            let end = Int(now.timeIntervalSince1970)
            let step = size.width / CGFloat(n)
            let baseline = Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2), cornerRadius: 1)
            ctx.fill(baseline, with: .color(Theme.Fill.selected))
            let tick = max(1.5, step * 0.55)
            let color = live ? Color.accentColor : Color.primary.opacity(0.3)
            for s in seconds where s > end - n && s <= end {
                let x = CGFloat(n - (end - s) - 1) * step + (step - tick) / 2
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: tick, height: size.height), cornerRadius: tick / 2),
                         with: .color(color))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heard from Claude in \(seconds.filter { $0 > Int(now.timeIntervalSince1970) - ClaudeTurnActivity.heartbeatSeconds }.count) of the last 120 seconds")
    }
}
