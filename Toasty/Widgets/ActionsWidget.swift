import AppKit
import Combine
import SwiftUI

// MARK: - Actions widget (an experiment)
//
// The commands a project keeps running (a dev server, a deploy, opening its
// local site), one click each, with their output in the widget's own
// terminal. Each action has a shell of its own in the widget, made the
// first time it runs and reused after; the list picks which one the well
// shows, and ▶ types the command into it as if you had. Actions are kept
// per folder in Toasty (`actions.json`), not in the project.
//
// Everything it needs is here; the rest of the app knows it by
// `WidgetKind.actions` alone (the gallery, its size limits,
// `WidgetContent`). To remove it: take `.actions` out of
// `WidgetKind.gallery`, its case in `WidgetContent`, and this file.

/// One command a project runs.
struct ProjectAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    /// Asks before running (a production deploy).
    var confirm = false
}

/// Every folder's actions, saved in Toasty's support folder.
@MainActor
final class ProjectActions: ObservableObject {
    static let shared = ProjectActions()

    @Published private(set) var byFolder: [String: [ProjectAction]] = [:]

    private static var url: URL {
        WorkspaceStore.stateURL.deletingLastPathComponent().appendingPathComponent("actions.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([String: [ProjectAction]].self, from: data) {
            byFolder = saved
        }
    }

    func list(for folder: String) -> [ProjectAction] { byFolder[Self.key(folder)] ?? [] }

    /// Adds it, or replaces the one with its id.
    func save(_ action: ProjectAction, in folder: String) {
        var list = list(for: folder)
        if let i = list.firstIndex(where: { $0.id == action.id }) { list[i] = action } else { list.append(action) }
        set(list, in: folder)
    }

    func delete(_ id: UUID, in folder: String) {
        set(list(for: folder).filter { $0.id != id }, in: folder)
    }

    func reorder(from: IndexSet, to: Int, in folder: String) {
        var list = list(for: folder)
        list.move(fromOffsets: from, toOffset: to)
        set(list, in: folder)
    }

    private func set(_ list: [ProjectAction], in folder: String) {
        byFolder[Self.key(folder)] = list.isEmpty ? nil : list
        let url = Self.url
        if let data = try? JSONEncoder().encode(byFolder) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func key(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.path
    }
}

extension Workspace {
    /// Whose actions it uses: a worktree shares its repository's (they
    /// still run in the worktree's own folder).
    var actionsFolder: String { parent?.folder ?? folder }
}

// MARK: - The widget

struct ActionsWidget: View {
    @ObservedObject var workspace: Workspace
    let item: WidgetItem
    @Environment(\.widgetPreview) private var preview

    var body: some View {
        if preview {
            VStack(spacing: 0) {
                WidgetHeader(kind: .actions)
                ActionRowLook(name: "Dev Server", selected: true, running: true)
                ActionRowLook(name: "Deploy Staging", selected: false, running: false)
                ActionWell {
                    VStack(spacing: 0) {
                        ActionBarLook(name: "Dev Server", state: "Running") { EmptyView() }
                        ActionPlaceholder(text: "$ npm run dev")
                    }
                }
            }
        } else {
            ActionsBody(workspace: workspace, item: item,
                        runner: ActionRunners.shared.runner(for: item.id, in: workspace),
                        store: ProjectActions.shared)
        }
    }
}

private struct ActionsBody: View {
    @ObservedObject var workspace: Workspace
    let item: WidgetItem
    @ObservedObject var runner: ActionRunner
    @ObservedObject var store: ProjectActions
    /// The + popover: adding, changing, reordering and removing actions.
    @State private var managing = false

    private var actions: [ProjectAction] { store.list(for: workspace.actionsFolder) }
    /// The action whose output is open below the list, if any.
    private var shown: ProjectAction? {
        actions.first { $0.id == runner.shownID && runner.sessions[$0.id] != nil }
    }

    /// Fit: the list alone, until an output is open (then all of its size).
    private var fit: CGFloat? {
        let size = WidgetSize(span: 2, units: item.units)
        if actions.isEmpty { return size.fitHeight(count: 0) }
        if shown != nil { return WidgetGrid.height(item.units) }
        return WidgetGrid.headerHeight + listHeight + Theme.Space.s
    }

    private var listHeight: CGFloat { CGFloat(min(actions.count, 5)) * Theme.Widget.rowHeight }

