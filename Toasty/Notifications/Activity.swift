import AppKit
import IOKit.pwr_mgt
import SwiftUI
@preconcurrency import UserNotifications

/// What Claude is doing in each conversation, for everything outside the
/// conversation itself: the sidebar, the dock badge, the sound, the toast,
/// macOS notifications, keep-awake, and close/quit confirmations.
@MainActor
final class Activity: NSObject, ObservableObject {
    static let shared = Activity()

    enum State: String { case idle, working, waiting }

    private struct Entry {
        var state: State
        /// When the current stretch of work began.
        var since: Date
    }

    private struct Message {
        var text: String
        var date: Date
        /// The turn ended with an error rather than finishing.
        var stopped = false
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        let location: String
        weak var conversation: ClaudeConversation?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    @Published private var entries: [UUID: Entry] = [:]
    @Published private var messages: [UUID: Message] = [:]
    @Published private(set) var toast: Toast?
    private var dismissWork: DispatchWorkItem?

    /// A sound from /System/Library/Sounds or ~/Library/Sounds, or "none":
    /// `defaults write com.martyvasquez.toasty ToastySound Glass`.
    private var soundName: String {
        UserDefaults.standard.string(forKey: "ToastySound") ?? "Glass"
    }

    private override init() {
        super.init()
        // Coming back to Toasty: the conversation on screen has been seen.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Activity.shared.markShownAsSeen() }
        }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call at launch.
    func start() { syncDockBadge() }

    // MARK: State

    func state(of conversation: ClaudeConversation) -> State {
        entries[conversation.id]?.state ?? .idle
    }

    func setAgentState(_ conversation: ClaudeConversation, _ raw: String) {
        let state = State(rawValue: raw) ?? .idle
        let now = Date()
        switch state {
        case .idle:
            entries[conversation.id] = nil
        case .working:
            let since = entries[conversation.id].flatMap { $0.state == .working ? $0.since : nil } ?? now
            entries[conversation.id] = Entry(state: .working, since: since)
        case .waiting:
            entries[conversation.id] = Entry(state: .waiting, since: now)
        }
        stateDidChange()
    }

    /// When the earliest working conversation of these started, if any.
    func workingSince(_ conversations: [ClaudeConversation]) -> Date? {
        conversations.compactMap { c in entries[c.id].flatMap { $0.state == .working ? $0.since : nil } }.min()
    }

    /// The latest message (needs you / finished) from any of these.
    func latestMessage(_ conversations: [ClaudeConversation]) -> String? {
        conversations.compactMap { messages[$0.id] }.max { $0.date < $1.date }?.text
    }

    func forget(_ conversation: ClaudeConversation) {
        entries[conversation.id] = nil
        messages[conversation.id] = nil
        stateDidChange()
    }

    private var allConversations: [ClaudeConversation] {
        WorkspaceStore.shared.workspaces.flatMap(\.conversations)
    }

    private func stateDidChange() {
        syncDockBadge()
        syncPowerAssertion()
    }

    // MARK: Attention

    /// The conversation is on screen: its tab is selected in the shown
    /// workspace, and Toasty's window is key.
    func isVisible(_ conversation: ClaudeConversation) -> Bool {
        guard NSApp.isActive, AppDelegate.shared.windowController?.window?.isKeyWindow == true,
              let w = conversation.workspace else { return false }
        return w.store?.activeID == w.id && w.selectedID == conversation.id
    }

    func markShownAsSeen() {
        if let c = WorkspaceStore.shared.active?.selected, c.attention { c.attention = false }
        syncDockBadge()
    }

    func attentionChanged() { syncDockBadge() }

    /// Jump to the latest conversation needing the user: waiting first,
    /// then finished unseen (⌃⌘U).
    func jumpToLatest() {
        let all = allConversations
        let waiting = all.filter { !$0.requests.isEmpty }
        let unseen = all.filter(\.attention)
        func latest(_ list: [ClaudeConversation]) -> ClaudeConversation? {
            list.max { (messages[$0.id]?.date ?? .distantPast) < (messages[$1.id]?.date ?? .distantPast) }
        }
        guard let target = latest(waiting) ?? latest(unseen) else { NSSound.beep(); return }
        show(target)
    }

