import AppKit
import SwiftUI

// MARK: - Diff page (in the conversation column)

/// A changed file's diff against the last commit, in place of the
/// conversation until closed (Esc or the back button).
struct DiffPage: View {
    let file: GitChanges.File
    /// Every changed file, for the previous / next buttons.
    var files: [GitChanges.File] = []
    var select: (GitChanges.File) -> Void = { _ in }
    let close: () -> Void
    @State private var lines: [DiffLine]?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            if let lines {
                if lines.isEmpty {
                    InspectorEmpty(symbol: "doc", title: "No Line Changes",
                                   detail: file.status == .renamed ? "The file was renamed without edits." : nil)
                } else {
                    DiffTextView(lines: lines, path: file.path)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.claudeBackground)
        .task(id: file) {
            lines = nil
            let f = file
            let loaded = await Task.detached(priority: .userInitiated) { GitChanges.diffLines(f) }.value
            // Another file was chosen while this one loaded.
            guard !Task.isCancelled else { return }
            lines = loaded
        }
    }

    private var position: Int? { files.firstIndex { $0.id == file.id } }

    private func step(_ by: Int) {
        guard let i = position, files.indices.contains(i + by) else { return }
        select(files[i + by])
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.toasty(Theme.Size.meta, .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .tooltip("Back to Conversation", shortcut: "esc")
            .accessibilityLabel("Back to Conversation")

            ChangeLetter(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.toasty(Theme.Size.control, .semibold)).lineLimit(1)
                Text(file.directory.isEmpty ? file.status.label : "\(file.status.label) · \(file.directory)")
                    .font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            DiffCounts(added: file.added, removed: file.removed)
            if files.count > 1, let i = position {
                Text("\(i + 1) of \(files.count)")
                    .font(.toasty(Theme.Size.meta)).foregroundStyle(.tertiary).monospacedDigit()
                    .padding(.leading, Theme.Space.s)
                HStack(spacing: 0) {
                    BarIconButton(symbol: "chevron.up",
                                  tooltip: Tooltip(title: "Previous File", shortcut: "⌃⌘↑")) { step(-1) }
                        .disabled(i == 0)
                        .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                    BarIconButton(symbol: "chevron.down",
                                  tooltip: Tooltip(title: "Next File", shortcut: "⌃⌘↓")) { step(1) }
                        .disabled(i == files.count - 1)
                        .keyboardShortcut(.downArrow, modifiers: [.control, .command])
                }
            }
            if file.status != .deleted {
                OpenExternallyButton(file: file.url, project: file.root, detail: file.path)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}
