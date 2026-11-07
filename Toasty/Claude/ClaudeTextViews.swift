import AppKit
import SwiftUI

// MARK: - Read-only, selectable text

/// Native, selectable rich text for Claude's output. A real
/// NSTextView (TextKit 1 so Markdown tables can use NSTextTable), so
/// selection, copy, look up, services, drag and links all behave like any
/// Mac app. It sizes itself to its content for the proposed width.
struct ClaudeRichText: NSViewRepresentable {
    let text: NSAttributedString
    var insets = NSSize(width: 0, height: 0)
    /// Size to the text's own width (up to the proposal), like a label.
    var hugs = false

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
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: ClaudeOutputTextView, context: Context) {
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
    /// Measured heights by width, cleared when the text changes.
    var heights: [Int: CGFloat] = [:] {
        didSet { if heights.isEmpty { usedWidths.removeAll() } }
    }
    private var usedWidths: [Int: CGFloat] = [:]
    private var lastKey: Int?

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
/// Return submits; Shift-Return or Option-Return inserts a newline. While an
/// input method is composing (marked text), Return goes to the input method.
struct ClaudeComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void
    var onEscape: () -> Bool
    var onShiftTab: () -> Void
    var onPasteImage: ((NSImage) -> Void)?

    /// One line of text at rest; the box grows as you type.
    static var minHeight: CGFloat {
        ceil(NSFont.systemFont(ofSize: ClaudeStyle.bodySize).boundingRectForFont.height * 1.2) + 6
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
        view.font = .systemFont(ofSize: ClaudeStyle.bodySize)
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
        view.typingAttributes = [
            .font: NSFont.systemFont(ofSize: ClaudeStyle.bodySize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.lineHeightMultiple = 1.2
                return p
            }(),
        ]
        view.placeholder = placeholder
        view.string = text

        scroll.documentView = view
        context.coordinator.textView = view
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        if view.string != text {
            view.string = text
            context.coordinator.recalcHeight()
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

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            if parent.text != view.string { parent.text = view.string }
            recalcHeight()
        }

        func recalcHeight() {
            guard let view = textView,
                  let layout = view.textLayoutManager else { return }
            layout.ensureLayout(for: layout.documentRange)
            var h: CGFloat = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { f in
                h = f.layoutFragmentFrame.maxY
                return false
            }
            h += view.textContainerInset.height * 2
            let clamped = min(ClaudeComposer.maxHeight, max(ClaudeComposer.minHeight, ceil(h)))
            if abs(clamped - parent.height) > 0.5 {
                parent.height = clamped
            }
            view.enclosingScrollView?.hasVerticalScroller = h > ClaudeComposer.maxHeight
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let mods = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if mods.contains(.shift) || mods.contains(.option) {
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
    weak var coordinator: ClaudeComposer.Coordinator?
    var placeholder: String = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
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
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        // Same font and line height as typed text, so the placeholder sits
        // exactly where the first line will.
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: ClaudeStyle.bodySize),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: style,
        ]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let rect = NSRect(x: x, y: textContainerInset.height, width: bounds.width - x * 2, height: bounds.height)
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
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
        let hasText = pb.canReadObject(forClasses: [NSString.self], options: nil)
        if !hasText, let onImage = coordinator?.parent.onPasteImage,
           let image = NSImage(pasteboard: pb) {
            onImage(image)
            return
        }
        pasteAsPlainText(sender)
    }
}
