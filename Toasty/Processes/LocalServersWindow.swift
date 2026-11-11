import AppKit
import SwiftUI

/// The list behind Window ▸ Local Servers: looked up while the window is
/// open, every two seconds, off the main thread.
@MainActor
final class LocalServersModel: ObservableObject {
    @Published private(set) var servers: [LocalServer] = []
    /// False until the first look has come back.
    @Published private(set) var loaded = false
    /// Servers told to stop that haven't gone yet.
    @Published private(set) var stopping: Set<String> = []

    private var timer: Timer?
    private var scanning = false

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // `.common`: keeps going while a menu is open or the window resizes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let found = LocalServers.scan()
            await MainActor.run {
                self.scanning = false
                self.loaded = true
                if found != self.servers { self.servers = found }
                self.stopping.formIntersection(found.map(\.id))
            }
        }
    }

    func stop(_ server: LocalServer) {
        guard stopping.insert(server.id).inserted else { return }
        Task.detached(priority: .userInitiated) {
            LocalServers.stop(server)
            await MainActor.run { self.refresh() }
        }
    }

    func open(_ server: LocalServer) {
        if let url = server.url { NSWorkspace.shared.open(url) }
    }

    func reveal(_ server: LocalServer) {
        NSWorkspace.shared.open(URL(fileURLWithPath: server.folder))
    }
}

/// Window ▸ Local Servers: every dev server running on this Mac, each with
/// a Stop button. A utility for finding and clearing out servers left
/// running, whoever started them; conversations already stop their own
/// when they close (`ProcessReaper`).
@MainActor
final class LocalServersWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LocalServersWindowController()

    let model = LocalServersModel()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: LocalServersView(model: model)))
        window.title = "Local Servers"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 380))
        window.contentMinSize = NSSize(width: 420, height: 200)
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ToastyLocalServers")
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func show(_ sender: Any?) {
        model.start()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) { model.pause() }
    func windowDidMiniaturize(_ notification: Notification) { model.pause() }
    func windowDidDeminiaturize(_ notification: Notification) { model.start() }
}

struct LocalServersView: View {
    @ObservedObject var model: LocalServersModel

    var body: some View {
        VStack(spacing: 0) {
            if model.servers.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.servers) { server in
                            LocalServerRow(server: server, stopping: model.stopping.contains(server.id), model: model)
                            if server.id != model.servers.last?.id {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            Divider()
            Text("Every program serving a port from one of your folders.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .frame(height: 32)
        }
        .frame(minWidth: 420, minHeight: 200)
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 4) {
            if model.loaded {
                Text("No Local Servers")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Nothing is serving a port from your folders.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LocalServerRow: View {
    let server: LocalServer
    let stopping: Bool
    let model: LocalServersModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(detail(now: context.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Button("Open") { model.open(server) }
                .help("Open \(server.address) in your browser")
            Button("Stop") { model.stop(server) }
                .disabled(stopping)
                .help("Stop this server")
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .opacity(stopping ? 0.5 : 1)
        .contentShape(Rectangle())
        .help(help)
        .contextMenu {
            Button("Open in Browser") { model.open(server) }
            Button("Show Folder in Finder") { model.reveal(server) }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.url?.absoluteString ?? server.address, forType: .string)
            }
            Divider()
            Button("Stop") { model.stop(server) }.disabled(stopping)
        }
        .accessibilityElement(children: .contain)
    }

    /// "localhost:4321 · astro dev · started 5 days ago · Claude Code"
    private func detail(now: Date) -> String {
        var parts = [server.address]
        if !server.command.isEmpty { parts.append(server.command) }
        parts.append(stopping ? "stopping…" : Self.started(server.process.started, now: now))
        if server.startedByClaude { parts.append("Claude Code") }
        return parts.joined(separator: " · ")
    }

    private var help: String {
        let folder = (server.folder as NSString).abbreviatingWithTildeInPath
        let since = server.process.started.formatted(date: .abbreviated, time: .shortened)
        return "\(folder)\nRunning since \(since)" + (server.startedByClaude ? "\nStarted by Claude Code" : "")
    }

    static func started(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "started just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "started " + formatter.localizedString(for: date, relativeTo: now)
    }
}
