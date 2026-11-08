import AppKit
import SwiftUI

/// Settings ▸ Dictation: your vocabulary (everywhere, or this project), and
/// what Toasty adds by itself. Edits are saved to the same plain-text files
/// dictation reads (Application Support/…/vocabulary.txt and
/// <project>/.toasty/vocabulary.txt), so a project's file can be committed.
@MainActor
final class VocabularyEditor: ObservableObject {
    struct TermRow: Identifiable, Equatable {
        let id = UUID()
        var text = ""
        var soundsLike = ""
        var fixCase = false
    }

    struct ReplacementRow: Identifiable, Equatable {
        let id = UUID()
        var from = ""
        var to = ""
    }

    enum Scope: Hashable { case global, project }

    @Published var scope: Scope = .global { didSet { if scope != oldValue { load() } } }
    @Published var terms: [TermRow] = [] { didSet { if !loading { scheduleSave() } } }
    @Published var replacements: [ReplacementRow] = [] { didSet { if !loading { scheduleSave() } } }
    @Published private(set) var projectName: String?
    @Published private(set) var projectFolder: String?
    @Published private(set) var contextNames: [String] = []

    private var header = ""
    private var loading = false
    private var saveWork: DispatchWorkItem?

    var fileURL: URL? {
        switch scope {
        case .global: Vocabulary.globalURL
        case .project: projectFolder.map { Vocabulary.projectURL(folder: $0) }
        }
    }

    /// Picks up the current workspace and reloads (the files may have been
    /// edited by hand meanwhile).
    func refresh() {
        let folder = DictationController.shared.currentFolder
        projectFolder = folder
        projectName = folder.map { (($0 as NSString).lastPathComponent) }
        if projectFolder == nil { scope = .global }
        load()
        loadContext()
    }

    private func load() {
        flushSave()
        loading = true
        defer { loading = false }
        let url: URL?
        switch scope {
        case .global: url = Vocabulary.ensureGlobalFile()
        case .project: url = projectFolder.map { Vocabulary.projectURL(folder: $0) }
        }
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? (scope == .project ? Vocabulary.projectTemplate : "")
        // The comment block at the top is kept as written; entries are ours.
        let lines = text.components(separatedBy: "\n")
        let headerEnd = lines.firstIndex { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        } ?? lines.count
        header = lines[..<headerEnd].joined(separator: "\n").trimmingCharacters(in: .newlines)
        let file = Vocabulary.parse(text)
        terms = file.terms.map { TermRow(text: $0.text, soundsLike: $0.soundsLike.joined(separator: ", "), fixCase: $0.forced) }
        replacements = file.replacements.map { ReplacementRow(from: $0.from, to: $0.to) }
    }