    func show(_ conversation: ClaudeConversation) {
        guard let w = conversation.workspace, let store = w.store else { return }
        store.activate(w.id)
        w.select(conversation)
        AppDelegate.shared.windowController?.showWindow(nil)
        conversation.focusComposer()
    }

    // MARK: Notifications

    /// Something happened in a conversation the user should know about
    /// (finished, stopped, needs them): sound, attention, toast, banner.
    func present(source conversation: ClaudeConversation, title: String, body rawBody: String, stopped: Bool = false) {
        // One line of text for the sidebar, toast and banner.
        let body = rawBody.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        messages[conversation.id] = Message(text: body.isEmpty ? title : body, date: Date(), stopped: stopped)

        // 1. Sound
        if soundName.lowercased() != "none", let sound = NSSound(named: NSSound.Name(soundName)) {
            sound.stop()
            sound.play()
        }

        let visible = isVisible(conversation)

        // 2. Attention, unless the user is looking right at it.
        if !visible {
            conversation.attention = true
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        syncDockBadge()

        let location = [conversation.workspace?.name, conversation.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")

        // 3. In-window toast (not for the conversation on screen).
        if !visible {
            let toast = Toast(title: title, body: body, location: location, conversation: conversation)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.toast = toast }
            dismissWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard self?.toast?.id == toast.id else { return }
                withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }

        // 4. A macOS notification when Toasty isn't frontmost.
        if !NSApp.isActive {
            postSystemNotification(conversation, title: title, body: body, location: location)
        }
    }

    func dismissToast() {
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
    }

    func open(_ toast: Toast) {
        dismissToast()
        if let c = toast.conversation { show(c) }
    }

    private func postSystemNotification(_ c: ClaudeConversation, title: String, body: String, location: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = location
            content.body = String(body.prefix(300))
            content.userInfo = ["conversation": c.id.uuidString]
            content.threadIdentifier = c.id.uuidString
            // Toasty plays its own sound.
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: Notifications (sidebar)

    /// A conversation that needs the user, for the sidebar's list. Derived
    /// from live state, so it goes away by itself once answered or seen.
    struct Notice: Identifiable {
        enum Kind { case permission, question, plan, stopped, finished }
        let conversation: ClaudeConversation
        let kind: Kind
        let text: String
        let date: Date
        var id: UUID { conversation.id }
    }

    /// Waiting conversations first, then stopped and finished ones; newest
    /// first within each. The same set the dock badge counts.
    var notices: [Notice] {
        let list: [Notice] = allConversations.compactMap { c in
            let date = messages[c.id]?.date ?? entries[c.id]?.since ?? .distantPast
            if let r = c.requests.first {
                let kind: Notice.Kind = switch r.toolName {
                case "AskUserQuestion": .question
                case "ExitPlanMode": .plan
                default: .permission
                }
                // A plan's summary only repeats the row's title.
                return Notice(conversation: c, kind: kind, text: kind == .plan ? "" : r.summary, date: date)
            }
            guard c.attention else { return nil }
            let m = messages[c.id]
            return Notice(conversation: c, kind: m?.stopped == true ? .stopped : .finished,
                          text: m?.text ?? "", date: date)
        }
        func rank(_ k: Notice.Kind) -> Int { k == .finished ? 2 : (k == .stopped ? 1 : 0) }
        return list.sorted { (rank($0.kind), $1.date) < (rank($1.kind), $0.date) }
    }

    // MARK: Dock badge

    /// Conversations needing the user: waiting on them, or finished unseen.
    var needingCount: Int {
        allConversations.filter { !$0.requests.isEmpty || $0.attention }.count
    }

    private var badgeAuthorized = false
    private var askedForBadge = false

    func syncDockBadge() {
        let n = needingCount
        let label = n > 0 ? (n > 99 ? "99+" : String(n)) : nil
        guard NSApp.dockTile.badgeLabel != label else { return }
        if label != nil, !badgeAuthorized, !askedForBadge {
            // Badges need notification permission on current macOS.
            askedForBadge = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Activity.shared.badgeAuthorized = granted
                        Activity.shared.syncDockBadge()
                    }
                }
            }
        }
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
    }

