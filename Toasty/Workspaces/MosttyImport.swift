import AppKit
import SwiftUI

/// One-time import from mostty: its workspaces (names, folders, order, read
/// from mostty's defaults; nothing of mostty's is changed) and, for each,
/// the folder's recent Claude Code sessions to reopen as tabs.
@MainActor
final class MosttyImport: ObservableObject {
    struct Session: Identifiable {
        let id: String
        let title: String
        let date: Date
        var selected: Bool
    }

    struct Item: Identifiable {
        let id: String
        let name: String
        let folder: String
        /// Toasty already has a workspace for this folder (sessions go there).
        let existing: Bool
        var selected: Bool
        var sessions: [Session]
    }

    @Published var items: [Item] = []
    @Published var loading = true

    /// mostty's defaults domain. Debug builds can point it elsewhere
    /// (`ToastyMosttyDomain`) so tests never resume real sessions.
    nonisolated static var domain: String {
        #if DEBUG
        if let d = UserDefaults.standard.string(forKey: "ToastyMosttyDomain") { return d }
        #endif
        return "com.mostty.app"
    }

    /// mostty's current workspaces, in its sidebar order.
    nonisolated static func mosttyWorkspaces() -> [(id: String, name: String, folder: String)] {
        guard let defaults = UserDefaults(suiteName: domain),
              let order = defaults.array(forKey: "MosttyWorkspaceOrder") as? [String] else { return [] }
        let names = defaults.dictionary(forKey: "MosttyWorkspaceNames") as? [String: String] ?? [:]
        let folders = defaults.dictionary(forKey: "MosttyWorkspaceFolders") as? [String: String] ?? [:]
        return order.compactMap { id in
            guard let folder = folders[id], FileManager.default.fileExists(atPath: folder) else { return nil }
            let name = names[id].flatMap { $0.isEmpty ? nil : $0 } ?? (folder as NSString).lastPathComponent
            return (id, name, folder)
        }
    }

    static var isAvailable: Bool { !mosttyWorkspaces().isEmpty }

    func load(store: WorkspaceStore) {
        let existing = Set(store.workspaces.map { WorkspaceStore.normalize($0.folder) })
        let found = Self.mosttyWorkspaces()
        Task.detached(priority: .userInitiated) {
            var items: [Item] = []
            for w in found {
                let sessions = Self.recentSessions(in: w.folder, limit: 8)
                items.append(Item(id: w.id, name: w.name, folder: w.folder,
                                  existing: existing.contains(WorkspaceStore.normalize(w.folder)),
                                  selected: true,
                                  sessions: sessions.enumerated().map { i, s in
                                      // The newest session is most likely the one to continue.
                                      Session(id: s.id, title: s.title, date: s.date, selected: i == 0)
                                  }))
            }
            await MainActor.run {
                self.items = items
                self.loading = false
            }
        }
    }

