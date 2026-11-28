import AppKit
import SwiftUI

// MARK: - Read-only, selectable text

/// Native, selectable rich text for Claude's output. A real
/// NSTextView (TextKit 1 so Markdown tables can use NSTextTable), so
/// selection, copy, look up, services, drag and links all behave like any
/// Mac app. It sizes itself to its content for the proposed width.
///
/// In a transcript (`claudeQuoteTarget` set), selecting text with the mouse
/// shows a Quote pill over it; Quote (Return, or ⌘' and the text's menu)
/// puts the selection in the composer as a quote.
struct ClaudeRichText: View {
    let text: NSAttributedString
    var insets = NSSize(width: 0, height: 0)
    /// Size to the text's own width (up to the proposal), like a label.
    var hugs = false
    @Environment(\.claudeQuoteTarget) private var quoteTarget
    /// Where the Quote pill sits: the top center of the selection.
    @State private var pill: CGPoint?
    @State private var handle = ClaudeOutputTextView.Handle()

    var body: some View {
        ClaudeRichTextView(text: text, insets: insets, hugs: hugs, quoteTarget: quoteTarget,
                           handle: handle, onPill: { p in if p != pill { pill = p } })
            .overlay(alignment: .topLeading) {
                if let pill, quoteTarget != nil {
                    QuotePill { handle.view?.quoteSelection(nil) }
                        .offset(x: max(0, pill.x - QuotePill.size.width / 2),
                                y: pill.y - QuotePill.size.height - 6)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: pill == nil)
    }
}

struct ClaudeRichTextView: NSViewRepresentable {
    let text: NSAttributedString
    var insets = NSSize(width: 0, height: 0)
    var hugs = false
    var quoteTarget: ClaudeQuoteTarget?
    var handle: ClaudeOutputTextView.Handle?
    var onPill: ((CGPoint?) -> Void)?

    func makeNSView(context: Context) -> ClaudeOutputTextView {
        let view = ClaudeOutputTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(ClaudeLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textContainerInset = insets
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // Links style themselves (web links blue, file links look like the
        // text or code they're in); the view only adds the hand cursor.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(text)
        view.shownText = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.quoteTarget = quoteTarget
        view.onPill = onPill
        handle?.view = view
        return view
    }

    func updateNSView(_ view: ClaudeOutputTextView, context: Context) {
        view.quoteTarget = quoteTarget
        view.onPill = onPill
        handle?.view = view
        // The same (cached) string as last time: nothing to compare.
        guard view.shownText !== text else { return }
        view.shownText = text
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        // Keep a selection the user is making in a streaming message.
        let selection = view.selectedRanges
        storage.setAttributedString(text)
        let valid = selection.map(\.rangeValue).filter { NSMaxRange($0) <= storage.length }
        if !valid.isEmpty { view.selectedRanges = valid.map { NSValue(range: $0) } }
        view.heights.removeAll()
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ClaudeOutputTextView, context: Context) -> CGSize? {
        // SwiftUI also probes with zero/unbounded widths; answering those
        // with "every word on its own line" heights corrupts the layout.
        if hugs {
            // Like a label: the text's natural width, wrapped only if wider
            // than what's offered.
            let natural = nsView.naturalWidth
            let offered = proposal.width.flatMap { $0.isFinite && $0 > 40 ? $0 : nil } ?? natural
            let width = min(natural, offered)
            return CGSize(width: width, height: nsView.height(forWidth: width))
        }
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: 600, height: nsView.height(forWidth: 600))
        }
        return CGSize(width: width, height: nsView.height(forWidth: max(width, 240)))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            MainActor.assumeIsolated { ClaudeFileLinks.open(url) }
            return true
        }
    }
}

final class ClaudeOutputTextView: NSTextView {
    /// The string last handed to the view.
    weak var shownText: NSAttributedString?
    /// Measured heights by width, cleared when the text changes.
    var heights: [Int: CGFloat] = [:] {
        didSet { if heights.isEmpty { usedWidths.removeAll() } }
    }
    private var usedWidths: [Int: CGFloat] = [:]
    private var lastKey: Int?

    // MARK: Quoting

