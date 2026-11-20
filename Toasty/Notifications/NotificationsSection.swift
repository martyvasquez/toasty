import SwiftUI

/// The bottom of the workspaces sidebar: every conversation that needs the
/// user, across all workspaces. A to-do list, not a log: rows come from
/// live state (`Activity.notices`) and leave by themselves once the request
/// is answered or the finished conversation has been seen. Always shown:
/// with nothing pending it says so.
struct NotificationsSection: View {
    @ObservedObject private var activity: Activity = .shared
    /// The rows' natural height: the list hugs it, up to the cap.
    @State private var listHeight: CGFloat = 0

    /// The list scrolls past this height, leaving the workspaces room.
    private static let maxListHeight: CGFloat = 300

    var body: some View {
        let notices = activity.notices
        Group { content(notices) }
            .animation(.easeInOut(duration: 0.2), value: notices.map(\.id))
    }

    @ViewBuilder private func content(_ notices: [Activity.Notice]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, Theme.textEdge)

            HStack {
                Text("Notifications")
                    .font(.toasty(Theme.Size.meta, .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !notices.isEmpty {
                    Text("\(notices.count)")
                        .font(.toasty(Theme.Size.caption, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Theme.Fill.subtle))
                        .transition(.opacity)
                }
            }
            .frame(height: 16)
            .padding(.horizontal, Theme.Space.m + Theme.Space.xs)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Notifications, \(notices.count)")

            if notices.isEmpty {
                EmptyNotices()
                    .padding(.horizontal, Theme.Sidebar.inset)
                    .padding(.bottom, Theme.Space.s)
                    .transition(.opacity)
            } else {
                ScrollView {
                    list(notices)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, Self.maxListHeight))
                .padding(.bottom, Theme.Space.s)
                .transition(.opacity)
            }
        }
    }

    private func list(_ notices: [Activity.Notice]) -> some View {
        VStack(spacing: Theme.Space.xxs) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { i, notice in
                NoticeRow(notice: notice, number: i < 9 ? i + 1 : nil)
            }
        }
        .padding(.horizontal, Theme.Sidebar.inset)
    }
}

/// Nothing needs the user: laid out like a row, so the section keeps its
/// shape.
private struct EmptyNotices: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Sidebar.iconGap) {
            Image(systemName: "cup.and.heat.waves")
                .font(.toasty(Theme.Size.control))
                .foregroundStyle(.tertiary)
                .frame(width: Theme.Sidebar.iconWidth, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("All caught up")
                    .font(.toasty(Theme.Size.body))
                    .foregroundStyle(.secondary)
                    .frame(height: 20)
                Text("Claude will check in here")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs + Theme.Space.xxs)
        .padding(.horizontal, Theme.Sidebar.rowPadding)
        .accessibilityElement(children: .combine)
    }
}

private struct NoticeRow: View {
    let notice: Activity.Notice
    /// Its ⌘-number shortcut (⌘1–9), shown on the row.
    let number: Int?
    @State private var hovering = false

    private var dismissable: Bool { [.finished, .stopped, .paused].contains(notice.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Sidebar.iconGap) {
            StatusDot(color: color)
                .frame(width: Theme.Sidebar.iconWidth, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.toasty(Theme.Size.body))
                    .lineLimit(1)
                    .frame(height: 20)
                Text(location)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Its own column, so the text above truncates before it.
            Group {
                if hovering && dismissable {
                    Button { notice.conversation.attention = false } label: {
                        Image(systemName: "xmark")
                            .font(.toasty(Theme.Size.caption, .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                } else if let number {
                    Text("⌘\(number)")
                        .font(.toasty(Theme.Size.caption, .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 20, height: 20, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.xs + Theme.Space.xxs)
        .padding(.horizontal, Theme.Sidebar.rowPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(hovering ? Theme.Fill.hover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Activity.shared.show(notice.conversation) }
        .contextMenu {
            Button("Show Conversation") { Activity.shared.show(notice.conversation) }
            if dismissable {
                Button("Dismiss") { notice.conversation.attention = false }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the conversation")
        // The message (the question, the command, the result) isn't on the
        // two-line row: it's in the tooltip and read by VoiceOver.
        .accessibilityValue(notice.text)
        .help(notice.text.isEmpty ? (number.map { "Show Conversation (⌘\($0))" } ?? "Show Conversation") : notice.text)
    }

    private var title: String {
        switch notice.kind {
        case .permission: "Permission required"
        case .question: "Claude has a question"
        case .plan: "Plan ready for review"
        case .paused: "Auto-Send paused"
        case .stopped: "Stopped"
        case .finished: "Finished"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .permission, .question, .plan, .paused: StatusColor.needsInput
        case .stopped: StatusColor.stopped
        case .finished: StatusColor.ready
        }
    }

    /// "Workspace · Tab".
    private var location: String {
        [notice.conversation.workspace?.displayName, notice.conversation.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
