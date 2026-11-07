import AppKit
import Combine

/// A terminal tab: a shell that starts when first shown and keeps running
/// while hidden or while its workspace is in the background.
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    /// Where the shell started (restored as a fresh shell here).
    let startDirectory: String
    @Published private(set) var title = ""
    /// The shell's current directory, as last seen.
    @Published private(set) var directory: String

    /// Called when the shell exits.
    var onExit: (() -> Void)?

    private var _view: TerminalScrollView?
    private var cancellables: Set<AnyCancellable> = []
    private var poll: Timer?

    init(id: UUID = UUID(), cwd: String) {
        self.id = id
        self.startDirectory = cwd
        self.directory = cwd
    }

    var isStarted: Bool { _view != nil }

    /// The terminal view; starts the shell on first use.
    var view: TerminalScrollView {
        if let _view { return _view }
        let dir = FileManager.default.fileExists(atPath: startDirectory) ? startDirectory : NSHomeDirectory()
        let v = TerminalScrollView(cwd: dir)
        _view = v
        v.terminal.onExit = { [weak self] _ in self?.onExit?() }
        v.terminal.$title.combineLatest(v.terminal.$pwd)
            .sink { [weak self] _, _ in self?.refresh() }
            .store(in: &cancellables)
        // Without shell integration there's no OSC 7: follow the
        // foreground process (its name and directory) instead.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        return v
    }

    var terminalView: TerminalView? { _view?.terminal }

    var hasRunningProcess: Bool { _view?.terminal.pty?.hasRunningProcess ?? false }

    /// The tab's title: the program's title (OSC 0/2) unless it's the
    /// shell's `user@host:path`, else the directory's last component.
    private func refresh() {
        guard let t = _view?.terminal else { return }
        let pwd = !t.pwd.isEmpty ? t.pwd : (t.pty?.foregroundDirectory ?? directory)
        if pwd != directory { directory = pwd }
        let name: String
        if !t.title.isEmpty, !t.title.contains("@") {
            name = t.title
        } else if let fg = t.pty?.foregroundName, t.pty?.hasRunningProcess == true {
            name = fg
        } else {
            name = pwd == NSHomeDirectory() ? "~" : (pwd as NSString).lastPathComponent
        }
        if name != title { title = name }
    }

    func terminate() {
        poll?.invalidate()
        _view?.terminal.terminate()
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return directory == NSHomeDirectory() ? "~" : (directory as NSString).lastPathComponent
    }
}
