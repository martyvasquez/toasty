import SwiftUI

/// The inspector's Activity tab: whether the selected conversation's Claude
/// is alive and what it is doing, for long runs where the transcript alone
/// doesn't say, and below it what the conversation has used (context,
/// plan limits, tokens and cost). Everything here is read from what Claude Code already
/// sends; nothing is asked of Claude.
struct ActivityTab: View {
    @ObservedObject var conversation: ClaudeConversation

    /// Silence from Claude Code for this long during a turn is called out.
    /// Streamed text and a running tool's heartbeat arrive every few
    /// seconds, so minutes of nothing is unusual; it isn't proof of a
    /// crash, and the tab doesn't say it is.
    static let quietAfter: TimeInterval = 180

    var body: some View {
        if conversation.phase == .idle, conversation.backgroundTasks.isEmpty,
           conversation.stopped == nil, lastTurn == nil, !UsageSections.hasUsage(conversation) {
            InspectorEmpty(symbol: InspectorTab.activity.symbol, title: "No Activity Yet",
                           detail: "What Claude is doing, and what it has used, shows here once it starts.")
                .onAppear { conversation.refreshContextUsage() }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Inspector.sectionGap) {
                        // How full the context is first, then the status and
                        // what's happening, then the plan's and session's totals.
                        UsageSections(conversation: conversation, part: .context)
                        StatusSection(conversation: conversation, activity: conversation.activity,
                                      lastTurn: lastTurn, now: context.date)
                        if conversation.phase == .working {
                            NowSection(conversation: conversation, activity: conversation.activity, now: context.date)
                        }
                        if !conversation.backgroundTasks.isEmpty {
                            BackgroundSection(conversation: conversation, now: context.date)
                        }
                        UsageSections(conversation: conversation, part: .totals)
                    }
                    .padding(.horizontal, Theme.Inspector.edge)
                    .padding(.top, Theme.Space.s)
                    .padding(.bottom, Theme.Inspector.edge)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        seconds < 5 ? "Just now" : ClaudeToolInfo.duration(Int(seconds)) + " ago"
    }
}

// MARK: - Status

private struct StatusSection: View {
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
        InspectorSection(title: "Status") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    mark.frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.toasty(Theme.Size.control, .medium))
                        if let detail {
                            Text(detail)
                                .font(.toasty(Theme.Size.meta))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.title) { row in
                            InspectorRow(title: row.title, value: row.value,
                                         valueStyle: row.warns ? AnyShapeStyle(Color(nsColor: .systemOrange)) : AnyShapeStyle(.secondary))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var mark: some View {
        switch health {
        case .starting, .working:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .waiting:
            StatusDot(color: StatusColor.needsInput)
        case .quiet:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.toasty(Theme.Size.caption))
                .foregroundStyle(Color(nsColor: .systemOrange))
        case .stopped:
            StatusDot(color: StatusColor.stopped)
        case .idle:
            StatusDot(color: Color.primary.opacity(0.25))
        }
    }

    private var title: String {
        switch health {
        case .starting: "Starting Claude Code"
        case .working: "Working"
        case .waiting: "Waiting for You"
        case .quiet: "No Activity for \(ClaudeToolInfo.duration(Int(silence) / 60 * 60))"
        case .stopped: "Claude Code Stopped"
        case .idle: "Idle"
        }
    }

    private var detail: String? {
        switch health {
        case .waiting:
            return conversation.requests.first?.summary
        case .quiet:
            return "Claude Code is running but has sent nothing. It may be waiting on a slow step."
        case .stopped:
            guard let stopped = conversation.stopped else { return nil }
            let code = stopped.status != 0 ? " (exit \(stopped.status))" : ""
            return "Its process ended unexpectedly\(code) \(ActivityTab.ago(now.timeIntervalSince(stopped.date)).lowercased())."
        case .idle:
            let n = conversation.backgroundTasks.count
            return n == 0 ? nil : n == 1 ? "1 task is running in the background." : "\(n) tasks are running in the background."
        case .starting, .working:
            return nil
        }
    }

    private struct Row {
        let title: String
        let value: String
        var warns = false
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if conversation.phase == .working {
            if let started = conversation.turnStarted {
                rows.append(Row(title: "This turn", value: ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(started))))))
            }
            rows.append(Row(title: "Last heard from Claude", value: ActivityTab.ago(silence),
                            warns: health == .quiet))
            if activity.outputTokens > 0 {
                let n = activity.outputTokens
                rows.append(Row(title: "Written this turn",
                                value: (n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)") + " tokens"))
            }
        } else if conversation.phase == .idle, let lastTurn, let finished = lastTurn.finishedAt {
            if let took = lastTurn.turnDuration {
                rows.append(Row(title: "Last turn took", value: ClaudeToolInfo.duration(took)))
            }
            rows.append(Row(title: "Last turn ended", value: ActivityTab.ago(now.timeIntervalSince(finished))))
        }
        return rows
    }
}

// MARK: - Now

/// The step Claude is on: each tool call still running with its own clock,
/// or thinking / writing between calls.
private struct NowSection: View {
    @ObservedObject var conversation: ClaudeConversation
    @ObservedObject var activity: ClaudeTurnActivity
    let now: Date

    var body: some View {
        let running = conversation.runningTools
        InspectorSection(title: "Now") {
            VStack(alignment: .leading, spacing: 10) {
                if running.isEmpty {
                    ActivityRow(symbol: symbol, title: verb, detail: nil, time: nil)
                } else {
                    ForEach(running) { item in
                        RunningTool(item: item, cwd: conversation.cwd, now: now)
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
        ActivityRow(symbol: ClaudeToolInfo.icon(item.toolName),
                    title: ClaudeToolInfo.activeVerb(item.toolName) + (summary.isEmpty ? "…" : " " + summary),
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

// MARK: - Background

/// Work Claude Code keeps running outside the turn: shells, subagents,
/// monitors. Hover a row to stop it.
private struct BackgroundSection: View {
    @ObservedObject var conversation: ClaudeConversation
    let now: Date

    var body: some View {
        InspectorSection(title: "In the Background") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(conversation.backgroundTasks) { task in
                    BackgroundRow(task: task, now: now) { conversation.stopTask(task.id) }
                }
            }
        }
    }
}

private struct BackgroundRow: View {
    let task: ClaudeConversation.BackgroundTask
    let now: Date
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        ActivityRow(symbol: symbol,
                    title: task.description.isEmpty ? name : ClaudeBackgroundLine.short(task.description),
                    detail: nil,
                    time: hovering ? nil : ClaudeToolInfo.duration(max(0, Int(now.timeIntervalSince(task.started)))))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: stop) {
                        Image(systemName: "stop.circle")
                            .font(.toasty(Theme.Size.control))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop this task")
                    .accessibilityLabel("Stop")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var kind: String { task.type.lowercased() }

    private var symbol: String {
        if kind.contains("agent") { return "person.2" }
        if kind.contains("monitor") { return "eye" }
        if kind.contains("bash") || kind.contains("shell") { return "terminal" }
        return "gearshape"
    }

    private var name: String {
        if kind.contains("agent") { return "Agent" }
        if kind.contains("monitor") { return "Monitor" }
        if kind.contains("bash") || kind.contains("shell") { return "Shell command" }
        return "Task"
    }
}

// MARK: - Row

/// One running thing: an icon, what it is (up to two lines), an optional
/// second line, and how long it has run.
private struct ActivityRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let time: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.caption))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.toasty(Theme.Size.meta))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.toasty(Theme.Size.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let time {
                Text(time)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