    // MARK: Keep awake

    private var powerAssertion: IOPMAssertionID = 0

    /// While any conversation is working, prevent idle system sleep (the
    /// display may still sleep).
    private func syncPowerAssertion() {
        let anyWorking = entries.values.contains { $0.state == .working }
        if anyWorking && powerAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Claude Code is working in Toasty" as CFString, &id)
            if result == kIOReturnSuccess { powerAssertion = id }
        } else if !anyWorking && powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }

    var keepingAwake: Bool { powerAssertion != 0 }

    // MARK: Confirmations

    /// Why closing these would interrupt something, or nil if it wouldn't.
    func closeWarning(conversations: [ClaudeConversation], terminals: [TerminalSession], action: String) -> String? {
        let working = conversations.filter { $0.phase != .idle && $0.requests.isEmpty }.count
        let waiting = conversations.filter { !$0.requests.isEmpty }.count
        let running = terminals.compactMap { $0.hasRunningProcess ? $0.terminalView?.pty?.foregroundName ?? "a program" : nil }
        var parts: [String] = []
        func tabs(_ n: Int) -> String { n == 1 ? "1 conversation" : "\(n) conversations" }
        if working > 0 { parts.append("Claude is working in \(tabs(working))") }
        if waiting > 0 { parts.append("Claude is waiting for you in \(tabs(waiting))") }
        if !running.isEmpty {
            let names = Array(Set(running)).sorted().map { "“\($0)”" }.joined(separator: ", ")
            parts.append(running.count == 1 ? "\(names) is running in a terminal" : "\(names) are running in \(running.count) terminals")
        }
        guard !parts.isEmpty else { return nil }
        let lead = parts.joined(separator: "; ")
        return "\(lead.prefix(1).uppercased() + lead.dropFirst()). If you \(action), it will be stopped."
    }

    /// Ask before closing; `proceed` runs if there's nothing to lose or the
    /// user confirms.
    func confirm(_ message: String?, title: String, button: String,
                 cancel: (() -> Void)? = nil, proceed: @escaping () -> Void) {
        guard let message else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if let window = AppDelegate.shared.windowController?.window, window.isVisible {
            alert.beginSheetModal(for: window) { $0 == .alertFirstButtonReturn ? proceed() : cancel?() }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        } else {
            cancel?()
        }
    }

    // MARK: Transcripts

    /// Claude Code's saved transcript for a session:
    /// `~/.claude/projects/<project>/<session>.jsonl`.
    nonisolated static func transcriptURL(for id: String) -> URL? {
        let fm = FileManager.default
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let projects = configDir.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        return dirs
            .map { $0.appendingPathComponent("\(id).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }
}

extension Activity: UNUserNotificationCenterDelegate {
    /// Clicking a banner jumps to its conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["conversation"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate()
                if let id, let uuid = UUID(uuidString: id),
                   let c = WorkspaceStore.shared.workspaces.flatMap(\.conversations).first(where: { $0.id == uuid }) {
                    Activity.shared.show(c)
                }
            }
        }
        completionHandler()
    }

    /// Toasty is frontmost: its own toast is enough.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

/// The toast overlay at the window's top-right, below the tab row.
struct ActivityToastView: View {
    @ObservedObject var activity: Activity = .shared
    @Environment(\.controlActiveState) private var activeState

    #if DEBUG
    /// Debug: show the toast even when the window isn't key (tests run
    /// while another app is frontmost).
    nonisolated(unsafe) static var alwaysShow = false
    #endif

    private var windowIsKey: Bool {
        #if DEBUG
        if Self.alwaysShow { return true }
        #endif
        return activeState == .key
    }

    var body: some View {
        if windowIsKey, let toast = activity.toast {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                    if !toast.body.isEmpty {
                        Text(toast.body)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !toast.location.isEmpty {
                        Text(toast.location)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { activity.dismissToast() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { activity.open(toast) }
            .padding(12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }
}