    /// Claude Code's sessions for a folder, newest first:
    /// `~/.claude/projects/<folder with non-alphanumerics as "-">/*.jsonl`.
    nonisolated static func recentSessions(in folder: String, limit: Int) -> [(id: String, title: String, date: Date)] {
        let fm = FileManager.default
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        var dirs: [String] = []
        for path in Set([folder, real]) {
            let encoded = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            dirs.append((configDir as NSString).appendingPathComponent("projects/\(encoded)"))
        }
        var files: [(URL, Date)] = []
        for dir in dirs {
            let url = URL(fileURLWithPath: dir)
            let list = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in list where f.pathExtension == "jsonl" {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((f, date))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [(String, String, Date)] = []
        for (url, date) in files {
            guard out.count < limit, let title = sessionTitle(url) else { continue }
            out.append((url.deletingPathExtension().lastPathComponent, title, date))
        }
        return out
    }

    /// The session's name as `claude --resume` shows it: a custom title,
    /// else Claude's generated title, else the first prompt. Nil for
    /// sessions with no prompt (nothing to resume).
    nonisolated static func sessionTitle(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var custom: String?, ai: String?, first: String?
        for line in data.split(separator: 0x0A) {
            // Cheap checks before parsing JSON.
            let isTitle = line.range(of: Data("-title\"".utf8)) != nil
            let isUser = first == nil && line.range(of: Data("\"type\":\"user\"".utf8)) != nil
            guard isTitle || isUser,
                  let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch e["type"] as? String {
            case "custom-title": custom = e["customTitle"] as? String ?? custom
            case "ai-title": ai = e["aiTitle"] as? String ?? ai
            case "user":
                guard e["isMeta"] as? Bool != true, e["isSidechain"] as? Bool != true,
                      let message = e["message"] as? [String: Any] else { continue }
                var text = message["content"] as? String
                if let blocks = message["content"] as? [[String: Any]] {
                    text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                }
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                    first = String(t.split(whereSeparator: \.isNewline).first ?? "")
                }
            default: break
            }
        }
        guard let title = custom ?? ai ?? first else { return nil }
        return title.count > 80 ? String(title.prefix(79)) + "…" : title
    }

    /// Create the chosen workspaces and open the chosen sessions as tabs.
    func perform(store: WorkspaceStore) {
        var firstImported: UUID?
        for item in items where item.selected {
            let workspace = store.workspaces.first { WorkspaceStore.normalize($0.folder) == WorkspaceStore.normalize(item.folder) }
                ?? store.create(folder: item.folder, name: item.name, activate: false, withConversation: false, append: true)
            for s in item.sessions.reversed()
                where s.selected && !workspace.conversations.contains(where: { $0.sessionID == s.id }) {
                let c = ClaudeConversation(restoring: UUID(), cwd: item.folder, sessionID: s.id, customTitle: nil)
                workspace.add(c, select: false)
            }
            if workspace.conversations.isEmpty { workspace.newConversation() }
            if workspace.selectedID == nil, let first = workspace.conversations.first { workspace.select(first) }
            if firstImported == nil { firstImported = workspace.id }
        }
        if let firstImported { store.activate(firstImported) }
        UserDefaults.standard.set(true, forKey: "ToastyImportedFromMostty")
        store.setNeedsSave()
    }

    // MARK: Presenting

    private static var sheetWindow: NSWindow?
    private static var activeModel: MosttyImport?

    /// Close the sheet; with `perform`, import the current selection first.
    static func finishSheet(perform: Bool, store: WorkspaceStore) {
        if perform, let m = activeModel, !m.loading { m.perform(store: store) }
        if let sheet = sheetWindow { AppDelegate.shared.windowController?.window?.endSheet(sheet) }
        sheetWindow = nil
        activeModel = nil
    }

    static func present(store: WorkspaceStore) {
        guard sheetWindow == nil, let window = AppDelegate.shared.windowController?.window else { return }
        let model = MosttyImport()
        model.load(store: store)
        activeModel = model
        let host = NSHostingController(rootView: MosttyImportView(model: model, store: store) {
            finishSheet(perform: false, store: store)
        })
        let sheet = NSWindow(contentViewController: host)
        sheet.setContentSize(NSSize(width: 560, height: 560))
        sheetWindow = sheet
        window.beginSheet(sheet)
    }
}

struct MosttyImportView: View {
    @ObservedObject var model: MosttyImport
    let store: WorkspaceStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from mostty")
                    .font(.system(size: 15, weight: .semibold))
                Text("Your mostty workspaces, and the recent Claude Code sessions in each folder to reopen as tabs. mostty isn't changed. Quit mostty first so no session is open in both apps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            if model.loading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                Text("No mostty workspaces found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach($model.items) { $item in
                            ItemRow(item: $item)
                        }
                    }
                    .padding(20)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    model.perform(store: store)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loading || !model.items.contains { $0.selected })
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }

    private struct ItemRow: View {
        @Binding var item: MosttyImport.Item

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $item.selected) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 13, weight: .medium))
                        Text((item.folder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.existing {
                            Text("Already in Toasty")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                }
                if item.sessions.isEmpty {
                    Text("No Claude Code sessions in this folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 22)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($item.sessions) { $session in
                            Toggle(isOn: $session.selected) {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkle")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(Color(nsColor: .systemOrange))
                                    Text(session.title)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 8)
                                    Text(session.date, format: .relative(presentation: .named))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .disabled(!item.selected)
                        }
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }
}