    var body: some View {
        VStack(spacing: 0) {
            WidgetHeader(kind: .actions) {
                InspectorControl(symbol: "plus", tooltip: Tooltip(title: "Add or Change Actions",
                                                                 detail: "The commands you run in this project, one click each from here.")) {
                    managing = true
                }
                .padding(.trailing, -Theme.Space.xs)
            }
            if actions.isEmpty {
                EmptyLine(text: "No actions yet.\nAdd the commands you run here, like a deploy, with +.")
            } else {
                list
                if let shown, let session = runner.sessions[shown.id] {
                    ActionWell {
                        VStack(spacing: 0) {
                            ActionOutputBar(action: shown, runner: runner)
                            TerminalHost(session: session)
                                .id(session.id)
                                .padding(.bottom, Theme.Space.xs)
                        }
                    }
                }
            }
        }
        // It only shrinks when you close or hide an output: at once.
        .reportsFit(fit, workspace: workspace.id, promptly: true)
        .popover(isPresented: $managing, arrowEdge: .leading) {
            ActionsManager(folder: workspace.actionsFolder, runsIn: workspace.folder) { managing = false }
        }
    }

    /// Up to five rows; more scroll.
    private var list: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(actions) { a in
                    ActionRow(action: a, selected: a.id == shown?.id, runner: runner, run: { run(a) })
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(height: listHeight)
        .padding(.bottom, Theme.Space.xs)
    }

    private func run(_ a: ProjectAction) {
        guard a.confirm else { runner.run(a); return }
        let alert = NSAlert()
        alert.messageText = "Run \(a.name)?"
        alert.informativeText = a.command
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let go = { (r: NSApplication.ModalResponse) in if r == .alertFirstButtonReturn { runner.run(a) } }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: go) } else { go(alert.runModal()) }
    }
}

/// An action's row: its name, selected while the well shows its shell, and
/// ▶ (■ while it's running).
private struct ActionRow: View {
    let action: ProjectAction
    let selected: Bool
    @ObservedObject var runner: ActionRunner
    let run: () -> Void

    var body: some View {
        let running = runner.isRunning(action.id)
        let ran = runner.sessions[action.id] != nil
        // Running, its row says so; its output bar has ■.
        ActionRowLook(name: action.name, selected: selected, running: running, open: ran,
                      tap: { runner.toggle(action.id) }) {
            if !running {
                InspectorControl(symbol: "play.fill", tooltip: Tooltip(title: "Run", detail: action.command)) { run() }
            }
        }
        .contextMenu {
            if running {
                Button("Stop") { runner.stop(action.id) }
            } else {
                Button("Run") { run() }
            }
            Button("Close Terminal") { runner.forget(action.id) }
                .disabled(!ran)
        }
    }
}

