import AppKit
import Combine
import GhosttyVt

/// A terminal: a login shell on a PTY, emulated by libghostty-vt and drawn
/// natively. `TerminalScrollView` wraps it for scrollback.
final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation, ObservableObject {
    let vt: VTTerminal
    private(set) var pty: PTYProcess?
    private let renderer = TerminalRenderer()
    private var displayLink: CADisplayLink?
    private var idleFrames = 0
    private var forceFrame = true

    /// The program's title (OSC 0/2), live.
    @Published private(set) var title = ""
    /// The terminal's working directory (OSC 7), live.
    @Published private(set) var pwd = ""
    /// Called on the main thread when the shell exits.
    var onExit: ((Int32) -> Void)?
    /// Scrollback changed: (total rows, first visible row, visible rows).
    var onScrollbar: ((GhosttyTerminalScrollbar) -> Void)?

    private var cols: UInt16 = 80
    private var rows: UInt16 = 24
    private var focused = false
    private var cursorBlinkOn = true
    private var blinkTimer: Timer?
    private var lastScrollbar = GhosttyTerminalScrollbar()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(cwd: String) {
        vt = VTTerminal(cols: 80, rows: 24)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        applyTheme()

        vt.onBell = { DispatchQueue.main.async { NSSound.beep() } }
        vt.onTitleChanged = { [weak self] in
            DispatchQueue.main.async { guard let self else { return }; self.title = self.vt.title }
        }
        vt.onPwdChanged = { [weak self] in
            DispatchQueue.main.async { guard let self else { return }; self.pwd = self.vt.pwd }
        }
        start(cwd: cwd)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func start(cwd: String) {
        let cw = UInt16(renderer.font.cellWidth.rounded()), ch = UInt16(renderer.font.cellHeight)
        do {
            let pty = try PTYProcess(shell: PTYProcess.loginShell, cwd: cwd, environment: PTYProcess.environment(),
                                     cols: cols, rows: rows, cellWidth: cw, cellHeight: ch)
            let vt = self.vt
            vt.onWritePTY = { [weak pty] data in pty?.write(data) }
            pty.onOutput = { [weak self] bytes in
                vt.write(bytes)
                self?.outputArrived()
            }
            pty.onExit = { [weak self] status in self?.onExit?(status) }
            pty.start()
            self.pty = pty
        } catch {
            vt.writeLocal("Couldn't start the shell: \(error)\r\n")
        }
    }

    func terminate() { pty?.terminate() }

    // MARK: Frames

    /// From the PTY read queue: make sure a frame is coming.
    nonisolated private func outputArrived() {
        DispatchQueue.main.async { [weak self] in self?.wake() }
    }

    private func wake() {
        idleFrames = 0
        cursorBlinkOn = true
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func frame(_ link: CADisplayLink) {
        renderFrame()
    }

    /// Frames rendered and time spent (debug stats).
    private(set) var framesRendered = 0
    private(set) var renderSeconds: Double = 0

    private func renderFrame() {
        let t0 = CACurrentMediaTime()
        defer { renderSeconds += CACurrentMediaTime() - t0 }
        guard vt.updateRenderState(force: forceFrame) else {
            idleFrames += 1
            if idleFrames > 30 { displayLink?.isPaused = true }
            return
        }
        let full = forceFrame
        forceFrame = false
        framesRendered += 1
        idleFrames = 0
        let changed = renderer.update(from: vt)
        if full { needsDisplay = true } else { for y in changed { setNeedsDisplay(rowRect(y)) } }
        updateBlink()
        let sb = vt.scrollbar
        if sb.total != lastScrollbar.total || sb.offset != lastScrollbar.offset || sb.len != lastScrollbar.len {
            lastScrollbar = sb
            onScrollbar?(sb)
        }
    }

    private func requestFullFrame() {
        forceFrame = true
        wake()
    }

    private func rowRect(_ y: Int) -> NSRect {
        NSRect(x: 0, y: TerminalTheme.paddingY + CGFloat(y) * renderer.font.cellHeight,
               width: bounds.width, height: renderer.font.cellHeight)
            .insetBy(dx: 0, dy: -1)
    }

    private(set) var drawSeconds: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        let t0 = CACurrentMediaTime()
        defer { drawSeconds += CACurrentMediaTime() - t0 }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(renderer.theme.background.cgColor)
        ctx.fill(dirtyRect)
        let ch = renderer.font.cellHeight
        let first = max(0, Int((dirtyRect.minY - TerminalTheme.paddingY) / ch))
        let last = min(renderer.rows.count - 1, Int((dirtyRect.maxY - TerminalTheme.paddingY) / ch))
        guard first <= last else { return }
        let options = TerminalRenderer.DrawOptions(cursorShown: cursorBlinkOn || !renderer.cursor.blinking || !focused,
                                                   focused: focused, markedText: markedText.isEmpty ? nil : markedText,
                                                   scale: window?.backingScaleFactor ?? 2)
        for y in first...last {
            renderer.draw(row: y, in: ctx, origin: CGPoint(x: TerminalTheme.paddingX, y: TerminalTheme.paddingY + CGFloat(y) * ch),
                          fullWidth: bounds.width, options: options)
        }
    }

    private func updateBlink() {
        let wantsBlink = focused && renderer.cursor.visible && renderer.cursor.blinking
        if wantsBlink && blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cursorBlinkOn.toggle()
                    self.setNeedsDisplay(self.rowRect(self.renderer.cursor.y))
                }
            }
        } else if !wantsBlink, let t = blinkTimer {
            t.invalidate()
            blinkTimer = nil
            cursorBlinkOn = true
        }
    }

    private func resetBlink() {
        cursorBlinkOn = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        if renderer.cursor.visible { setNeedsDisplay(rowRect(renderer.cursor.y)) }
        updateBlink()
    }

    // MARK: Size & appearance

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
    }

    private func updateGridSize() {
        let f = renderer.font
        let c = UInt16(clamping: max(2, Int((bounds.width - 2 * TerminalTheme.paddingX) / f.cellWidth)))
        let r = UInt16(clamping: max(1, Int((bounds.height - 2 * TerminalTheme.paddingY) / f.cellHeight)))
        guard c != cols || r != rows else { return }
        cols = c
        rows = r
        let scale = window?.backingScaleFactor ?? 2
        let cw = UInt32(f.cellWidth * scale), ch = UInt32(f.cellHeight * scale)
        vt.resize(cols: c, rows: r, cellWidth: cw, cellHeight: ch)
        pty?.resize(cols: c, rows: r, cellWidth: UInt16(f.cellWidth), cellHeight: UInt16(f.cellHeight))
        requestFullFrame()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let theme = TerminalTheme.current(for: effectiveAppearance)
        renderer.theme = theme
        layer?.backgroundColor = theme.background.cgColor
        vt.setColors(foreground: theme.foreground.ghostty, background: theme.background.ghostty,
                     cursor: theme.cursor.ghostty, palette: theme.palette.map(\.ghostty))
        requestFullFrame()
    }

    var cellSize: NSSize { NSSize(width: renderer.font.cellWidth, height: renderer.font.cellHeight) }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        setFocused(window?.isKeyWindow ?? true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
        updateGridSize()
        updateTrackingAreas()
    }

    @objc private func windowKeyChanged() {
        setFocused(window?.isKeyWindow == true && window?.firstResponder === self)
    }

    private func setFocused(_ f: Bool) {
        guard f != focused else { return }
        focused = f
        pty?.write(vt.encodeFocus(f))
        resetBlink()
        requestFullFrame()
    }

    // MARK: Keyboard

    /// Text produced by interpretKeyEvents during one keyDown.
    private var keyTextAccumulator: [String]?
    private var markedText = ""

    override func keyDown(with event: NSEvent) {
        let markedBefore = !markedText.isEmpty
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        let action: GhosttyKeyAction = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS
        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts { sendKey(event, action: action, text: text, composing: false) }
        } else {
            sendKey(event, action: action, text: Self.characters(event), composing: !markedText.isEmpty || markedBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_KEY_ACTION_RELEASE, text: nil, composing: false)
    }

    /// Ctrl-key combos the system would otherwise swallow as key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.control), !mods.contains(.command) {
            keyDown(with: event)
            return true
        }
        return false
    }

    /// The characters a key event types, for the encoder: control
    /// characters are left to the encoder; function keys have none.
    private static func characters(_ event: NSEvent) -> String? {
        guard let chars = event.characters, let scalar = chars.unicodeScalars.first else { return nil }
        if chars.unicodeScalars.count == 1 {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return chars
    }

    private func sendKey(_ event: NSEvent, action: GhosttyKeyAction, text: String?, composing: Bool) {
        guard !composing, let pty else { return }
        let mods = Self.mods(event.modifierFlags)
        // Option and shift were used to produce the text; ctrl and cmd weren't.
        let consumed = text?.isEmpty == false ? Self.mods(event.modifierFlags.subtracting([.control, .command])) : 0
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        let key = VTTerminal.Key(action: action, key: KeyCodes.map[event.keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED,
                                 mods: mods, consumedMods: consumed, text: text, unshifted: unshifted, composing: composing)
        let data = vt.encode(key, optionAsAlt: false)
        guard !data.isEmpty else { return }
        if action != GHOSTTY_KEY_ACTION_RELEASE {
            NSCursor.setHiddenUntilMouseMoves(true)
            if vt.hasSelection { vt.clearSelection() }
            if lastScrollbar.offset + lastScrollbar.len < lastScrollbar.total { vt.scroll(GHOSTTY_SCROLL_VIEWPORT_BOTTOM) }
            resetBlink()
        }
        pty.write(data)
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var m: GhosttyMods = 0
        if flags.contains(.shift) { m |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { m |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { m |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { m |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { m |= GhosttyMods(GHOSTTY_MODS_CAPS_LOCK) }
        return m
    }

    override func doCommand(by selector: Selector) {
        // Handled by the encoder in keyDown (Return, arrows, ctrl keys…).
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let hadMarked = !markedText.isEmpty
        markedText = ""
        if hadMarked { setNeedsDisplay(rowRect(renderer.cursor.y)) }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            // Dictation, the character viewer…: plain text input.
            pty?.write(Data(text.utf8))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        setNeedsDisplay(rowRect(renderer.cursor.y))
    }

    func unmarkText() {
        markedText = ""
        setNeedsDisplay(rowRect(renderer.cursor.y))
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count) }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the IME candidate window goes: under the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let f = renderer.font
        let r = NSRect(x: TerminalTheme.paddingX + CGFloat(renderer.cursor.x) * f.cellWidth,
                       y: TerminalTheme.paddingY + CGFloat(renderer.cursor.y) * f.cellHeight,
                       width: f.cellWidth, height: f.cellHeight)
        guard let window else { return r }
        return window.convertToScreen(convert(r, to: nil))
    }

    // MARK: Mouse

    private var trackingArea: NSTrackingArea?
    private var pressedButtons = Set<Int>()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }

    private func cell(at event: NSEvent) -> (col: Int, row: Int, point: NSPoint) {
        let p = convert(event.locationInWindow, from: nil)
        let f = renderer.font
        let col = Int(floor((p.x - TerminalTheme.paddingX) / f.cellWidth))
        let row = Int(floor((p.y - TerminalTheme.paddingY) / f.cellHeight))
        return (max(0, min(Int(cols) - 1, col)), max(0, min(Int(rows) - 1, row)), p)
    }

    /// Programs that track the mouse get it, unless Shift is held (then
    /// the mouse selects text, like Terminal and Ghostty).
    private func reportsMouse(_ event: NSEvent) -> Bool {
        !event.modifierFlags.contains(.shift) && vt.mouseTracking
    }

    private var mouseSize: GhosttyMouseEncoderSize {
        var s = GhosttyMouseEncoderSize()
        s.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        s.screen_width = UInt32(bounds.width)
        s.screen_height = UInt32(bounds.height)
        s.cell_width = UInt32(renderer.font.cellWidth)
        s.cell_height = UInt32(renderer.font.cellHeight)
        s.padding_left = UInt32(TerminalTheme.paddingX)
        s.padding_right = UInt32(TerminalTheme.paddingX)
        s.padding_top = UInt32(TerminalTheme.paddingY)
        s.padding_bottom = UInt32(TerminalTheme.paddingY)
        return s
    }

    private func sendMouse(_ action: GhosttyMouseAction, button: Int?, event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b: GhosttyMouseButton? = button.map {
            switch $0 {
            case 0: GHOSTTY_MOUSE_BUTTON_LEFT
            case 1: GHOSTTY_MOUSE_BUTTON_RIGHT
            case 2: GHOSTTY_MOUSE_BUTTON_MIDDLE
            case 3: GHOSTTY_MOUSE_BUTTON_FOUR
            case 4: GHOSTTY_MOUSE_BUTTON_FIVE
            case 5: GHOSTTY_MOUSE_BUTTON_SIX
            default: GHOSTTY_MOUSE_BUTTON_SEVEN
            }
        }
        let m = VTTerminal.Mouse(action: action, button: b, mods: Self.mods(event.modifierFlags), x: Float(p.x), y: Float(p.y))
        pty?.write(vt.encode(m, size: mouseSize, anyButtonPressed: !pressedButtons.isEmpty))
    }

    private var gestureGeometry: GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(columns: UInt32(cols), cell_width: UInt32(renderer.font.cellWidth),
                                        padding_left: UInt32(TerminalTheme.paddingX), screen_height: UInt32(bounds.height))
    }

    private var mouseDownClickCount = 0

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownClickCount = event.clickCount
        if reportsMouse(event) {
            pressedButtons.insert(0)
            sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: 0, event: event)
            return
        }
        if event.modifierFlags.contains(.command) { return } // ⌘-click opens links on mouseUp
        let c = cell(at: event)
        vt.selectionGesture(.press, col: c.col, row: c.row, x: c.point.x, y: c.point.y,
                            timeNS: UInt64(event.timestamp * 1e9), repeatIntervalNS: UInt64(NSEvent.doubleClickInterval * 1e9),
                            geometry: gestureGeometry, rectangle: false)
        wake()
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedButtons.contains(0) {
            sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: 0, event: event)
            return
        }
        let c = cell(at: event)
        // Dragging past the top or bottom edge scrolls the scrollback.
        if c.point.y < 0 { vt.scroll(GHOSTTY_SCROLL_VIEWPORT_DELTA, delta: -1) }
        else if c.point.y > bounds.height { vt.scroll(GHOSTTY_SCROLL_VIEWPORT_DELTA, delta: 1) }
        vt.selectionGesture(.drag, col: c.col, row: c.row, x: c.point.x, y: c.point.y,
                            timeNS: UInt64(event.timestamp * 1e9), repeatIntervalNS: 0,
                            geometry: gestureGeometry, rectangle: event.modifierFlags.contains(.option))
        wake()
    }

    override func mouseUp(with event: NSEvent) {
        if pressedButtons.remove(0) != nil {
            sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: 0, event: event)
            return
        }
        let c = cell(at: event)
        if event.modifierFlags.contains(.command), mouseDownClickCount == 1 {
            openLink(col: c.col, row: c.row)
            return
        }
        vt.selectionGesture(.release, col: c.col, row: c.row, x: c.point.x, y: c.point.y,
                            timeNS: UInt64(event.timestamp * 1e9), repeatIntervalNS: 0,
                            geometry: gestureGeometry, rectangle: false)
    }

    override func mouseMoved(with event: NSEvent) {
        guard reportsMouse(event) else { return }
        sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: nil, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) {
            pressedButtons.insert(1)
            sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: 1, event: event)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if pressedButtons.remove(1) != nil { sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: 1, event: event) }
        else { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard reportsMouse(event) else { return }
        pressedButtons.insert(event.buttonNumber)
        sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: event.buttonNumber, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard pressedButtons.remove(event.buttonNumber) != nil else { return }
        sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: event.buttonNumber, event: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Clear", action: #selector(clearTerminal(_:)), keyEquivalent: "")
        return menu
    }

    private var scrollRemainder: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        let alt = vt.isAlternateScreen
        if reportsMouse(event) || (alt && vt.mode(1007)) {
            var dy = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas { dy /= renderer.font.cellHeight }
            scrollRemainder += dy
            let lines = Int(scrollRemainder)
            guard lines != 0 else { return }
            scrollRemainder -= CGFloat(lines)
            for _ in 0..<min(abs(lines), 20) {
                if reportsMouse(event) {
                    sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: lines > 0 ? 3 : 4, event: event)
                } else {
                    // Alternate scroll mode: wheel → arrow keys (less, man).
                    pty?.write(Data((lines > 0 ? (vt.mode(1) ? "\u{1b}OA" : "\u{1b}[A") : (vt.mode(1) ? "\u{1b}OB" : "\u{1b}[B")).utf8))
                }
            }
            return
        }
        // Scrollback: the enclosing scroll view handles it.
        super.scrollWheel(with: event)
    }

    private func openLink(col: Int, row: Int) {
        if let link = vt.hyperlink(col: col, row: row), let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        // Detect a URL in the row's text around the clicked column.
        guard renderer.rows.indices.contains(row) else { return }
        let cells = renderer.rows[row].cells
        var text = "", columnAt: [Int] = []
        for (i, c) in cells.enumerated() {
            let t = c.text.isEmpty ? " " : c.text
            text += t
            columnAt += Array(repeating: i, count: t.utf16.count)
        }
        let ns = text as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            guard r.location < columnAt.count else { continue }
            let start = columnAt[r.location], end = columnAt[min(columnAt.count - 1, NSMaxRange(r) - 1)]
            if (start...end).contains(col), let url = match.url {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    // MARK: Edit actions

    /// The pasteboard for copy/paste (a private one while testing, so tests
    /// never touch the user's clipboard).
    static var pasteboard = NSPasteboard.general

    @objc func copy(_ sender: Any?) {
        guard let text = vt.selectionText, !text.isEmpty else { return }
        Self.pasteboard.clearContents()
        Self.pasteboard.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = Self.pasteboard.string(forType: .string) else { return }
        vt.scroll(GHOSTTY_SCROLL_VIEWPORT_BOTTOM)
        pty?.write(vt.encodePaste(text))
    }

    @objc override func selectAll(_ sender: Any?) {
        vt.selectAll()
        wake()
    }

    /// ⌘K: clear the screen and scrollback; the shell redraws its prompt.
    @objc func clearTerminal(_ sender: Any?) {
        if vt.isAlternateScreen { return }
        vt.writeLocal("\u{1b}[H\u{1b}[2J\u{1b}[3J")
        pty?.write(Data([0x0C]))
        requestFullFrame()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): vt.hasSelection
        case #selector(paste(_:)): Self.pasteboard.string(forType: .string) != nil
        default: true
        }
    }

    // MARK: Scrollback (driven by TerminalScrollView)

    func scrollTo(row: Int) {
        vt.scroll(GHOSTTY_SCROLL_VIEWPORT_ROW, row: row)
        wake()
    }

    // MARK: Debug

    var debugState: [String: Any] {
        ["cols": Int(cols), "rows": Int(rows), "title": title, "pwd": pwd,
         "cursor": [renderer.cursor.x, renderer.cursor.y], "alt": vt.isAlternateScreen,
         "scrollbar": [lastScrollbar.total, lastScrollbar.offset, lastScrollbar.len],
         "foreground": pty?.foregroundName ?? "", "cwd": pty?.foregroundDirectory ?? "",
         "focused": focused, "selection": vt.selectionText ?? NSNull(),
         "frames": framesRendered, "renderSeconds": renderSeconds, "drawSeconds": drawSeconds]
    }

    /// Types text into the shell as if pasted (no bracketing).
    func debugType(_ text: String) {
        vt.clearSelection()
        pty?.write(Data(text.utf8))
    }
}

