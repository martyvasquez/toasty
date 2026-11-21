import SwiftUI

/// The inspector's Activity tab: whether the selected conversation's Claude
/// is alive and what it is doing, for long runs where the transcript alone
/// doesn't say. The inspector's skeleton (InspectorKit): the status as the
/// summary row, then "Now" (this turn's steps) and "In the Background",
/// and Usage pinned above the footer. Everything here is read from what
/// Claude Code already sends; nothing is asked of Claude.
struct ActivityTab: View {
    @ObservedObject var conversation: ClaudeConversation

    /// Silence from Claude Code for this long during a turn is called out.
    /// Streamed text and a running tool's heartbeat arrive every few
    /// seconds, so minutes of nothing is unusual; it isn't proof of a
    /// crash, and the tab doesn't say it is.
    static let quietAfter: TimeInterval = 180

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                StatusSummary(conversation: conversation, activity: conversation.activity,
                              lastTurn: lastTurn, now: context.date)
                if conversation.phase == .working || !conversation.backgroundTasks.isEmpty {
                    ScrollView {
                        RunningSections(conversation: conversation, activity: conversation.activity, now: context.date)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, Theme.Space.l)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    InspectorEmpty(symbol: InspectorTab.activity.symbol, title: "Nothing Running",
                                   detail: "Commands and agents show here while Claude works.")
                }
                UsageSection(conversation: conversation)
            }
        }
        .onAppear { conversation.refreshContextUsage() }
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

/// The summary row: is Claude alive? A spinner or a status dot, the state,
/// the turn's clock, and the evidence under it.
private struct StatusSummary: View {
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
        InspectorSummary(title: title, detail: detail.map { text in
            health == .quiet ? Text(text).foregroundColor(StatusColor.needsInput) : Text(text)
        }) {
            mark
        } trailing: {
            if let clock { InspectorValue(clock) }
        }
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
                .foregroundStyle(StatusColor.needsInput)
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

// MARK: - Now, In the Background

private struct RunningSections: View {
    @ObservedObject var conversation: ClaudeConversation
    @ObservedObject var activity: ClaudeTurnActivity
    let now: Date