/// The row as drawn (also the gallery's picture).
private struct ActionRowLook<Trailing: View>: View {
    let name: String
    let selected: Bool
    let running: Bool
    /// Its output is open (running or finished): a dot, green while running.
    var open = false
    /// A click on the row (not its ▶): shows or hides its terminal.
    var tap: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // A real button: a tap gesture here loses its clicks.
            Button { tap?() } label: {
                HStack(spacing: Theme.Space.s) {
                    Circle()
                        .fill(running ? Color.green : open ? Color.secondary : Color.clear)
                        .frame(width: 6, height: 6)
                    Text(name)
                        .font(.toasty(Theme.Size.control, selected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Space.xs)
                    if running {
                        Text("Running")
                            .font(.toasty(Theme.Size.meta))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, Theme.Space.xxs)
        .frame(height: Theme.Widget.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(selected ? Theme.Fill.selected : hovering && tap != nil ? Theme.Fill.hover : Color.clear))
        .padding(.horizontal, Theme.Widget.rowInset)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension ActionRowLook where Trailing == EmptyView {
    init(name: String, selected: Bool, running: Bool) {
        self.init(name: name, selected: selected, running: running, open: running, tap: nil, trailing: { EmptyView() })
    }
}

/// The top of the output: whose it is and how it stands, with ■ while it
/// runs and × once it's done (clearing it).
private struct ActionOutputBar: View {
    let action: ProjectAction
    @ObservedObject var runner: ActionRunner

    var body: some View {
        let running = runner.isRunning(action.id)
        ActionBarLook(name: action.name, state: running ? "Running" : runner.hasRun(action.id) ? "Finished" : "Ready") {
            if running {
                InspectorControl(symbol: "stop.fill", tooltip: Tooltip(title: "Stop", detail: "Sends Control-C, as if you pressed it.")) {
                    runner.stop(action.id)
                }
            } else {
                InspectorControl(symbol: "xmark", tooltip: Tooltip(title: "Close", detail: "Clears this output. ▶ starts it fresh.")) {
                    runner.forget(action.id)
                }
            }
        }
    }
}

private struct ActionBarLook<Trailing: View>: View {
    let name: String
    let state: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(name)
                .font(.toasty(Theme.Size.meta, .medium))
                .lineLimit(1)
            Text("·").foregroundStyle(.tertiary)
            Text(state)
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            trailing()
        }
        .font(.toasty(Theme.Size.meta))
        // Its text starts where the terminal's does.
        .padding(.leading, TerminalTheme.paddingX)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: Theme.Widget.rowHeight + Theme.Space.xs)
    }
}

/// A command found in the project, in the New Action popover.
private struct SuggestionRow: View {
    let action: ProjectAction
    let picked: Bool
    let pick: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Theme.Space.s) {
                Text(action.name)
                    .font(.toasty(Theme.Size.control, picked ? .medium : .regular))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: Theme.Space.m)
                Text(action.command)
                    .font(.system(size: Theme.Size.meta - 1, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "checkmark")
                    .font(.toasty(Theme.Size.meta, .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(picked ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(picked ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.command)
    }
}

/// The terminal's well, as the Terminal widget's.
private struct ActionWell<Inside: View>: View {
    @ViewBuilder var inside: () -> Inside

    var body: some View {
        ZStack {
            TerminalBackdrop()
            inside()
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding([.horizontal, .bottom], Theme.Widget.rowInset)
    }
}

/// The well before an action has run: its command, waiting.
private struct ActionPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Theme.Size.meta, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, TerminalTheme.paddingX)
            .padding(.vertical, TerminalTheme.paddingY)
    }
}

/// The + popover: everything about the project's actions in one place.
/// Its list (dragged to reorder, a click to edit, × to remove), and under
/// it the form that adds one (filled from the project's own commands, or
/// typed) or, with one picked, changes it.
private struct ActionsManager: View {
    /// Where its actions are kept (a worktree's repository).
    let folder: String
    /// Where they run, and whose commands are offered.
    let runsIn: String
    let done: () -> Void
    @ObservedObject private var store = ProjectActions.shared
    /// What the form holds: a new action, or a copy of the one being edited.
    @State private var form = ProjectAction(name: "", command: "")
    @State private var editingID: UUID?
    @State private var found: [ActionSuggestions.Group] = []
    /// The row being dragged to a new place, and how far it's gone.
    @State private var dragID: UUID?
    @State private var dragY: CGFloat = 0

    private static let width: CGFloat = 340

    private var actions: [ProjectAction] { store.list(for: folder) }
    private var editing: Bool { editingID != nil }

    /// The project's commands not yet added.
    private var offered: [ProjectAction] {
        let have = Set(actions.map(\.command))
        return found.flatMap(\.actions).filter { !have.contains($0.command) }
    }

    private var valid: Bool {
        !form.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !form.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Actions")
                .font(.toasty(Theme.Size.control, .semibold))
            if !actions.isEmpty {
                label("In this widget", detail: "Drag to reorder. Click one to change it.")
                    .padding(.top, Theme.Space.m)
                list.padding(.top, Theme.Space.s)
            }
            label(editing ? "Change \u{201C}\(actions.first { $0.id == editingID }?.name ?? "")\u{201D}" : "Add an action",
                  detail: editing ? nil : offered.isEmpty ? nil : "Pick one of the project's commands, or type your own.")
                .padding(.top, actions.isEmpty ? Theme.Space.m : Theme.Space.l)
            if !editing, !offered.isEmpty {
                suggestions.padding(.top, Theme.Space.s)
            }
            fields
            buttons.padding(.top, Theme.Space.l)
        }
        .padding(Theme.Space.l)
        .frame(width: Self.width + Theme.Space.l * 2)
        .onAppear { found = ActionSuggestions.scan(runsIn) }
    }

    // MARK: Pieces

