import SwiftUI

/// The inspector's Activity tab: whether the selected conversation's Claude
/// is alive and what it is doing, for long runs where the transcript alone
/// doesn't say. Laid out by how often each part matters: the status as one
/// large line at the top, then what is running (this turn's steps and the
/// background tasks, one list in Tee-Up's row measure), and at the bottom
/// what the conversation has used, as meters that open into the details.
/// Everything here is read from what Claude Code already sends; nothing is
/// asked of Claude.
struct ActivityTab: View {
    @ObservedObject var conversation: ClaudeConversation

    /// Silence from Claude Code for this long during a turn is called out.
    /// Streamed text and a running tool's heartbeat arrive every few
    /// seconds, so minutes of nothing is unusual; it isn't proof of a
    /// crash, and the tab doesn't say it is.
    static let quietAfter: TimeInterval = 180

    var body: some View {
        if conversation.phase == .idle, conversation.backgroundTasks.isEmpty,
           conversation.stopped == nil, lastTurn == nil, !UsageDock.hasUsage(conversation) {
            InspectorEmpty(symbol: InspectorTab.activity.symbol, title: "No Activity Yet",
                           detail: "What Claude is doing, and what it has used, shows here once it starts.")
                .onAppear { conversation.refreshContextUsage() }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            StatusHeader(conversation: conversation, activity: conversation.activity,
                                         lastTurn: lastTurn, now: context.date)
                            RunningList(conversation: conversation, activity: conversation.activity, now: context.date)
                        }
                        .padding(.horizontal, Theme.Inspector.edge)
                        .padding(.top, Theme.Space.m)
                        .padding(.bottom, Theme.Space.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    UsageDock(conversation: conversation)
                }
            }
            .onAppear { conversation.refreshContextUsage() }
        }
    }

    /// The reply that ended the last turn, if it carries when and how long.
    private var lastTurn: ClaudeItem? {
        conversation.items.last { $0.endsTurn && $0.finishedAt != nil }
    }

    /// How long Claude Code has said nothing in the running turn.
    static func silence(_ conversation: ClaudeConversation, now: Date) -> TimeInterval {
        let since = [conversation.activity.lastHeard, conversation.turnStarted].compactMap { $0 }.max()
        return since.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    static func ago(_ seconds: TimeInterval) -> String {
        seconds < 5 ? "just now" : ClaudeToolInfo.duration(Int(seconds)) + " ago"
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: "\(n / 1000)k"
        case 1000...: String(format: "%.1fk", Double(n) / 1000)
        default: "\(n)"
        }
    }
}

// MARK: - Status

/// The one line that answers "is Claude alive?": a mark, the state in the
/// panel's title size, the turn's clock at the right, and one quiet line
/// under it with the evidence.
private struct StatusHeader: View {
    @ObservedObject var conversation: ClaudeConversation
    @ObservedObject var activity: ClaudeTurnActivity
    let lastTurn: ClaudeItem?
    let now: Date

    private enum Health {
        case starting, working, waiting, quiet, idle, stopped
    }

    private var silence: TimeInterval { ActivityTab.silence(conversation, now: now) }

    private var health: Health {
        if !conversation.requests.isEmpty { return .waiting }
        switch conversation.phase {
        case .starting: return .starting
        case .working: return silence >= ActivityTab.quietAfter ? .quiet : .working
        case .idle: return conversation.stopped != nil ? .stopped : .idle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(alignment: .center, spacing: Theme.Todo.boxGap) {
                mark.frame(width: Theme.Todo.box, height: Theme.Todo.box)
                Text(title)
                    .font(.toasty(Theme.Size.title, .semibold))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                if let clock {
                    Text(clock)
                        .font(.toasty(Theme.Size.title))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(health == .quiet ? AnyShapeStyle(Color(nsColor: .systemOrange)) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Todo.box + Theme.Todo.boxGap)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch health {
        case .starting, .working:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .waiting:
            StatusDot(color: StatusColor.needsInput)
        case .quiet:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(Color(nsColor: .systemOrange))
        case .stopped:
            StatusDot(color: StatusColor.stopped)
        case .idle:
            StatusDot(color: Theme.Sidebar.restDot)
        }
    }

    private var title: String {
        switch health {
        case .starting: "Starting"
        case .working: "Working"
        case .waiting: "Waiting for You"
        case .quiet: "No Activity"
        case .stopped: "Stopped"
        case .idle: "Idle"
        }
    }

    /// The running turn's clock.
    private var clock: String? {
        guard conversation.phase == .working, let started = conversation.turnStarted else { return nil }
        return ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(started))))
    }

