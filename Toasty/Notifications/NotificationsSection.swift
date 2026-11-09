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
            Divider().padding(.horizontal, 12)

            HStack {
                Text("Notifications")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !notices.isEmpty {
                    Text("\(notices.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .transition(.opacity)
                }
            }
            .frame(height: 16)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Notifications, \(notices.count)")

            if notices.isEmpty {
                EmptyNotices()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                ScrollView {
                    list(notices)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, Self.maxListHeight))
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }

    private func list(_ notices: [Activity.Notice]) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { i, notice in
                NoticeRow(notice: notice, number: i < 9 ? i + 1 : nil)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Nothing needs the user: laid out like a row, so the section keeps its
/// shape.
private struct EmptyNotices: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cup.and.heat.waves")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("All caught up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 18)
                Text("Claude will check in here")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct NoticeRow: View {
    let notice: Activity.Notice
    /// Its ⌘-number shortcut (⌘1–9), shown on the row.
    let number: Int?
    @State private var hovering = false

    private var dismissable: Bool { notice.kind == .finished || notice.kind == .stopped }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: color)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(height: 18)
                Text(location)
                    .font(.system(size: 11))
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
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                } else if let number {
                    Text("⌘\(number)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 20, height: 18, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
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
        case .stopped: "Stopped"
        case .finished: "Finished"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .permission, .question, .plan: StatusColor.needsInput
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