    private var list: some View {
        let h = SuggestionRow.height
        let from = dragID.flatMap { id in actions.firstIndex { $0.id == id } }
        // Where the dragged row would land: rows between slide over a place.
        let to = from.map { min(max($0 + Int((dragY / h).rounded()), 0), actions.count - 1) }
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                    let dragged = a.id == dragID
                    ManagerRow(action: a, picked: a.id == editingID, lifted: dragged) {
                        editingID = a.id
                        form = a
                    } remove: {
                        if editingID == a.id { clear() }
                        ActionRunners.shared.forget(action: a.id)
                        store.delete(a.id, in: folder)
                    }
                    .offset(y: dragged ? dragY : shift(i, from: from, to: to) * h)
                    .zIndex(dragged ? 1 : 0)
                    .animation(dragged ? nil : .easeOut(duration: 0.15), value: to)
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { g in
                            if dragID == nil { dragID = a.id }
                            // Not past the list's ends.
                            dragY = min(max(g.translation.height, -CGFloat(i) * h), CGFloat(actions.count - 1 - i) * h)
                        }
                        .onEnded { _ in
                            if let from, let to, from != to {
                                store.reorder(from: IndexSet(integer: from), to: to > from ? to + 1 : to, in: folder)
                            }
                            dragID = nil
                            dragY = 0
                        })
                }
            }
            .padding(Theme.Space.xxs)
        }
        .scrollDisabled(dragID != nil)
        .frame(height: CGFloat(min(actions.count, 5)) * h + Theme.Space.xxs * 2
               + (actions.count > 5 ? h / 2 : 0))
        .card()
    }

    /// Rows a row moves while another is dragged from `from` to `to`.
    private func shift(_ i: Int, from: Int?, to: Int?) -> CGFloat {
        guard let from, let to else { return 0 }
        if from < to, i > from, i <= to { return -1 }
        if to < from, i >= to, i < from { return 1 }
        return 0
    }

    private var suggestions: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(offered) { a in
                    SuggestionRow(action: a, picked: form.command == a.command) {
                        form.name = a.name
                        form.command = a.command
                    }
                }
            }
            .padding(Theme.Space.xxs)
        }
        .frame(height: CGFloat(min(offered.count, 4)) * SuggestionRow.height + Theme.Space.xxs * 2
               + (offered.count > 4 ? SuggestionRow.height / 2 : 0))
        .card()
    }

    @ViewBuilder private var fields: some View {
        label("Name").padding(.top, Theme.Space.m)
        TextField("Shown in the widget", text: $form.name)
            .textFieldStyle(.roundedBorder)
            .padding(.top, Theme.Space.xs)
        label("Command").padding(.top, Theme.Space.m)
        TextField("Runs in \((runsIn as NSString).lastPathComponent)", text: $form.command)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: Theme.Size.meta, design: .monospaced))
            .padding(.top, Theme.Space.xs)
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("Ask before running").font(.toasty(Theme.Size.control))
                Text("For anything you don't want run by accident, like a production deploy.")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("Ask before running", isOn: $form.confirm)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.top, Theme.Space.m)
    }

    private var buttons: some View {
        HStack {
            if editing {
                Spacer()
                Button("Cancel") { clear() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            } else {
                Button("Done") { done() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
    }

    /// A section's name (and a line about it).
    private func label(_ text: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(text)
                .font(.toasty(Theme.Size.meta, .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Changes

    /// Adds the form's action (or saves the one being changed); the form
    /// clears for the next.
    private func commit() {
        var a = form
        a.name = a.name.trimmingCharacters(in: .whitespaces)
        a.command = a.command.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(a, in: folder)
        clear()
    }

    private func clear() {
        editingID = nil
        form = ProjectAction(name: "", command: "")
    }
}

/// One of the widget's actions, in the manager: grab it to reorder, click it
/// to change it, × to remove it.
private struct ManagerRow: View {
    let action: ProjectAction
    let picked: Bool
    /// Being dragged: raised over the others.
    var lifted = false
    let edit: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.tertiary)
            Text(action.name)
                .font(.toasty(Theme.Size.control, picked ? .medium : .regular))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.m)
            Text(action.command)
                .font(.system(size: Theme.Size.meta - 1, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.toasty(Theme.Size.meta - 1, .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering && !lifted ? 1 : 0)
            .help("Remove \u{201C}\(action.name)\u{201D}")
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: SuggestionRow.height)
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Surface.floating)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(picked ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Color.clear)
            }
        }
        .scaleEffect(lifted ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: lifted)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { edit() }
    }
}

private extension View {
    /// A quiet card a list sits in.
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.Fill.faint))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Theme.Fill.subtle, lineWidth: 1))
    }
}

// MARK: - Running