    private var detail: String? {
        switch health {
        case .starting:
            return "Claude Code is starting up."
        case .working:
            var parts = ["Heard from Claude \(ActivityTab.ago(silence))"]
            if activity.outputTokens > 0 { parts.append("\(ActivityTab.tokens(activity.outputTokens)) tokens written") }
            return parts.joined(separator: " · ")
        case .waiting:
            return conversation.requests.first?.summary
        case .quiet:
            return "Nothing from Claude Code for \(ClaudeToolInfo.duration(Int(silence) / 60 * 60)). It's still running, and may be on a slow step."
        case .stopped:
            guard let stopped = conversation.stopped else { return nil }
            let code = stopped.status != 0 ? " (exit \(stopped.status))" : ""
            return "Claude Code ended unexpectedly\(code) \(ActivityTab.ago(now.timeIntervalSince(stopped.date)))."
        case .idle:
            guard let lastTurn, let finished = lastTurn.finishedAt else { return "Ready for your next message." }
            let ended = "Last turn ended \(ActivityTab.ago(now.timeIntervalSince(finished)))"
            return lastTurn.turnDuration.map { "\(ended) · took \(ClaudeToolInfo.duration($0))" } ?? ended
        }
    }
}

// MARK: - Running

/// What is running: this turn's steps (each tool call with its clock, or
/// thinking / writing between calls), then the background tasks under a
/// quiet caption.
private struct RunningList: View {
    @ObservedObject var conversation: ClaudeConversation
    @ObservedObject var activity: ClaudeTurnActivity
    let now: Date

    var body: some View {
        let working = conversation.phase == .working
        let background = conversation.backgroundTasks
        if working || !background.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if working {
                    let running = conversation.runningTools
                    if running.isEmpty {
                        ActivityRow(symbol: symbol, title: Text(verb), tooltip: verb, detail: nil, time: nil)
                    } else {
                        ForEach(running) { item in
                            RunningTool(item: item, cwd: conversation.cwd, now: now)
                        }
                    }
                }
                if !background.isEmpty {
                    ActivityCaption(text: "In the Background")
                        .padding(.top, working ? Theme.Space.m : 0)
                    ForEach(background) { task in
                        BackgroundRow(task: task, now: now) { conversation.stopTask(task.id) }
                    }
                }
            }
            .padding(.top, Theme.Space.l)
        }
    }

    private var verb: String {
        if let status = conversation.status { return status }
        switch activity.step {
        case .thinking: return "Thinking…"
        case .writing: return "Writing…"
        case .working: return "Working…"
        }
    }

    private var symbol: String {
        if conversation.status != nil { return "arrow.triangle.2.circlepath" }
        switch activity.step {
        case .thinking: return "brain"
        case .writing: return "text.alignleft"
        case .working: return "ellipsis"
        }
    }
}