/// Scrollback for a TerminalView with a native overlay scroller: the
/// document is as tall as the scrollback; the terminal stays pinned to the
/// visible area and shows the rows the scroll position points at.
final class TerminalScrollView: NSView {
    let terminal: TerminalView
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private var syncing = false

    init(cwd: String) {
        terminal = TerminalView(cwd: cwd)
        super.init(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.documentView = document
        document.addSubview(terminal)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        terminal.onScrollbar = { [weak self] sb in self?.sync(sb) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = scrollView.contentSize
        if document.frame.width != size.width || document.frame.height < size.height {
            document.frame.size = NSSize(width: size.width, height: max(size.height, document.frame.height))
        }
        terminal.frame = NSRect(origin: scrollView.contentView.bounds.origin, size: size)
    }

    private var scrollbar = GhosttyTerminalScrollbar()

    private func sync(_ sb: GhosttyTerminalScrollbar) {
        scrollbar = sb
        let size = scrollView.contentSize
        let ch = terminal.cellSize.height
        let hidden = CGFloat(sb.total > sb.len ? sb.total - sb.len : 0)
        syncing = true
        document.frame.size = NSSize(width: size.width, height: size.height + hidden * ch)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(sb.offset) * ch))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        terminal.frame.origin = scrollView.contentView.bounds.origin
        syncing = false
    }

    @objc private func clipScrolled() {
        terminal.frame.origin = scrollView.contentView.bounds.origin
        guard !syncing else { return }
        let row = Int((scrollView.contentView.bounds.origin.y / terminal.cellSize.height).rounded())
        if row != Int(scrollbar.offset) { terminal.scrollTo(row: row) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