/// One Actions widget's shells, in one workspace: a shell per action that
/// has run, and the action the well shows.
@MainActor
final class ActionRunner: ObservableObject {
    @Published private(set) var sessions: [UUID: TerminalSession] = [:]
    /// The action whose output is open below the list (nil: just the list).
    @Published private(set) var shownID: UUID?
    private let folder: String
    private var watching: [UUID: AnyCancellable] = [:]
    @Published private var ran: Set<UUID> = []

    init(folder: String) {
        self.folder = folder
    }

    /// Its command is still going (the shell isn't at its prompt).
    func isRunning(_ id: UUID) -> Bool { sessions[id]?.program != nil }

    func show(_ id: UUID?) {
        if shownID != id { shownID = id }
    }

    /// Shows its terminal, or hides it if it's the one showing. One that
    /// hasn't been opened gets a shell in the folder, its command not run
    /// (▶ runs it).
    func toggle(_ id: UUID) {
        if sessions[id] == nil { _ = start(id) }
        show(shownID == id ? nil : id)
    }

    /// Its command has been run in its shell (else the shell is just open).
    func hasRun(_ id: UUID) -> Bool { ran.contains(id) }

    /// Shows its shell and types the command into it; if it's still
    /// running, only shows it (a second dev server would fight the first).
    func run(_ action: ProjectAction) {
        show(action.id)
        if isRunning(action.id) { return }
        let session = sessions[action.id] ?? start(action.id)
        ran.insert(action.id)
        Self.type(action.command, into: session.view.terminal)
    }

    /// Types the command once the shell has drawn its prompt (typed before,
    /// the terminal echoes it and the shell prints it again).
    private static func type(_ command: String, into terminal: TerminalView, tries: Int = 60) {
        let ready = !terminal.vt.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard ready || tries == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { type(command, into: terminal, tries: tries - 1) }
            return
        }
        terminal.insertPaste(command)
        terminal.pty?.write(Data("\r".utf8))
    }

    /// Control-C, as if pressed in its shell.
    func stop(_ id: UUID) {
        sessions[id]?.terminalView?.pty?.write(Data([0x03]))
    }

    /// Its shell ends (the action was deleted).
    func forget(_ id: UUID) {
        if let s = sessions[id] { s.onExit = nil; s.terminate() }
        sessions[id] = nil
        watching[id] = nil
        ran.remove(id)
        if shownID == id { shownID = nil }
    }

    func terminateAll() {
        for id in Array(sessions.keys) { forget(id) }
    }

    private func start(_ id: UUID) -> TerminalSession {
        let s = TerminalSession(cwd: folder)
        // `exit` in it: the next run starts a fresh shell.
        s.onExit = { [weak self] in self?.forget(id) }
        sessions[id] = s
        // Its running state shows in the row.
        watching[id] = s.$program.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() }
        return s
    }
}

/// Every Actions widget's shells, by workspace and widget. A removed
/// widget's (or a closed workspace's) shells end.
@MainActor
final class ActionRunners {
    static let shared = ActionRunners()

    private struct Key: Hashable {
        let workspace: UUID
        let widget: UUID
    }

    private var all: [Key: ActionRunner] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let store = WorkspaceStore.shared
        store.$spaces
            .combineLatest(store.$workspaces)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces, workspaces in self?.prune(spaces: spaces, workspaces: workspaces) }
            .store(in: &cancellables)
    }

    func runner(for widget: UUID, in workspace: Workspace) -> ActionRunner {
        let key = Key(workspace: workspace.id, widget: widget)
        if let r = all[key] { return r }
        let r = ActionRunner(folder: workspace.folder)
        all[key] = r
        return r
    }

    /// A deleted action's shells end, in every widget.
    func forget(action id: UUID) {
        for r in all.values { r.forget(id) }
    }

    private func prune(spaces: [WidgetSpace], workspaces: [Workspace]) {
        let widgets = Set(spaces.flatMap(\.widgets).filter { $0.kind == .actions }.map(\.id))
        let open = Set(workspaces.map(\.id))
        for (key, r) in all where !widgets.contains(key.widget) || !open.contains(key.workspace) {
            all[key] = nil
            r.terminateAll()
        }
    }
}

// MARK: - Found in the project

/// Commands a project already names, offered when adding an action: its
/// package.json and composer.json scripts, Makefile and justfile targets,
/// Envoy tasks, Deployer hosts, and its local site under Herd or Valet.
enum ActionSuggestions {
    struct Group: Identifiable {
        let source: String
        let actions: [ProjectAction]
        var id: String { source }
    }