/// A small group label inside a panel: quieter than a heading, no rule.
private struct ActivityCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.toasty(Theme.Size.meta, .medium))
            .foregroundStyle(.tertiary)
            .frame(height: Theme.Inspector.rowHeight, alignment: .bottom)
            .padding(.bottom, Theme.Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct RunningTool: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    let now: Date

    var body: some View {
        let summary = ClaudeToolInfo.summary(item.toolName, item.input, cwd: cwd)
        let verb = ClaudeToolInfo.activeVerb(item.toolName)
        ActivityRow(symbol: ClaudeToolInfo.icon(item.toolName),
                    title: ActivityRow.title(verb: verb, summary: summary, code: item.toolName == "Bash"),
                    tooltip: summary.isEmpty ? verb : verb + " " + summary,
                    detail: subagentStep,
                    time: seconds.map { ClaudeToolInfo.duration($0) })
    }

    /// How long the call has run: Claude Code's own count when it sends
    /// one, else the time since the call appeared.
    private var seconds: Int? {
        let since = item.started.map { now.timeIntervalSince($0) }
        guard let longest = [since, item.elapsed].compactMap({ $0 }).max() else { return nil }
        return max(0, Int(longest))
    }

    /// For an agent, the step its subagent is on.
    private var subagentStep: String? {
        guard let child = item.children.last(where: { !$0.finalized }) ?? item.children.last else { return nil }
        let summary = ClaudeToolInfo.summary(child.toolName, child.input, cwd: cwd)
        let done = item.children.count - 1
        return ClaudeToolInfo.activeVerb(child.toolName) + (summary.isEmpty ? "" : " " + summary)
            + (done > 0 ? " · \(done) earlier \(done == 1 ? "step" : "steps")" : "")
    }
}