    /// Lets the SwiftUI side reach its text view (the Quote pill's action).
    final class Handle {
        weak var view: ClaudeOutputTextView?
    }

    /// Where Quote sends the selection; nil outside a transcript.
    var quoteTarget: ClaudeQuoteTarget?
    /// Shows the Quote pill at a point (the selection's top center) or
    /// hides it (nil).
    var onPill: ((CGPoint?) -> Void)?
    private var showsPill = false
    /// The one text view showing its pill: selecting in another hides it.
    private static weak var pillOwner: ClaudeOutputTextView?

    private var selectedText: [NSRange] {
        selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= (textStorage?.length ?? 0) }
    }

    /// Quote the selection (each selected range, for a ⌘-drag selection of
    /// several) in the next message, then let it go.
    @objc func quoteSelection(_ sender: Any?) {
        guard let quoteTarget, let storage = textStorage else { return }
        let ranges = selectedText
        guard !ranges.isEmpty else { return }
        quoteTarget.quote(ranges.map { ClaudeQuoteFormat.text(of: storage, in: $0) })
        setSelectedRange(NSRange(location: ranges[0].location, length: 0))
        hidePill()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(quoteSelection(_:)) { return quoteTarget != nil && !selectedText.isEmpty }
        if item.action == #selector(paste(_:)), composer != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// ⌘V in a transcript (with reply text selected, say) pastes into the
    /// conversation's composer, as if it had the cursor: a picture or file
    /// is attached, text goes in at the composer's cursor.
    override func paste(_ sender: Any?) {
        guard let composer else { return super.paste(sender) }
        hidePill()
        window?.makeFirstResponder(composer)
        composer.paste(sender)
    }

    /// The composer of the conversation this transcript text belongs to.
    private var composer: ComposerTextView? {
        guard let id = quoteTarget?.conversation?.id else { return nil }
        return ComposerTextView.find(id, in: window?.contentView)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let menu, quoteTarget != nil, !selectedText.isEmpty {
            let item = NSMenuItem(title: "Quote in Reply", action: #selector(quoteSelection(_:)), keyEquivalent: "'")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)  // tracks until the mouse is up
        updatePill()
    }

    /// Return quotes the selection (as on a file page it comments on the
    /// selected lines). Read-only text has no other use for it.
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 36 || event.keyCode == 76, quoteTarget != nil, !selectedText.isEmpty {
            quoteSelection(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if showsPill, stillSelecting || selectedText.isEmpty { hidePill() }
    }

    #if DEBUG
    /// Select passages as a mouse selection would (the debug `selectReply`).
    func debugSelect(_ ranges: [NSRange]) {
        window?.makeFirstResponder(self)
        selectedRanges = ranges.map { NSValue(range: $0) }
        updatePill()
    }
    #endif

    private func updatePill() {
        guard quoteTarget != nil, let onPill, let layout = layoutManager, let container = textContainer,
              let first = selectedText.first else { return hidePill() }
        let glyphs = layout.glyphRange(forCharacterRange: first, actualCharacterRange: nil)
        var line = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &line)
        let top = layout.boundingRect(forGlyphRange: NSIntersectionRange(glyphs, line), in: container)
        // Over the middle of what's selected (of its first line, when
        // that's all there is).
        var all = top
        for r in selectedText {
            all = all.union(layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: container))
        }
        let x = (selectedText.count == 1 && NSMaxRange(glyphs) <= NSMaxRange(line) ? top.midX : all.midX) + textContainerOrigin.x
        if Self.pillOwner !== self { Self.pillOwner?.hidePill() }
        Self.pillOwner = self
        showsPill = true
        onPill(CGPoint(x: min(x, bounds.width - QuotePill.size.width / 2), y: top.minY + textContainerOrigin.y))
    }

    func hidePill() {
        guard showsPill else { return }
        showsPill = false
        onPill?(nil)
    }

    /// Copied (or dragged) text has ordinary newlines. The rendered text
    /// breaks lines inside a paragraph with line separators (U+2028, see
    /// `ClaudeMarkdown.lineBreaks`), which other apps and command-line
    /// tools don't treat as the end of a line.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard super.writeSelection(to: pboard, types: types) else { return false }
        // After all the types are written (the text view fills them in
        // lazily, so the plain text isn't there to change any earlier).
        if let text = pboard.string(forType: .string), text.contains("\u{2028}") {
            pboard.setString(text.replacingOccurrences(of: "\u{2028}", with: "\n"), forType: .string)
        }
        return true
    }

    /// Width of the text laid out without wrapping.
    var naturalWidth: CGFloat {
        _ = height(forWidth: 100_000)
        return usedWidths[100_000] ?? 100
    }

    /// Height of the laid out text for a given width.
    func height(forWidth width: CGFloat) -> CGFloat {
        let key = Int(width.rounded())
        lastKey = key
        if let h = heights[key] { return h }
        let (h, used) = measure(width)
        if heights.count > 8 { heights.removeAll() }
        heights[key] = h
        usedWidths[key] = used
        return h
    }

    /// A private layout stack used only for measuring, so measuring never
    /// disturbs the view's own text container (which tracks its width).
    private lazy var measuring: (NSTextStorage, NSLayoutManager, NSTextContainer) = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return (storage, layout, container)
    }()

    private func measure(_ width: CGFloat) -> (CGFloat, CGFloat) {
        let (storage, layout, container) = measuring
        if let text = textStorage, !storage.isEqual(to: text) {
            storage.setAttributedString(text)
        }
        let inner = max(1, width - textContainerInset.width * 2)
        container.size = NSSize(width: inner, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return (ceil(used.height + textContainerInset.height * 2), ceil(used.width + textContainerInset.width * 2) + 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.size = NSSize(width: max(1, newSize.width - textContainerInset.width * 2),
                                     height: .greatestFiniteMagnitude)
    }

    // Scrolling belongs to the transcript, not to each text view.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // Don't steal ⌘F etc. from the window when nothing is selected here.
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Composer

/// The prompt composer: a real NSTextView, so clicking positions the
/// caret, selection, undo/redo, cut/copy/paste, input methods, dictation and
/// all the standard keyboard navigation work as in any Mac text field.
///
/// What Return does in the composer and the fields that send like it
/// (Settings ▸ General ▸ Typing). Either way Command-Return sends and
/// Shift-Return starts a new line, so the habit works in both.
enum ReturnKey: String, CaseIterable, Identifiable {
    /// Return sends; Shift-Return starts a new line.
    case sends
    /// Return starts a new line; Command-Return sends.
    case newLine

    var id: String { rawValue }
    static let defaultsKey = "returnKey"
    static var current: ReturnKey {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ReturnKey.init) ?? .sends
    }

    var title: String {
        switch self {
        case .sends: "Sends the message"
        case .newLine: "Starts a new line"
        }
    }

    /// The key that sends, finishes a comment or a teed-up prompt.
    var send: String { self == .sends ? "Return" : "Command-Return" }
    var sendSymbol: String { self == .sends ? "⏎" : "⌘⏎" }
    /// The key that starts a new line.
    var newLine: String { self == .sends ? "Shift-Return" : "Return" }
    var newLineSymbol: String { self == .sends ? "⇧⏎" : "⏎" }
}

/// Return submits (Command-Return always does); Shift-Return or
/// Option-Return inserts a newline. With `ReturnKey.newLine` plain Return
/// inserts one too. While an input method is composing (marked text),
/// Return goes to the input method.
struct ClaudeComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void
    var onEscape: () -> Bool
    var onShiftTab: () -> Void
    var onPasteImage: ((NSImage) -> Void)?
    /// Files pasted or dropped on the composer, attached instead of
    /// inserted as paths.
    var onFiles: (([URL]) -> Void)?
    /// Files are being dragged over the text (it takes drops itself, so a
    /// SwiftUI drop target around it stops being targeted).
    var onFilesTargeted: ((Bool) -> Void)?
    /// Gets keys first (e.g. the slash command menu): return true if handled.
    var onKeyCommand: ((Selector) -> Bool)?
    /// The conversation, so dictation can show its state on this composer.
    var dictationID: UUID?
    /// The workspace, for dictation's vocabulary, when `dictationID` isn't
    /// one of its conversations (the browser's comment field).
    var dictationWorkspace: UUID? = nil
    /// Claude Code's suggested next prompt: ghost text while empty, Tab
    /// takes it.
    var suggestion: String? = nil
    var onAcceptSuggestion: () -> Void = {}
    var fontSize: CGFloat = ClaudeStyle.bodySize
    /// The text lost the keyboard (a click elsewhere).
    var onBlur: (() -> Void)? = nil
    /// Space after the first line, setting it apart as a title over the
    /// rest (a teed-up prompt, as a Things to-do's title over its notes).
    var titleSpacing: CGFloat? = nil
    /// Drawn invisibly (still taking typing): a stand-in shows the text
    /// while the view around it animates.
    var concealed = false
    /// The tallest the box grows before it scrolls.
    var maxTextHeight: CGFloat = ClaudeComposer.maxHeight

    /// One line of text at rest; the box grows as you type.
    static var minHeight: CGFloat {
        ceil(ClaudeTypography.lineHeight(.systemFont(ofSize: ClaudeStyle.bodySize), ClaudeTypography.inputLineHeightMultiple)) + 6
    }
    static let maxHeight: CGFloat = 300

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = ComposerTextView(usingTextLayoutManager: true)
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = NSSize(width: 0, height: 3)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: Self.minHeight)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // Prompts are often code: no smart quotes/dashes or autocorrect.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        // No Writing Tools / Apple Intelligence button beside the text.
        view.writingToolsBehavior = .none
        view.typingAttributes = ComposerTextView.inputAttributes(font: .systemFont(ofSize: fontSize), color: .labelColor)
        view.placeholder = placeholder
        view.suggestion = suggestion
        view.dictationID = dictationID
        view.dictationWorkspace = dictationWorkspace
        view.string = text

        scroll.documentView = view
        scroll.alphaValue = concealed ? 0 : 1
        context.coordinator.textView = view
        context.coordinator.styleTitle()
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let alpha: CGFloat = concealed ? 0 : 1
        if scroll.alphaValue != alpha { scroll.alphaValue = alpha }
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.dictationID = dictationID
        view.dictationWorkspace = dictationWorkspace
        if view.suggestion != suggestion { view.suggestion = suggestion }
        if view.string != text {
            view.string = text
            context.coordinator.styleTitle()
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // Not during this view update: SwiftUI drops state written
            // while it updates a view (the box kept its old height after
            // sending, or stayed one line for a draft set from code).
            DispatchQueue.main.async { context.coordinator.recalcHeight() }
        }
        if view.placeholder != placeholder {
            view.placeholder = placeholder
            view.needsDisplay = true
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClaudeComposer
        weak var textView: ComposerTextView?
        var lastFocusToken: Int
        /// The composer's own undo stack, separate from the window's (which
        /// Ghostty uses for reopening closed tabs).
        let undo = UndoManager()

        init(_ parent: ClaudeComposer) {
            self.parent = parent
            self.lastFocusToken = -1
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidEndEditing(_ notification: Notification) {
            // After the click that took the keyboard has been handled.
            DispatchQueue.main.async { [weak self] in self?.parent.onBlur?() }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            if parent.text != view.string { parent.text = view.string }
            styleTitle()
            recalcHeight()
        }

        /// With `titleSpacing`: the first paragraph gets that space after
        /// it; the rest keep the input style.
        func styleTitle() {
            guard let spacing = parent.titleSpacing, let view = textView,
                  let storage = view.textStorage, !view.hasMarkedText() else { return }
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let base = ComposerTextView.inputAttributes(font: font, color: .labelColor)
            guard let style = (base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            let all = NSRange(location: 0, length: storage.length)
            let first = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            style.paragraphSpacing = spacing
            storage.beginEditing()
            storage.addAttribute(.paragraphStyle, value: base[.paragraphStyle] as Any, range: all)
            storage.addAttribute(.paragraphStyle, value: style, range: first)
            storage.endEditing()
        }

        func recalcHeight() {
            guard let view = textView,
                  let layout = view.textLayoutManager else { return }
            if view.string.isEmpty {
                if abs(parent.height - ClaudeComposer.minHeight) > 0.5 { parent.height = ClaudeComposer.minHeight }
                view.enclosingScrollView?.hasVerticalScroller = false
                return
            }
            layout.ensureLayout(for: layout.documentRange)
            var h: CGFloat = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { f in
                h = f.layoutFragmentFrame.maxY
                return false
            }
            h += view.textContainerInset.height * 2
            let clamped = min(parent.maxTextHeight, max(ClaudeComposer.minHeight, ceil(h)))
            if abs(clamped - parent.height) > 0.5 {
                parent.height = clamped
            }
            view.enclosingScrollView?.hasVerticalScroller = h > parent.maxTextHeight
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Command-Return has no text-system command (it comes as
            // noop:): it goes the way Return does, so a menu open over the
            // composer picks with it and otherwise it sends. Key
            // equivalents (a request card's ⌘⏎) have had it first.
            let key = (textView as? ComposerTextView)?.keyEvent ?? NSApp.currentEvent
            if selector == Selector(("noop:")), let e = key, e.type == .keyDown,
               e.keyCode == 36 || e.keyCode == 76,
               e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
                return self.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            }
            if parent.onKeyCommand?(selector) == true { return true }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let mods = key?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if mods.contains(.command) {
                    parent.onSubmit()
                } else if mods.contains(.shift) || mods.contains(.option) || ReturnKey.current == .newLine {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape()
            case #selector(NSResponder.insertTab(_:)) where textView.string.isEmpty && parent.suggestion != nil:
                parent.onAcceptSuggestion()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onShiftTab()
                return true
            default:
                return false
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    /// The visible composer of conversation `id`, in `view`.
    static func find(_ id: UUID, in view: NSView?) -> ComposerTextView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let field = view as? ComposerTextView, field.dictationID == id { return field }
        for sub in view.subviews { if let found = find(id, in: sub) { return found } }
        return nil
    }

    /// Typed text, the placeholder and the suggestion: the input line
    /// height, glyphs centered in it (as in the sent bubble).
    static func inputAttributes(font: NSFont, color: NSColor, truncating: Bool = false) -> [NSAttributedString.Key: Any] {
        let style = ClaudeTypography.paragraphStyle(font: font, multiple: ClaudeTypography.inputLineHeightMultiple)
        if truncating { style.lineBreakMode = .byTruncatingTail }
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
            .baselineOffset: ClaudeTypography.baselineOffset(font, ClaudeTypography.inputLineHeightMultiple),
        ]
    }

    weak var coordinator: ClaudeComposer.Coordinator?
    /// The conversation this composer belongs to (dictation's target id).
    var dictationID: UUID?
    /// Its workspace, when `dictationID` isn't one of its conversations.
    var dictationWorkspace: UUID?

    /// The key being handled, for its modifiers (NSApp.currentEvent isn't
    /// it when the key was sent to the window directly).
    private(set) var keyEvent: NSEvent?
    override func keyDown(with event: NSEvent) {
        keyEvent = event
        defer { keyEvent = nil }
        super.keyDown(with: event)
    }

    /// No system badge beside the cursor (Siri, dictation, input source).
    override func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement { .invisible }
    var placeholder: String = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    /// Shown in place of the placeholder, with a "tab" key hint.
    var suggestion: String? {
        didSet { if suggestion != oldValue { needsDisplay = true } }
    }

    /// Whether the placeholder was last drawn; typing only invalidates the
    /// typed glyph's rect, so the whole view must redraw when this flips.
    private var showedPlaceholder = true
    private func updatePlaceholder() {
        let show = string.isEmpty && !hasMarkedText()
        if show != showedPlaceholder {
            showedPlaceholder = show
            setNeedsDisplay(bounds)
        }
    }

    override var string: String {
        didSet { updatePlaceholder() }
    }

    /// Wrapping changes with the width: measure again (outside layout).
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, !string.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.coordinator?.recalcHeight() }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        updatePlaceholder()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updatePlaceholder()
    }

    override func unmarkText() {
        super.unmarkText()
        updatePlaceholder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        if let suggestion, !suggestion.isEmpty {
            drawSuggestion(suggestion)
            return
        }
        guard !placeholder.isEmpty else { return }
        // Same font and line height as typed text, so the placeholder sits
        // exactly where the first line will.
        let attrs = Self.inputAttributes(font: font ?? NSFont.systemFont(ofSize: ClaudeStyle.bodySize),
                                         color: .placeholderTextColor, truncating: true)
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let rect = NSRect(x: x, y: textContainerInset.height, width: bounds.width - x * 2, height: bounds.height)
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    /// The suggested prompt on one line (truncated), then a small "tab"
    /// key cap, like the CLI's ghost text.
    private func drawSuggestion(_ text: String) {
        let font = font ?? NSFont.systemFont(ofSize: ClaudeStyle.bodySize)
        let attrs = Self.inputAttributes(font: font, color: .placeholderTextColor, truncating: true)
        let keyFont = NSFont.systemFont(ofSize: Theme.Size.caption, weight: .medium)
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: keyFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let key = "tab" as NSString
        let keySize = key.size(withAttributes: keyAttrs)
        let capWidth = ceil(keySize.width) + 10, capHeight: CGFloat = 16

        let line = text.replacingOccurrences(of: "\n", with: " ") as NSString
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let available = max(0, bounds.width - x * 2 - capWidth - 8)
        let width = min(ceil(line.size(withAttributes: attrs).width), available)
        let lineHeight = ClaudeTypography.lineHeight(font, ClaudeTypography.inputLineHeightMultiple)
        line.draw(with: NSRect(x: x, y: textContainerInset.height, width: width, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)

        let cap = NSRect(x: x + width + 8, y: textContainerInset.height + (lineHeight - capHeight) / 2,
                         width: capWidth, height: capHeight)
        let path = NSBezierPath(roundedRect: cap.insetBy(dx: 0.25, dy: 0.25), xRadius: Theme.Radius.small - 2, yRadius: Theme.Radius.small - 2)
        path.lineWidth = 0.5
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
        key.draw(at: NSPoint(x: cap.midX - keySize.width / 2, y: cap.midY - keySize.height / 2), withAttributes: keyAttrs)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    // Edit > Undo / Redo act on the composer's own text, never on the
    // window's undo stack.
    @objc func undo(_ sender: Any?) { coordinator?.undo.undo() }
    @objc func redo(_ sender: Any?) { coordinator?.undo.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            if let mi = item as? NSMenuItem { mi.title = coordinator?.undo.undoMenuItemTitle ?? "Undo" }
            return coordinator?.undo.canUndo ?? false
        }
        if item.action == #selector(redo(_:)) {
            if let mi = item as? NSMenuItem { mi.title = coordinator?.undo.redoMenuItemTitle ?? "Redo" }
            return coordinator?.undo.canRedo ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    // Paste: plain text only (the composer isn't rich text), and images are
    // handed to the conversation as attachments.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // Files copied in Finder (they also carry their names as text).
        if let onFiles = coordinator?.parent.onFiles, let urls = Self.fileURLs(pb) {
            onFiles(urls)
            return
        }
        let hasText = pb.canReadObject(forClasses: [NSString.self], options: nil)
        if !hasText, let onImage = coordinator?.parent.onPasteImage,
           let image = NSImage(pasteboard: pb) {
            onImage(image)
            return
        }
        pasteAsPlainText(sender)
    }

    // Dropped files are attachments, not paths typed into the prompt.
    static func fileURLs(_ pb: NSPasteboard) -> [URL]? {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if coordinator?.parent.onFiles != nil, Self.fileURLs(sender.draggingPasteboard) != nil {
            coordinator?.parent.onFilesTargeted?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.parent.onFilesTargeted?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        coordinator?.parent.onFilesTargeted?(false)
        super.draggingEnded(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if coordinator?.parent.onFiles != nil, Self.fileURLs(sender.draggingPasteboard) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFiles = coordinator?.parent.onFiles, let urls = Self.fileURLs(sender.draggingPasteboard) {
            coordinator?.parent.onFilesTargeted?(false)
            onFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