    private func loadContext() {
        let workspace = WorkspaceStore.shared.workspaces.first { $0.folder == projectFolder }
        let input = DictationController.contextInput(workspace: workspace, conversation: workspace?.selected?.id)
        Task.detached(priority: .utility) {
            let names = ContextVocabulary.gather(input).filter { $0.source != .core }.map(\.text)
            await MainActor.run { self.contextNames = names }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flushSave() {
        if let work = saveWork { work.cancel(); saveWork = nil; save() }
    }

    private func save() {
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.serialize(header: header, terms: terms, replacements: replacements)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file text: the kept comment header, terms, then replacements.
    nonisolated static func serialize(header: String, terms: [TermRow], replacements: [ReplacementRow]) -> String {
        var lines: [String] = []
        if !header.isEmpty { lines.append(header); lines.append("") }
        for row in terms {
            let text = row.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let spellings = row.soundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            lines.append(text + (row.fixCase ? "!" : "") + (spellings.isEmpty ? "" : " = " + spellings.joined(separator: ", ")))
        }
        let rules = replacements.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
        if !rules.isEmpty {
            lines.append("")
            for rule in rules {
                lines.append(rule.from.trimmingCharacters(in: .whitespaces) + " -> " + rule.to.trimmingCharacters(in: .whitespaces))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A short note when a term may swap ordinary speech (Vocabulary's warning rules).
    static func warning(for row: TermRow) -> String? {
        let text = row.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // Names Toasty ships with are known; no warning.
        if DevVocabulary.catalogue.entries.contains(where: { $0.term.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return nil
        }
        return Vocabulary.parse(text).warnings.first
    }
}

struct DictationSettingsView: View {
    @StateObject private var editor = VocabularyEditor()
    @State private var selectedTerms = Set<VocabularyEditor.TermRow.ID>()
    @State private var selectedRules = Set<VocabularyEditor.ReplacementRow.ID>()

    var body: some View {
        Form {
            Section {
                Picker("Vocabulary", selection: $editor.scope) {
                    Text("Everywhere").tag(VocabularyEditor.Scope.global)
                    Text(editor.projectName.map { "This project (\($0))" } ?? "This project").tag(VocabularyEditor.Scope.project)
                        .disabled(editor.projectFolder == nil)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(editor.scope == .global
                     ? "Names you say in every project. Toasty already knows common developer tools and the names in your project."
                     : "Saved in the project's .toasty/vocabulary.txt, so you can commit it for your team. It comes before your everywhere vocabulary.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Table($editor.terms, selection: $selectedTerms) {
                    TableColumn("Term") { $row in
                        TextField("Name", text: $row.text).labelsHidden()
                            .overlay(alignment: .trailing) {
                                if let warning = VocabularyEditor.warning(for: row) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help(warning)
                                }
                            }
                    }
                    TableColumn("Sounds like") { $row in
                        TextField("Optional", text: $row.soundsLike).labelsHidden()
                    }
                    TableColumn("Fix case") { $row in
                        Toggle("", isOn: $row.fixCase).labelsHidden()
                            .help("Also fix the capitals of an ordinary English word (e.g. Codex)")
                    }
                    .width(56)
                }
                .frame(height: 170)
                AddRemove(add: { editor.terms.append(.init()) },
                          remove: { editor.terms.removeAll { selectedTerms.contains($0.id) } },
                          canRemove: !selectedTerms.isEmpty)
            } header: {
                Text("Terms")
            } footer: {
                Text("The speech engine favours these names when the audio fits. Prefer longer names: “Claude Code”, not “Claude”.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Table($editor.replacements, selection: $selectedRules) {
                    TableColumn("When I say") { $row in TextField("nimblest", text: $row.from).labelsHidden() }
                    TableColumn("Write") { $row in TextField("Nimbalyst", text: $row.to).labelsHidden() }
                }
                .frame(height: 120)
                AddRemove(add: { editor.replacements.append(.init()) },
                          remove: { editor.replacements.removeAll { selectedRules.contains($0.id) } },
                          canRemove: !selectedRules.isEmpty)
            } header: {
                Text("Replacements")
            } footer: {
                Text("Always applied to the text, for names the speech engine can't produce.")
                    .foregroundStyle(.secondary)
            }

            Section("Toasty adds by itself") {
                DisclosureGroup("Built in · \(names(DevVocabulary.catalogue.entries.count))") {
                    NameList(names: DevVocabulary.catalogue.entries.map(\.term.text))
                }
                DisclosureGroup("From \(editor.projectName ?? "this project") · \(names(editor.contextNames.count))") {
                    NameList(names: editor.contextNames)
                }
            }

            if let url = editor.fileURL {
                HStack {
                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        editor.flushSave()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 780)
        .onAppear { editor.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in editor.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in editor.flushSave() }
    }
}

private func names(_ n: Int) -> String { n == 1 ? "1 name" : "\(n) names" }

/// The macOS +/− pair under a table.
private struct AddRemove: View {
    let add: () -> Void
    let remove: () -> Void
    let canRemove: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) { Image(systemName: "plus").frame(width: 22, height: 18) }
                .help("Add")
            Button(action: remove) { Image(systemName: "minus").frame(width: 22, height: 18) }
                .disabled(!canRemove)
                .help("Remove Selected")
            Spacer()
        }
        .buttonStyle(.borderless)
    }
}

/// Read-only names, wrapped.
private struct NameList: View {
    let names: [String]
    var body: some View {
        Text(names.isEmpty ? "None yet." : names.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