    var body: some View {
        let running = conversation.runningTools
        let background = conversation.backgroundTasks
        VStack(alignment: .leading, spacing: 0) {
            if conversation.phase == .working {
                InspectorListSection(title: "Now", count: running.isEmpty ? nil : running.count) {
                    if running.isEmpty {
                        InspectorRow(label: InspectorRow<InspectorRowIcon, EmptyView>.label(verb)) {
                            InspectorRowIcon(symbol: symbol)
                        } trailing: { EmptyView() }
                    } else {
                        ForEach(running) { item in
                            RunningTool(item: item, cwd: conversation.cwd, now: now)
                        }
                    }
                }
            }
            if !background.isEmpty {
                InspectorListSection(title: "In the Background", count: background.count) {
                    ForEach(background) { task in
                        BackgroundRow(task: task, now: now) { conversation.stopTask(task.id) }
                    }
                }
            }
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

private struct RunningTool: View {
    @ObservedObject var item: ClaudeItem
    let cwd: String
    let now: Date

    var body: some View {
        let summary = ClaudeToolInfo.summary(item.toolName, item.input, cwd: cwd)
        InspectorRow(label: InspectorRow<InspectorRowIcon, AnyView>.label(label(summary), code: item.toolName == "Bash"),
                     progress: subagentStep) {
            InspectorRowIcon(symbol: ClaudeToolInfo.icon(item.toolName))
        } trailing: {
            AnyView(Group { if let seconds { InspectorValue(ClaudeToolInfo.duration(seconds)) } })
        }
        .tooltip(Tooltip(title: ClaudeToolInfo.activeVerb(item.toolName) + (summary.isEmpty ? "" : " " + summary), plain: true))
    }

    /// A command or an agent's task on its own (the icon says which); any
    /// other step with its verb ("Reading queue.ts").
    private func label(_ summary: String) -> String {
        switch item.toolName {
        case "Bash", "Task", "Agent" where !summary.isEmpty: return summary
        default: return ClaudeToolInfo.activeVerb(item.toolName) + (summary.isEmpty ? "…" : " " + summary)
        }
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
        InspectorRow(label: InspectorRow<InspectorRowIcon, AnyView>.label(text, code: isShell), hoverable: true) {
            InspectorRowIcon(symbol: symbol)
        } trailing: {
            AnyView(Group {
                if hovering {
                    Button(action: stop) {
                        Image(systemName: "stop.circle")
                            .font(.toasty(Theme.Size.control))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tooltip("Stop Task")
                    .accessibilityLabel("Stop")
                } else {
                    InspectorValue(ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(task.started)))))
                }
            })
        }
        .onHover { hovering = $0 }
        .tooltip(Tooltip(title: text, plain: true))
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

// MARK: - Usage (pinned)

/// Pinned above the footer: the context window and the plan's limits as
/// meters. "Details" opens what fills the context and the session's
/// totals above them.
struct UsageSection: View {
    @ObservedObject var conversation: ClaudeConversation
    @AppStorage("activityUsageDetails") private var expanded = false

    static func hasUsage(_ c: ClaudeConversation) -> Bool {
        c.context != nil || c.usage != nil || !c.rateLimits.isEmpty
    }

    var body: some View {
        if UsageSection.hasUsage(conversation) {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSectionHeading(title: "Usage") {
                    DetailsButton(expanded: $expanded)
                }
                if expanded { details.transition(.opacity) }
                if let context = conversation.context {
                    let fraction = context.maxTokens > 0 ? Double(context.totalTokens) / Double(context.maxTokens) : context.percentage / 100
                    InspectorMeter(title: "Context",
                                   value: "\(Int((fraction * 100).rounded()))% · \(ActivityTab.tokens(context.totalTokens)) of \(ActivityTab.tokens(context.maxTokens))",
                                   fraction: fraction)
                }
                ForEach(conversation.rateLimits) { limit in
                    if let u = limit.utilization {
                        InspectorMeter(title: limit.title, value: limitValue(limit, u), fraction: u,
                                       warns: limit.status == "rejected")
                    } else if limit.status == "rejected" {
                        InspectorMeter(title: limit.title, value: "Limit reached", fraction: 1, warns: true)
                    }
                }
            }
            .padding(.bottom, Theme.Space.m)
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
                ForEach(used.prefix(7)) { c in valueRow(c.name, ActivityTab.tokens(c.tokens)) }
            }
            if let usage = conversation.usage {
                if conversation.context != nil { Color.clear.frame(height: Theme.Space.s) }
                valueRow("Cost (estimate)", usage.costUSD < 0.01 && usage.costUSD > 0 ? "< $0.01" : String(format: "$%.2f", usage.costUSD))
                valueRow("Tokens In / Out", "\(ActivityTab.tokens(usage.inputTokens)) / \(ActivityTab.tokens(usage.outputTokens))")
                valueRow("Cache Reads / Writes", "\(ActivityTab.tokens(usage.cacheReadTokens)) / \(ActivityTab.tokens(usage.cacheWriteTokens))")
                valueRow("API Time", ClaudeToolInfo.duration(Int(usage.apiDuration.rounded())))
            }
        }
        .padding(.bottom, Theme.Space.s)
    }

    /// A detail: the row's text, its value at the right.
    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).font(.toasty(Theme.Size.control)).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(value).font(.toasty(Theme.Size.meta)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(height: Theme.Inspector.rowHeight)
        .padding(.horizontal, Theme.Inspector.edge)
    }
}

/// "Details" / "Hide" at a section heading's right.
private struct DetailsButton: View {
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            Text(expanded ? "Hide" : "Details")
                .font(.toasty(Theme.Size.caption))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(Tooltip(title: expanded ? "Hide Details" : "Show Details",
                         detail: "What fills the context window, and this session's tokens and cost."))
    }
}