    static func scan(_ folder: String) -> [Group] {
        let root = URL(fileURLWithPath: folder)
        func text(_ names: String...) -> String? {
            for n in names { if let s = try? String(contentsOf: root.appendingPathComponent(n), encoding: .utf8) { return s } }
            return nil
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
        func json(_ name: String) -> [String: Any]? {
            guard let s = text(name), let d = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        var groups: [Group] = []
        func add(_ source: String, _ items: [(name: String, command: String)]) {
            var seen = Set<String>()
            let list = items.filter { seen.insert($0.command).inserted }.map { ProjectAction(name: $0.name, command: $0.command) }
            if !list.isEmpty { groups.append(Group(source: source, actions: list)) }
        }

        // package.json: its scripts, by the package manager its lockfile says.
        if let scripts = json("package.json")?["scripts"] as? [String: Any] {
            let runner = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn"
                : exists("bun.lockb") || exists("bun.lock") ? "bun run" : "npm run"
            let hooks: Set<String> = ["preinstall", "install", "postinstall", "prepare", "prepublish", "prepublishOnly", "prepack", "postpack"]
            let names = scripts.keys.filter { k in
                if hooks.contains(k) { return false }
                for p in ["pre", "post"] where k.hasPrefix(p) && scripts[String(k.dropFirst(p.count))] != nil { return false }
                return true
            }
            add("package.json", ordered(names, in: text("package.json")).map { (title($0), "\(runner) \($0)") })
        }
        // composer.json: its scripts, not Composer's own events (pre-/post-).
        if let scripts = json("composer.json")?["scripts"] as? [String: Any] {
            let names = scripts.keys.filter { !$0.hasPrefix("pre-") && !$0.hasPrefix("post-") }
            add("composer.json", ordered(names, in: text("composer.json")).map { (title($0), "composer run \($0)") })
        }
        // Envoy (Laravel): its stories and tasks.
        if let s = text("Envoy.blade.php") {
            let envoy = exists("vendor/bin/envoy") ? "vendor/bin/envoy" : "envoy"
            add("Envoy", matches(#"@(?:story|task)\(\s*['"]([^'"]+)['"]"#, in: s).map { (title($0), "\(envoy) run \($0)") })
        }
        // Deployer: a deploy to each host.
        if let s = text("deploy.php") {
            let dep = exists("vendor/bin/dep") ? "vendor/bin/dep" : "dep"
            add("Deployer", matches(#"host\(\s*['"]([^'"]+)['"]"#, in: s).map { ("Deploy \(title($0))", "\(dep) deploy \($0)") })
        }
        // Makefile: its targets (not special or pattern ones, not variables).
        if let s = text("Makefile", "makefile", "GNUmakefile") {
            let targets = matches(#"(?m)^([A-Za-z0-9][A-Za-z0-9_.\-/]*)\s*:(?![=:])"#, in: s)
            add("Makefile", targets.map { (title($0), "make \($0)") })
        }
        // justfile: its recipes.
        if let s = text("justfile", "Justfile", ".justfile") {
            let recipes = matches(#"(?m)^@?([A-Za-z0-9_-]+)(?:[ \t][^:\n]*)?:(?!=)"#, in: s)
                .filter { !["set", "export", "alias", "import", "mod"].contains($0) }
            add("justfile", recipes.map { (title($0), "just \($0)") })
        }
        // Herd or Valet: the site they serve this folder at.
        if exists("artisan") || exists("public/index.php"), let tld = localTLD() {
            let host = root.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
            add(FileManager.default.fileExists(atPath: herdConfig.path) ? "Herd" : "Valet",
                [("Open Site", "open https://\(host).\(tld)/")])
        }
        return groups
    }

    private static var herdConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Herd/config/valet/config.json")
    }

    /// The domain Herd (or Valet) serves sites under ("test").
    private static func localTLD() -> String? {
        let valet = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/valet/config.json")
        for url in [herdConfig, valet] {
            guard let d = try? Data(contentsOf: url) else { continue }
            let tld = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["tld"] as? String
            return tld ?? "test"
        }
        return nil
    }

    /// Keys in the order the file writes them (JSON objects have none).
    private static func ordered(_ keys: [String], in source: String?) -> [String] {
        guard let source else { return keys.sorted() }
        func at(_ k: String) -> String.Index { source.range(of: "\"\(k)\"")?.lowerBound ?? source.endIndex }
        return keys.sorted { at($0) < at($1) }
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    /// "deploy:staging" → "Deploy Staging".
    static func title(_ key: String) -> String {
        key.split(whereSeparator: { ":-_./ ".contains($0) })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