/// Work Claude Code keeps running outside the turn: shells, subagents,
/// monitors. Hover a row to stop it.
private struct BackgroundRow: View {
    let task: ClaudeConversation.BackgroundTask
    let now: Date
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        let text = task.description.isEmpty ? name : ClaudeBackgroundLine.short(task.description)
        ActivityRow(symbol: symbol,
                    title: Text(text).font(isShell ? .toasty(Theme.Size.control, design: .monospaced) : .toasty(Theme.Size.body)),
                    tooltip: text,
                    detail: nil,
                    time: hovering ? nil : ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(task.started)))))
            .overlay(alignment: .trailing) {
                if hovering {
                    Button(action: stop) {
                        Image(systemName: "stop.circle")
                            .font(.toasty(Theme.Size.body))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: Theme.Todo.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tooltip("Stop Task")
                    .accessibilityLabel("Stop")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var kind: String { task.type.lowercased() }
    private var isShell: Bool { kind.contains("bash") || kind.contains("shell") }

    private var symbol: String {
        if kind.contains("agent") { return "person.2" }
        if kind.contains("monitor") { return "eye" }
        if isShell { return "terminal" }
        return "gearshape"
    }

    private var name: String {
        if kind.contains("agent") { return "Agent" }
        if kind.contains("monitor") { return "Monitor" }
        if isShell { return "Shell command" }
        return "Task"
    }
}

/// One running thing in Tee-Up's row measure: a glyph in the to-do box's
/// slot, one line of text (cut in the middle, the whole of it in a
/// tooltip), an optional second line, and its clock at the right.
private struct ActivityRow: View {
    let symbol: String
    let title: Text
    let tooltip: String
    let detail: String?
    let time: String?

    /// "Running" in the body face and a shell command in monospace.
    static func title(verb: String, summary: String, code: Bool) -> Text {
        guard !summary.isEmpty else { return Text(verb + "…").font(.toasty(Theme.Size.body)) }
        let rest = code ? Text(summary).font(.toasty(Theme.Size.control, design: .monospaced))
                        : Text(summary).font(.toasty(Theme.Size.body))
        return Text(verb + " ").font(.toasty(Theme.Size.body)).foregroundColor(.secondary) + rest
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Todo.boxGap) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.control))
                .foregroundStyle(Theme.Todo.mark)
                .frame(width: Theme.Todo.box)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                title
                    .font(.toasty(Theme.Size.body))
                    .foregroundStyle(Theme.Sidebar.titleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .tooltip(Tooltip(title: tooltip, plain: true))
                if let detail {
                    Text(detail)
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if let time {
                Text(time)
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, (Theme.Todo.rowHeight - 17) / 2)
        .frame(minHeight: Theme.Todo.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Usage

/// The bottom of the tab: the context window and the plan's limits as
/// meters. A click opens what fills the context and the session's totals
/// above them.
struct UsageDock: View {
    @ObservedObject var conversation: ClaudeConversation
    @AppStorage("activityUsageDetails") private var expanded = false
    @State private var hovering = false

    static func hasUsage(_ c: ClaudeConversation) -> Bool {
        c.context != nil || c.usage != nil || !c.rateLimits.isEmpty
    }

    var body: some View {
        if UsageDock.hasUsage(conversation) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if expanded { details.transition(.opacity) }
                if let context = conversation.context {
                    let fraction = context.maxTokens > 0 ? Double(context.totalTokens) / Double(context.maxTokens) : context.percentage / 100
                    MeterRow(title: "Context", disclosure: expanded,
                             value: "\(Int((fraction * 100).rounded()))% · \(ActivityTab.tokens(context.totalTokens)) of \(ActivityTab.tokens(context.maxTokens))",
                             fraction: fraction,
                             tint: fraction > 0.9 ? Color(nsColor: .systemRed) : fraction > 0.7 ? Color(nsColor: .systemOrange) : .accentColor)
                }
                ForEach(conversation.rateLimits) { limit in
                    if let u = limit.utilization {
                        MeterRow(title: limit.title, disclosure: nil,
                                 value: limitValue(limit, u),
                                 fraction: u,
                                 tint: limit.status == "rejected" ? Color(nsColor: .systemRed)
                                     : limit.status == "allowed_warning" ? Color(nsColor: .systemOrange) : .accentColor)
                    } else if limit.status == "rejected" {
                        MeterRow(title: limit.title, disclosure: nil, value: "Limit reached", fraction: 1, tint: Color(nsColor: .systemRed))
                    }
                }
            }
            .padding(.horizontal, Theme.Inspector.edge)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }
            .onHover { hovering = $0 }
            .tooltip(Tooltip(title: expanded ? "Hide Details" : "Show Details",
                             detail: "What fills the context window, and this session's tokens and cost."))
            .accessibilityAddTraits(.isButton)
        }
    }

    private func limitValue(_ limit: ClaudeConversation.RateLimit, _ u: Double) -> String {
        let percent = "\(Int((u * 100).rounded()))%"
        guard let resets = limit.resetsAt else { return percent }
        let when = resets.formatted(resets.timeIntervalSinceNow < 86_400 ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
        return "\(percent) · resets \(when)"
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context = conversation.context {
                let used = context.categories.filter { $0.kind == "used" && $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
                if !used.isEmpty {
                    ActivityCaption(text: "In the Context Window")
                    ForEach(used.prefix(7)) { c in
                        InspectorRow(title: c.name, value: ActivityTab.tokens(c.tokens))
                    }
                }
            }
            if let usage = conversation.usage {
                ActivityCaption(text: "This Session").padding(.top, Theme.Space.s)
                InspectorRow(title: "Cost (estimate)",
                             value: usage.costUSD < 0.01 && usage.costUSD > 0 ? "< $0.01" : String(format: "$%.2f", usage.costUSD))
                InspectorRow(title: "Tokens in / out",
                             value: "\(ActivityTab.tokens(usage.inputTokens)) / \(ActivityTab.tokens(usage.outputTokens))")
                InspectorRow(title: "Cache reads / writes",
                             value: "\(ActivityTab.tokens(usage.cacheReadTokens)) / \(ActivityTab.tokens(usage.cacheWriteTokens))")
                InspectorRow(title: "API time", value: ClaudeToolInfo.duration(Int(usage.apiDuration.rounded())))
            }
        }
    }
}

/// A label and its value over a thin meter.
private struct MeterRow: View {
    let title: String
    /// Whether the details are open, for the row that opens them.
    let disclosure: Bool?
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(title)
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(Theme.Sidebar.titleColor)
                    .lineLimit(1)
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.toasty(Theme.Glyph.small, .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(disclosure ? -90 : 0))
                }
                Spacer(minLength: Theme.Space.s)
                Text(value)
                    .font(.toasty(Theme.Size.control))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Meter(fraction: fraction, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }
}
