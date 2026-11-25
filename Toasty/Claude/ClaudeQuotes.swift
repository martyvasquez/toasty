import AppKit
import SwiftUI

// MARK: - Model

/// A passage of the transcript quoted in the next message, with the user's
/// note on it. Several can be gathered before sending, each with its own
/// note, like comments on a review.
struct ClaudeQuote: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var note = ""
    /// The transcript item it was taken from (to bring it back into view).
    var source: String?
}

extension ClaudeConversation {
    /// Quote passages selected in the transcript (one per selected range).
    /// The same passage twice is quoted once.
    func addQuotes(_ texts: [String], source: String?) {
        let fresh = texts.map(ClaudeQuoteFormat.clean).filter { t in
            !t.isEmpty && !quotes.contains { $0.text == t }
        }
        guard !fresh.isEmpty else { return }
        let added = fresh.map { ClaudeQuote(text: $0, source: source) }
        quotes += added
        // Straight into a comment on it: select, ⌘', comment, next.
        quoteToComment = added.last?.id
    }

    /// Bring a quoted passage's message into view: the item it was quoted
    /// from when known, else the latest message (before `before`) that
    /// contains it.
    func revealQuote(_ text: String, source: String? = nil, before: String? = nil) {
        if let source, items.contains(where: { $0.id == source }) {
            revealItemID = source
            return
        }
        let needle = ClaudeQuoteFormat.searchKey(text)
        guard !needle.isEmpty else { return }
        var pool = items[...]
        if let before, let i = items.firstIndex(where: { $0.id == before }) { pool = items[..<i] }
        let found = pool.last { item in
            item.kind != .user && item.kind != .tool && ClaudeQuoteFormat.searchKey(item.text).contains(needle)
        }
        if let found { revealItemID = found.id }
    }
}

/// How quotes are written into the prompt Claude receives, and read back
/// for showing a sent message (also when resumed from Claude Code's
/// transcript): plain Markdown quotes ahead of the typed text, each
/// followed by its note.
///
///     > the quoted passage
///     > its second line
///     The comment on it.
///
///     > another passage
///
///     What the user typed.
nonisolated enum ClaudeQuoteFormat {
    static func prompt(_ quotes: [ClaudeQuote], typed: String) -> String {
        let blocks = quotes.map { q in
            let lines = q.text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
            let note = commentLines(q.note)
            return (lines + (note.isEmpty ? [] : [note])).joined(separator: "\n")
        }
        return (blocks + (typed.isEmpty ? [] : [typed])).joined(separator: "\n\n")
    }

    /// A sent prompt split into its leading quotes (with their notes) and
    /// the rest of the text.
    static func split(_ raw: String) -> (quotes: [(text: String, note: String)], text: String) {
        let lines = raw.components(separatedBy: "\n")
        var quotes: [(text: String, note: String)] = []
        var i = 0
        while i < lines.count, lines[i].hasPrefix(">") {
            var quoted: [String] = []
            while i < lines.count, lines[i].hasPrefix(">") {
                var l = lines[i].dropFirst()
                if l.hasPrefix(" ") { l = l.dropFirst() }
                quoted.append(String(l))
                i += 1
            }
            var note: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i].hasPrefix(">") {
                note.append(lines[i])
                i += 1
            }
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            quotes.append((quoted.joined(separator: "\n"), note.joined(separator: "\n")))
        }
        guard !quotes.isEmpty else { return ([], raw) }
        let rest = lines[min(i, lines.count)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (quotes, rest)
    }

    /// Selected transcript text as it reads: ordinary line breaks, list
    /// bullets as "- ", no runs of blank lines or edge whitespace.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A comment as sent: its own line breaks, but no blank lines (a blank
    /// line ends the comment when the message is read back).
    static func commentLines(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Letters and digits only, lowercased, so a passage as shown matches
    /// the Markdown it came from (bold marks, bullets, links and all). The
    /// passage's first 60 of them, which is plenty to find it.
    static func searchKey(_ s: String, limit: Int = 60) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(limit).map(Character.init))
    }

    /// The text of a range of a reply as shown: a list's bullet placeholder
    /// (drawn by the layout manager) becomes "- ".
    static func text(of string: NSAttributedString, in range: NSRange) -> String {
        var out = ""
        let ns = string.string as NSString
        string.enumerateAttributes(in: range) { attrs, sub, _ in
            if attrs[.claudeBullet] != nil || attrs[.claudeTask] != nil {
                out += "- "
            } else {
                out += ns.substring(with: sub)
            }
        }
        return out
    }
}

// MARK: - Where quoting goes

/// The conversation a transcript's text quotes into, and the item the text
/// belongs to. Set on the transcript's rows; text elsewhere has none and
/// offers no Quote.
struct ClaudeQuoteTarget {
    weak var conversation: ClaudeConversation?
    var source: String?

    func quote(_ texts: [String]) { conversation?.addQuotes(texts, source: source) }
}

extension EnvironmentValues {
    @Entry var claudeQuoteTarget: ClaudeQuoteTarget? = nil
}

// MARK: - The pill over a selection

/// A small floating button beside a selection ("Comment ↩", "Quote ↩"):
/// it doesn't take the keyboard, so the selection can still be copied.
struct SelectionPill: View {
    let symbol: String
    let title: String
    let shortcut: String
    let tooltip: String
    let action: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.toasty(Theme.Size.meta))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.toasty(Theme.Size.meta, .medium))
                Text(shortcut).font(.toasty(Theme.Size.caption)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(Capsule().fill(hovering ? Color.claudeField.mix(with: .primary, by: 0.06) : Color.claudeField)
                .background(Capsule().fill(Color.claudeBackground))  // opaque over the text
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2))
            .overlay(Capsule().strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .tooltip(tooltip, shortcut: shortcut)
        .accessibilityLabel(tooltip)
    }
}

