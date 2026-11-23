import AppKit
import SwiftUI

/// The window with no workspaces (a fresh install, or after closing the
/// last one): the sidebar and inspector have nothing to show and stay
/// hidden. The page asks for a folder and, since it's mostly seen once,
/// teaches the three essentials beneath it. A folder dropped anywhere on
/// the page opens too.
struct WelcomeView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Space.xxl)
            VStack(spacing: Theme.Space.s) {
                // As the conversation's empty state: the icon large and
                // faint; the words quiet beneath it.
                Image(systemName: "folder")
                    .font(.toasty(Theme.Glyph.emptyState, .ultraLight))
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, Theme.Space.m)
                Text("Welcome to Toasty")
                    .font(.toasty(Theme.Size.title, .semibold))
                    .foregroundStyle(.secondary)
                Text("Open a folder to start your first workspace.")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                OpenFolderButton { store.createWithFolderPicker() }
                    .padding(.top, Theme.Space.l)
            }
            // The essentials on a card like the composer's: the field
            // surface, its radius, border and lift.
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Things you should know to get started")
                    .font(.toasty(Theme.Size.meta, .semibold))
                    .foregroundStyle(Theme.headingBlue)
                    .accessibilityAddTraits(.isHeader)
                // Each with the glyph it has in the app.
                Tip(symbol: "folder", title: "Workspaces, tabs and headings",
                    detail: "Each workspace is a folder, and each tab is its own Claude chat. Group workspaces under headings in the sidebar.",
                    keys: "⌘T")
                Tip(symbol: "mic", title: "Dictation",
                    detail: "Hold Right Option and talk. Double-tap it to keep listening.",
                    keys: "Right ⌥")
                Tip(symbol: "square.grid.2x2", title: "Widgets",
                    detail: "Git, usage and terminals beside the conversation. Make spaces of your own, and switch with a swipe.",
                    keys: "⌃⌘I")
            }
            .padding(.horizontal, Theme.Inspector.edge)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.l + Theme.Space.xxs)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Surface.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
            .raisedShadow()
            .padding(.top, Theme.Space.xxl)
            Text("or drop a folder here")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.tertiary)
                .padding(.top, Theme.Space.l)
            // Two spacers below to one above: the block sits above the
            // middle, where the eye lands first.
            Spacer(minLength: Theme.Space.xxl)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Theme.Fill.faint : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.isFileURL }
            guard !folders.isEmpty else { return false }
            AppDelegate.shared.openFolders(folders)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// One essential, in the inspector rows' type: the glyph in a 16pt box,
/// a 13 name, a 12 line under it, and its key.
private struct Tip: View {
    let symbol: String
    let title: String
    let detail: String
    let keys: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s + Theme.Space.xxs) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Size.control))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Todo.box)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title)
                    .font(.toasty(Theme.Size.control, .medium))
                Text(detail)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            // One column for the keys, so every line wraps at the same width.
            KeyCap(keys: keys)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

/// The page's one action, as the bars' buttons: a glyph and a word in a
/// capsule, tinted with the accent (Return presses it).
private struct OpenFolderButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
                Image(systemName: "folder.badge.plus").font(.toasty(Theme.Size.control))
                Text("Open Folder…").font(.toasty(Theme.Size.control, .medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Theme.Space.m + Theme.Space.xxs)
            .frame(height: Theme.Control.height + Theme.Space.xs)
            .contentShape(Capsule())
        }
        .buttonStyle(BarButtonStyle(hovering: hovering, accent: true))
        .onHover { hovering = $0 }
        .keyboardShortcut(.defaultAction)
    }
}
