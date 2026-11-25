import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers
import SwiftUI

// MARK: - File page (in the conversation column)
//
// A file from the Files widget, in place of the conversation until closed
// (Esc or the back button), as the Git widget's diff page is. Toasty only
// shows files: Claude edits them, and "Open in Default App" is one click.
//
// - Code and text: the diff page's text view, every line with its number,
//   in syntax colors. Select lines and a Comment pill shows by them (the
//   keyboard stays in the text, so ⌘C copies); click it or press Return
//   and the browser's comment box opens in its place: "Comment on @path
//   (lines 12-30): …" goes to a tab or Tee-Up.
//   The @ button opens it for the whole file.
// - Markdown: rendered as replies are (Preview), or its source.
// - Images at their size, PDFs in PDFKit; anything else in Quick Look.
// - A changed file can switch to its diff (the same page, a mode).
//
// It follows the file on disk: when Claude changes it, it shows the change.

struct FilePage: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var changes: GitChanges
    let url: URL
    let close: () -> Void

    enum Mode: String { case preview = "Preview", source = "Source", file = "File", diff = "Diff" }

    @State private var content: FileContent?
    @State private var mode: Mode?
    @State private var diff: [DiffLine]?
    @State private var modified: Date?
    /// The comment being written, and where its box sits.
    @State private var comment: FileComment?
    @State private var commentHeight = CommentField.restingHeight
    /// The tab comments go to, when one is pinned in the box.
    @State private var pinnedTab: UUID?
    @State private var confirmation: String?
    @ObservedObject private var settings = PreviewSettings.shared

    /// Lines (or the whole file), and the selection's place on the page.
    struct FileComment: Equatable {
        var id = UUID()
        let lines: ClosedRange<Int>?
        var rect: CGRect?
        /// The box; false: only the pill that opens it.
        var open = true
    }

    private var change: GitChanges.File? {
        changes.files.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path && $0.status != .deleted }
    }

    private var modes: [Mode] {
        var out: [Mode] = content?.isMarkdown == true ? [.preview, .source] : [.file]
        if change != nil { out.append(.diff) }
        return out.count > 1 ? out : []
    }

    private var shownMode: Mode {
        if let mode, modes.contains(mode) { return mode }
        return content?.isMarkdown == true ? .preview : .file
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            page
                .overlay(alignment: .topLeading) { commentBox }
                .overlay(alignment: .bottom) { confirmationLabel }
                .clipped()
        }
        .background(Color.claudeBackground)
        .onChange(of: shownMode) { _, _ in comment = nil }
        .task(id: confirmation) {
            guard confirmation != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { confirmation = nil }
        }
        .task(id: url) {
            content = nil
            diff = nil
            comment = nil
            modified = Self.modificationDate(url)
            await load()
            // Follow the file: Claude's edits show as they land.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Self.modificationDate(url)
                if now != modified {
                    modified = now
                    await load()
                }
            }
        }
        .task(id: "\(url.path)|\(shownMode.rawValue)|\(modified?.timeIntervalSince1970 ?? 0)") {
            guard shownMode == .diff, let change else { return }
            let f = change
            let loaded = await Task.detached(priority: .userInitiated) { GitChanges.diffLines(f) }.value
            guard !Task.isCancelled else { return }
            diff = loaded
        }
    }

    private func load() async {
        let u = url
        let loaded = await Task.detached(priority: .userInitiated) { FileContent.load(u) }.value
        guard !Task.isCancelled else { return }
        content = loaded
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: Page

    @ViewBuilder private var page: some View {
        switch content {
        case nil:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            InspectorEmpty(symbol: "doc", title: "File Not Found", detail: "It was moved or deleted.")
        case .text(let lines, let markdown):
            switch shownMode {
            case .diff: diffPage
            case .preview: MarkdownPreview(markdown: markdown ?? "", cwd: (url.path as NSString).deletingLastPathComponent)
            default:
                FileTextView(lines: lines, path: url.path, commentID: comment?.lines == nil ? nil : comment?.id) { lines, rect, open in
                    comment = lines.map { FileComment(lines: $0, rect: rect, open: open) }
                } moved: { rect in
                    comment?.rect = rect
                } returnPressed: {
                    guard comment?.open == false else { return false }
                    comment?.open = true
                    return true
                }
            }
        case .other:
            if shownMode == .diff {
                diffPage
            } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) {
                PDFPreview(url: url).id(modified)
            } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let image = NSImage(contentsOf: url) {
                ImagePreview(image: image, url: url).id(modified)
            } else {
                QuickLookView(url: url).id(modified)
            }
        }
    }

    @ViewBuilder private var diffPage: some View {
        if let diff {
            if diff.isEmpty {
                InspectorEmpty(symbol: "doc", title: "No Line Changes", detail: nil)
            } else {
                DiffTextView(lines: diff, path: url.path).id(modified)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private var relativeFolder: String {
        let folder = (url.path as NSString).deletingLastPathComponent
        let root = workspace.folder.hasSuffix("/") ? workspace.folder : workspace.folder + "/"
        if folder == workspace.folder { return (workspace.folder as NSString).lastPathComponent }
        return folder.hasPrefix(root) ? String(folder.dropFirst(root.count)) : (folder as NSString).abbreviatingWithTildeInPath
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Esc: a comment (or its pill) first, then the page.
            Button { if comment != nil { comment = nil } else { close() } } label: {
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

            if let change {
                ChangeLetter(status: change.status)
            } else {
                Image(systemName: "doc").font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary)
                    .frame(width: Theme.Todo.box)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.toasty(Theme.Size.control, .semibold)).lineLimit(1)
                Text(change.map { "\($0.status.label) · \(relativeFolder)" } ?? relativeFolder)
                    .font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if !modes.isEmpty {
                ModePicker(modes: modes, selection: Binding(get: { shownMode }, set: { mode = $0 }))
            }
            HStack(spacing: 0) {
                BarIconButton(symbol: "at", tooltip: Tooltip(title: "Comment on File",
                                                             detail: "Write Claude a note about this file. Select lines to comment on just those.")) {
                    comment = comment?.lines == nil && comment != nil ? nil : FileComment(lines: nil)
                }
                OpenExternallyButton(file: url, project: workspace.folder, detail: url.lastPathComponent)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Comments

    /// The browser's comment box: under the selected lines (above them
    /// when there's no room), or under the header's @ for the whole file.
    @ViewBuilder private var commentBox: some View {
        if let comment, !comment.open {
            GeometryReader { geo in
                let size = CommentPill.size
                let frame = commentFrame(comment, in: geo.size, size: size)
                CommentPill { self.comment?.open = true }
                    .fixedSize()
                    .offset(x: frame.minX, y: frame.minY)
                    .transition(.opacity)
            }
        } else if let comment {
            GeometryReader { geo in
                let frame = commentFrame(comment, in: geo.size)
                CommentField(destination: $settings.commentsTo, workspace: workspace.id, height: $commentHeight,
                             tabs: CommentTabs(workspace: workspace, pinnedID: $pinnedTab),
                             sendTip: "Send the comment to Claude now.") { note, images, files in
                    send(comment, note: note, images: images, files: files)
                } cancel: {
                    self.comment = nil
                }
                // Opaque over the code (the browser's sits over a page).
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Color.claudeBackground))
                // At least its width, wider when its controls need it
                // (a long tab name), growing right from where it's placed.
                .frame(minWidth: frame.width, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .id(comment.id)
            }
        }
    }

    private func commentFrame(_ c: FileComment, in pane: CGSize, size: CGSize? = nil) -> CGRect {
        let width = size?.width ?? min(CommentField.width, max(120, pane.width - 16))
        let height = size?.height ?? commentHeight
        guard let rect = c.rect else {
            return CGRect(x: max(8, pane.width - width - 12), y: 8, width: width, height: height)
        }
        // By the code, not the gutter; under the selection, else above.
        let x = min(max(8, rect.minX), max(8, pane.width - width - 8))
        var y = rect.maxY + 6
        if y + height > pane.height - 8 { y = rect.minY - 6 - height }
        y = min(max(8, y), max(8, pane.height - height - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    @ViewBuilder private var confirmationLabel: some View {
        if let confirmation {
            Label(confirmation, systemImage: "checkmark")
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.toasty(Theme.Size.meta, .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.claudeField).shadow(color: .black.opacity(0.22), radius: 8, y: 2))
                .overlay(Capsule().strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
                .padding(.bottom, 14)
                .transition(.opacity)
        }
    }

    /// "Comment on @path (lines 12-30): note", to the tab (pinned, else the
    /// last selected; a new one when there's none) or onto Tee-Up. The page
    /// stays, for the next comment.
    private func send(_ c: FileComment, note: String, images: [NSImage], files: [URL]) {
        let pinned = pinnedTab.flatMap { id in workspace.conversations.first { $0.id == id } }
        let existing = pinned ?? workspace.selected
        let cwd = existing?.cwd ?? workspace.folder
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "Comment on " + Workspace.mentionToken(url, cwd: cwd, lines: c.lines) + (trimmed.isEmpty ? "" : ": \(trimmed)")
        switch settings.commentDestination {
        case .teeUp:
            var item = TeeUp(text: line)
            images.forEach { item.attach($0) }
            if !files.isEmpty { item.attach(files) }
            workspace.addTeeUp(item)
            withAnimation(.easeOut(duration: 0.15)) { confirmation = "Added to Tee-Up" }
        case .conversation:
            let sentTo = existing.map { "Sent to “\($0.title)”" } ?? "Sent to a new conversation"
            let tab = existing ?? workspace.newConversation(select: false)
            tab.post(line, images: images, files: files)
            withAnimation(.easeOut(duration: 0.15)) { confirmation = sentTo }
        }
        comment = nil
    }

    static func lines(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? "Line \(r.lowerBound)" : "Lines \(r.lowerBound)–\(r.upperBound)"
    }
}

/// File, Diff; Preview, Source: the gallery's size picker's look.
private struct ModePicker: View {
    let modes: [FilePage.Mode]
    @Binding var selection: FilePage.Mode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.self) { m in
                Button { selection = m } label: {
                    Text(m.rawValue)
                        .font(.toasty(Theme.Size.meta, selection == m ? .medium : .regular))
                        .foregroundStyle(selection == m ? .primary : .secondary)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 22)
                        .background {
                            if selection == m {
                                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                    .fill(Theme.Surface.page).liftShadow()
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.Fill.subtle))
    }
}

// MARK: - Content

nonisolated enum FileContent: Equatable {
    /// Every line numbered; Markdown keeps its text for the preview.
    case text([DiffLine], markdown: String?)
    /// Not text: Quick Look shows it.
    case other
    case missing

    var isMarkdown: Bool {
        if case .text(_, let md) = self { return md != nil }
        return false
    }

    static let maxBytes = 2_000_000
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Text when it reads as UTF-8 with no NUL bytes; the first 2 MB and
    /// 8,000 lines of a long one, with a note.
    nonisolated static func load(_ url: URL) -> FileContent {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        let cutShort = data.count > maxBytes
        var bytes = cutShort ? data.prefix(maxBytes) : data
        if bytes.prefix(8192).contains(0) { return .other }
        if cutShort, let lastNewline = bytes.lastIndex(of: 0x0A) { bytes = bytes[..<lastNewline] }
        guard var text = String(data: bytes, encoding: .utf8) ?? (cutShort ? nil : String(data: bytes, encoding: .isoLatin1)) else {
            return .other
        }
        // A PDF or other text-ish binary is still better in Quick Look.
        if text.hasPrefix("%PDF") { return .other }
        if text.hasSuffix("\n") { text.removeLast() }
        let all = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var lines = all.prefix(GitChanges.maxDiffLines).enumerated().map {
            DiffLine(kind: .context, text: $1.hasSuffix("\r") ? String($1.dropLast()) : $1, old: nil, new: $0 + 1)
        }
        if cutShort || all.count > lines.count {
            let more = all.count - lines.count
            lines.append(DiffLine(kind: .note, text: cutShort ? "Too large to show in full"
                                  : more == 1 ? "1 more line" : "\(more.formatted()) more lines", old: nil, new: nil))
        }
        let md = markdownExtensions.contains(url.pathExtension.lowercased()) && !cutShort ? text : nil
        return .text(lines, markdown: md)
    }
}

// MARK: - Source

/// The file's lines: the diff page's text view with one number column and
/// no marks. Letting go of a selection (or right-click ▸ Comment) asks for
/// a comment on its lines, with where they are on the page; the place
/// follows them as the page scrolls. A click elsewhere drops it.
struct FileTextView: NSViewRepresentable {
    let lines: [DiffLine]
    let path: String
    /// The open comment on lines, if any (so scrolling moves its box).
    let commentID: UUID?
    /// Lines to comment on, their rect in this view (top-left origin),
    /// and whether to open the box at once (else the pill); nil lines: no
    /// comment.
    let comment: (ClosedRange<Int>?, CGRect?, Bool) -> Void
    let moved: (CGRect) -> Void
    /// Return in the text: true when it opened a comment.
    let returnPressed: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = CommentingTextView(usingTextLayoutManager: false)
        let layout = DiffLayoutManager()
        layout.allowsNonContiguousLayout = true
        text.textContainer?.replaceLayoutManager(layout)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = true
        text.backgroundColor = ClaudeStyle.background
        // The selection tints the lines; the code keeps its colors.
        text.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        text.selectionEnded = { [weak coordinator = context.coordinator] in coordinator?.selectionEnded() }
        text.returnPressed = { [weak coordinator = context.coordinator] in coordinator?.parent.returnPressed() ?? false }
        text.textContainerInset = NSSize(width: 0, height: 14)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator
        scroll.documentView = text
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        fill(text)
        context.coordinator.shown = lines
        ShownCode.register(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.shown != lines, let text = scroll.documentView as? NSTextView else { return }
        // The file changed on disk: the new text, at the same place.
        let origin = scroll.contentView.bounds.origin
        let selected = text.selectedRange()
        fill(text)
        context.coordinator.shown = lines
        let length = text.string.utf16.count
        if NSMaxRange(selected) <= length { text.setSelectedRange(selected) }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func fill(_ text: NSTextView) {
        guard let layout = text.layoutManager as? DiffLayoutManager else { return }
        layout.lineHeight = ClaudeTypography.lineHeight(DiffStyle.font, DiffStyle.lineMultiple)
        // One number column: the old one and its gap are the margin.
        layout.margin = DiffStyle.margin - DiffStyle.columnGap
        layout.columnGap = DiffStyle.columnGap
        layout.markWidth = 0
        layout.numberFont = DiffStyle.numberFont
        layout.colors = [.note: (DiffStyle.hunk, nil)]
        layout.oldColumn = 0
        layout.newColumn = DiffStyle.numberColumn(lines.compactMap(\.new).max() ?? 0)
        let gutter = layout.margin + layout.columnGap + layout.newColumn + DiffStyle.columnGap + DiffStyle.codeGap
        layout.codeStart = gutter
        text.textStorage?.setAttributedString(DiffStyle.text(lines, path: path, gutter: gutter))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FileTextView
        var shown: [DiffLine] = []
        weak var scroll: NSScrollView?
        private var text: NSTextView? { scroll?.documentView as? NSTextView }

        init(_ parent: FileTextView) { self.parent = parent }

        /// The mouse let go: a selection asks for a comment, a click
        /// drops one.
        func selectionEnded() {
            guard let text else { return }
            let r = text.selectedRange()
            if r.length == 0 {
                if parent.commentID != nil { parent.comment(nil, nil, false) }
                return
            }
            parent.comment(Self.lines(of: r, in: text.string as NSString), rect(of: r), false)
        }

        @objc func scrolled() {
            guard parent.commentID != nil, let text, let rect = rect(of: text.selectedRange()) else { return }
            parent.moved(rect)
        }

        /// The selection's lines on the page: from the code's edge, in this
        /// view's top-left space.
        private func rect(of r: NSRange) -> CGRect? {
            guard let text, let scroll, let layout = text.layoutManager, let container = text.textContainer, r.length > 0 else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            var box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x += text.textContainerOrigin.x
            box.origin.y += text.textContainerOrigin.y
            var inWindow = text.convert(box, to: nil)
            inWindow = scroll.convert(inWindow, from: nil)
            if !scroll.isFlipped { inWindow.origin.y = scroll.bounds.height - inWindow.maxY }
            // The code's edge, past the gutter.
            let gutter = (text.textStorage?.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            inWindow.origin.x = max(inWindow.minX, gutter)
            return inWindow
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let r = view.selectedRange()
            let title = r.length > 0 ? "Comment on \(FilePage.lines(Self.lines(of: r, in: view.string as NSString)))…" : "Comment on This Line…"
            let item = NSMenuItem(title: title, action: #selector(commentFromMenu), keyEquivalent: "")
            item.target = self
            item.representedObject = charIndex
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func commentFromMenu(_ item: NSMenuItem) {
            guard let text else { return }
            var r = text.selectedRange()
            if r.length == 0, let at = item.representedObject as? Int {
                r = (text.string as NSString).lineRange(for: NSRange(location: min(at, text.string.utf16.count), length: 0))
                text.setSelectedRange(r)
            }
            guard r.length > 0 else { return }
            parent.comment(Self.lines(of: r, in: text.string as NSString), rect(of: r), true)
        }

        /// 1-based lines a selection covers (a selection ending at a line's
        /// start doesn't take that line).
        static func lines(of r: NSRange, in s: NSString) -> ClosedRange<Int> {
            func line(at i: Int) -> Int {
                var n = 1, at = 0
                let end = min(i, s.length)
                while at < end {
                    let found = s.range(of: "\n", options: .literal, range: NSRange(location: at, length: end - at))
                    if found.location == NSNotFound { break }
                    n += 1
                    at = found.location + 1
                }
                return n
            }
            let first = line(at: r.location)
            var lastIndex = NSMaxRange(r)
            if lastIndex > r.location, lastIndex <= s.length, s.character(at: lastIndex - 1) == 0x0A { lastIndex -= 1 }
            return first...max(first, line(at: lastIndex))
        }
    }
}

/// Tells its owner when the mouse lets go (a click or a drag to select).
final class CommentingTextView: NSTextView {
    var selectionEnded: (() -> Void)?
    /// Return: true when the owner took it (the pill opens its box).
    var returnPressed: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)  // tracks until the mouse is up
        selectionEnded?()
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        let isReturn = event.keyCode == 36 || event.keyCode == 76 || ["\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "")
        if plain, isReturn, returnPressed?() == true { return }
        super.keyDown(with: event)
    }
}

/// By selected lines: "Comment ↩", which opens the comment box in its place.
/// It doesn't take the keyboard, so the selection can still be copied.
struct CommentPill: View {
    let action: () -> Void
    @State private var hovering = false

    /// For placing it (it's drawn at its own size, about this).
    static let size = CGSize(width: 124, height: 28)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus.bubble")
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(Color.accentColor)
                Text("Comment").font(.toasty(Theme.Size.meta, .medium))
                Text("↩").font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.size.height)
            .background(Capsule().fill(hovering ? Color.claudeField.mix(with: .primary, by: 0.06) : Color.claudeField)
                .background(Capsule().fill(Color.claudeBackground))  // opaque over the code
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2))
            .overlay(Capsule().strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .tooltip("Comment on the Selected Lines", shortcut: "↩")
        .accessibilityLabel("Comment on the selected lines")
    }
}

// MARK: - Markdown

/// Markdown as replies show it, in the conversation's column width.
private struct MarkdownPreview: View {
    let markdown: String
    let cwd: String

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: ClaudeTypography.paragraphGap - 4) {
                ForEach(Array(ClaudeMarkdown.blocks(markdown, style: .init(cwd: cwd)).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let s): ClaudeRichText(text: s)
                    case .code(let lang, let code): ClaudeCodeBlock(language: lang, code: code)
                    case .table(let s): ClaudeTableBlock(text: s)
                    case .rule: Rectangle().fill(Color(nsColor: ClaudeTypography.rule)).frame(height: 1).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxWidth: ClaudeTypography.composerWidth, alignment: .leading)
            .padding(.horizontal, ClaudeStyle.horizontalPadding)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Images and PDFs

/// An image at its own size (or fitted to the page when larger), centered,
/// with its size under it.
private struct ImagePreview: View {
    let image: NSImage
    let url: URL

    private var pixels: CGSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private var bytes: String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                .background(Theme.Fill.faint)
            Text("\(Int(pixels.width)) × \(Int(pixels.height)) · \(bytes)")
                .font(.toasty(Theme.Size.meta)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displaysPageBreaks = true
        v.backgroundColor = ClaudeStyle.background
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {}
}

// MARK: - Quick Look

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.shouldCloseWithWindow = false
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) {
        v.close()
    }
}

// MARK: - Mentions

extension Workspace {
    /// "@path" at the end of the open tab's draft, as Claude Code's file
    /// mentions: relative to the conversation's folder, quoted when needed;
    /// "(lines 12-30)" after it for a selection.
    func mention(_ url: URL, isFolder: Bool = false, lines: ClosedRange<Int>? = nil) {
        guard let c = selected else { return }
        let token = Self.mentionToken(url, cwd: c.cwd, isFolder: isFolder, lines: lines)
        let draft = c.draft
        c.draft = draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + token + " "
        c.focusComposer()
    }

    nonisolated static func mentionToken(_ url: URL, cwd: String, isFolder: Bool = false, lines: ClosedRange<Int>? = nil) -> String {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        var path = url.standardizedFileURL.path
        if path.hasPrefix(base) { path.removeFirst(base.count) }
        if isFolder { path += "/" }
        var token = path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@\(path)"
        if let lines {
            token += lines.lowerBound == lines.upperBound ? " (line \(lines.lowerBound))" : " (lines \(lines.lowerBound)-\(lines.upperBound))"
        }
        return token
    }
}