/// Over selected text in the transcript: quote it in the next message.
struct QuotePill: View {
    let action: () -> Void
    /// About its drawn size, for placing it.
    static let size = CGSize(width: 92, height: SelectionPill.height)

    var body: some View {
        SelectionPill(symbol: "text.quote", title: "Quote", shortcut: "↩",
                      tooltip: "Quote in Your Reply", action: action)
            .fixedSize()
    }
}

// MARK: - In the composer

/// The quotes gathered for the next message, above the composer's text.
/// Closed, a card is the passage on one line (and its comment, if it has
/// one); open (clicked, or just quoted) it shows the whole passage and the
/// comment field, which has the keyboard. × removes it.
struct ComposerQuotes: View {
    @ObservedObject var conversation: ClaudeConversation
    @FocusState private var focusedNote: UUID?
    /// The open card: the one whose comment has the keyboard.
    @State private var openID: UUID?

    var body: some View {
        let quotes = conversation.quotes
        let list = VStack(alignment: .leading, spacing: Theme.Space.s - 2) {
            ForEach(quotes) { quote in
                row(quote).id(quote.id)
            }
        }
        // Past four, the list scrolls rather than pushing the box up.
        Group {
            if quotes.count > 4 {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { list }
                        .frame(height: 4 * 56)
                        .onChange(of: openID) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        }
                }
            } else {
                list
            }
        }
        .animation(.easeOut(duration: 0.15), value: openID)
        .onAppear(perform: takeComment)
        .onChange(of: conversation.quoteToComment) { _, _ in takeComment() }
        // The comment lost the keyboard (Return, Esc, a click elsewhere):
        // its card closes.
        .onChange(of: focusedNote) { _, id in if id != openID { openID = id } }
        // Back to the message (Return, Esc, ×, a new quote's focus moving
        // on): nothing stays open without the keyboard.
        .onChange(of: conversation.composerFocusToken) { _, _ in openID = nil }
    }

    /// A quote just added: its card opens, its comment takes the keyboard.
    private func takeComment() {
        guard let id = conversation.quoteToComment else { return }
        conversation.quoteToComment = nil
        open(id)
    }

    private func open(_ id: UUID) {
        openID = id
        // After the field is in the window. The caret goes to the end of
        // the comment (focusing a field selects all of it otherwise, and a
        // keystroke would replace it).
        DispatchQueue.main.async {
            focusedNote = id
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
                editor.moveToEndOfDocument(nil)
            }
        }
    }

    private func row(_ quote: ClaudeQuote) -> some View {
        let isOpen = openID == quote.id
        return HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(isOpen ? quote.text : ClaudeQuoteFormat.oneLine(quote.text))
                    .font(.toasty(Theme.Size.control))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(isOpen ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if !isOpen, !quote.note.isEmpty {
                    // Closed: the comment on one line too.
                    Text(ClaudeQuoteFormat.oneLine(quote.note))
                        .font(.toasty(Theme.Size.control))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if isOpen {
                    TextField("Add a comment", text: note(quote.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.toasty(Theme.Size.control))
                        .focused($focusedNote, equals: quote.id)
                        // Shift-Return starts a new line, as in the message.
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.shift) || press.modifiers.contains(.option) else { return .ignored }
                            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                            return .handled
                        }
                        // Return goes back to the message (sending is the
                        // message's Return, so a comment is never sent by
                        // accident).
                        .onSubmit { conversation.focusComposer() }
                        .onExitCommand { conversation.focusComposer() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                conversation.quotes.removeAll { $0.id == quote.id }
                conversation.focusComposer()
            } label: {
                Image(systemName: "xmark")
                    .font(.toasty(Theme.Size.caption, .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip("Remove Quote")
            .accessibilityLabel("Remove Quote")
        }
        .padding(.vertical, Theme.Space.s + 2)
        .padding(.leading, Theme.Space.m + 2)
        .padding(.trailing, Theme.Space.s + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Fill.subtle))
        .contentShape(Rectangle())
        .onTapGesture { open(quote.id) }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ id: UUID) -> Binding<String> {
        Binding(
            get: { conversation.quotes.first { $0.id == id }?.note ?? "" },
            set: { v in
                if let i = conversation.quotes.firstIndex(where: { $0.id == id }) {
                    conversation.quotes[i].note = v
                }
            })
    }
}

// MARK: - In a sent message

/// A sent message's quotes, inside its bubble: each passage on a line
/// (click to see it in the transcript) with the comment under it. On the
/// blue bubble in white; on a queued (outlined) one in the usual colors.
struct SentQuotes: View {
    let quotes: [(text: String, note: String)]
    /// The message they were sent in (the passage is looked for before it).
    let messageID: String
    var onBlue = true
    @Environment(\.claudeQuoteTarget) private var target

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            ForEach(Array(quotes.enumerated()), id: \.offset) { _, q in
                card(q)
            }
        }
    }

    private func ink(_ opacity: Double) -> Color {
        onBlue ? Color.white.opacity(opacity) : Color.primary.opacity(opacity)
    }

    private func card(_ q: (text: String, note: String)) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(ClaudeQuoteFormat.oneLine(q.text))
                .font(.toasty(Theme.Size.control))
                .italic()
                .foregroundStyle(ink(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
            if !q.note.isEmpty {
                Text(q.note)
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(ink(0.95))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Theme.Space.s + 2)
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(onBlue ? Color.white.opacity(0.1) : Theme.Fill.subtle))
        .contentShape(Rectangle())
        .onTapGesture { target?.conversation?.revealQuote(q.text, before: messageID) }
        .tooltipText("Show in the conversation")
    }
}
