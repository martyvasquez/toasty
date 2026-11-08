import SwiftUI

/// The bottom of the workspaces sidebar: every conversation that needs the
/// user, across all workspaces. A to-do list, not a log: rows come from
/// live state (`Activity.notices`) and leave by themselves once the request
/// is answered or the finished conversation has been seen.
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
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.horizontal, 12)

                HStack {
                    Text("Notifications")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(notices.count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Notifications, \(notices.count)")

                ScrollView {
                    list(notices)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, Self.maxListHeight))
                .padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    private func list(_ notices: [Activity.Notice]) -> some View {
        VStack(spacing: 2) {
            ForEach(notices) { NoticeRow(notice: $0) }
        }
        .padding(.horizontal, 8)
    }
}

private struct NoticeRow: View {
    let notice: Activity.Notice
    @State private var hovering = false

    private var dismissable: Bool { notice.kind == .finished || notice.kind == .stopped }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
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
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(Self.age(notice.date, now: context.date))
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 18)

                if !notice.text.isEmpty {
                    Text(notice.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(location)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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

    private var symbol: String {
        switch notice.kind {
        case .permission: "exclamationmark.circle"
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .stopped: "xmark.octagon"
        case .finished: "checkmark.circle"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .permission, .plan: .orange
        case .question: .purple
        case .stopped: .red
        case .finished: .green
        }
    }

    /// "Workspace · Tab".
    private var location: String {
        [notice.conversation.workspace?.displayName, notice.conversation.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func age(_ date: Date, now: Date) -> String {
        guard date != .distantPast else { return "" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}
