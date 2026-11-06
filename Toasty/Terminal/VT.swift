import AppKit
import GhosttyVt

/// The one place Toasty talks to libghostty-vt's C API, so churn in the
/// (work-in-progress) API stays contained here.
///
/// Threading: the PTY reader thread feeds output with `write`; the main
/// thread renders, encodes input and changes selection. Every touch of the
/// terminal handle goes through `lock`. The render state is a snapshot,
/// updated under the lock and then read on the main thread alone.
nonisolated final class VTTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: GhosttyTerminal!
    private(set) var renderState: GhosttyRenderState!
    private(set) var rowIterator: GhosttyRenderStateRowIterator!
    private(set) var rowCells: GhosttyRenderStateRowCells!

    private var keyEncoder: GhosttyKeyEncoder!
    private var keyEvent: GhosttyKeyEvent!
    private var mouseEncoder: GhosttyMouseEncoder!
    private var mouseEvent: GhosttyMouseEvent!
    private var gesture: GhosttySelectionGesture!
    private var gesturePress: GhosttySelectionGestureEvent!
    private var gestureDrag: GhosttySelectionGestureEvent!
    private var gestureRelease: GhosttySelectionGestureEvent!

    /// Bytes the terminal answers with (device status reports, mode
    /// queries); called on the thread that wrote the output.
    var onWritePTY: (@Sendable (Data) -> Void)?
    /// Title, pwd or bell: called on the writing thread; hop to main.
    var onTitleChanged: (@Sendable () -> Void)?
    var onPwdChanged: (@Sendable () -> Void)?
    var onBell: (@Sendable () -> Void)?

    /// Output arrived since the last frame was rendered.
    private var _outputPending = false

    init(cols: UInt16, rows: UInt16) {
        ghostty_terminal_new(nil, &terminal, cols, rows)
        ghostty_render_state_new(nil, &renderState)
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &rowCells)
        ghostty_key_encoder_new(nil, &keyEncoder)
        ghostty_key_event_new(nil, &keyEvent)
        ghostty_mouse_encoder_new(nil, &mouseEncoder)
        ghostty_mouse_event_new(nil, &mouseEvent)
        ghostty_selection_gesture_new(nil, &gesture)
        ghostty_selection_gesture_event_new(nil, &gesturePress, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        ghostty_selection_gesture_event_new(nil, &gestureDrag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        ghostty_selection_gesture_event_new(nil, &gestureRelease, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)

        // Keep a generous scrollback, like Ghostty's default (10 MB).
        var maxBytes: UInt64 = 10_000_000
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &maxBytes)

        // Grapheme clustering on by default (Ghostty's default): emoji ZWJ
        // sequences and flags take the columns they're drawn in.
        var grapheme = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &grapheme)

        let me = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, me)
        let writePty: GhosttyTerminalWritePtyFn = { _, ud, data, len in
            guard let ud, let data else { return }
            Unmanaged<VTTerminal>.fromOpaque(ud).takeUnretainedValue().onWritePTY?(Data(bytes: data, count: len))
        }
        let title: GhosttyTerminalTitleChangedFn = { _, ud in
            guard let ud else { return }
            Unmanaged<VTTerminal>.fromOpaque(ud).takeUnretainedValue().onTitleChanged?()
        }
        let pwd: GhosttyTerminalPwdChangedFn = { _, ud in
            guard let ud else { return }
            Unmanaged<VTTerminal>.fromOpaque(ud).takeUnretainedValue().onPwdChanged?()
        }
        let bell: GhosttyTerminalBellFn = { _, ud in
            guard let ud else { return }
            Unmanaged<VTTerminal>.fromOpaque(ud).takeUnretainedValue().onBell?()
        }
        let xtversion: GhosttyTerminalXtversionFn = { _, _ in
            GhosttyString(ptr: VTTerminal.versionString.baseAddress, len: VTTerminal.versionString.count)
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwd, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self))
    }

    nonisolated(unsafe) private static let versionString: UnsafeBufferPointer<UInt8> = {
        let bytes = Array("Toasty".utf8)
        let p = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        _ = p.initialize(from: bytes)
        return UnsafeBufferPointer(p)
    }()

    deinit {
        ghostty_selection_gesture_event_free(gesturePress)
        ghostty_selection_gesture_event_free(gestureDrag)
        ghostty_selection_gesture_event_free(gestureRelease)
        ghostty_selection_gesture_free(gesture, terminal)
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    @inline(__always) private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: Output

    /// Feed bytes from the PTY (any thread).
    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        locked {
            ghostty_terminal_vt_write(terminal, base, bytes.count)
            _outputPending = true
        }
    }

    /// Write VT sequences into the terminal itself (not to the program).
    func writeLocal(_ s: String) {
        var bytes = Array(s.utf8)
        bytes.withUnsafeMutableBytes { write(UnsafeRawBufferPointer($0)) }
    }

    /// Updates the render state from the terminal. Returns false when nothing
    /// changed since the last frame and `force` is false.
    func updateRenderState(force: Bool) -> Bool {
        locked {
            guard force || _outputPending else { return false }
            _outputPending = false
            ghostty_render_state_update(renderState, terminal)
            return true
        }
    }

    // MARK: Size

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        locked {
            ghostty_terminal_resize(terminal, cols, rows, cellWidth, cellHeight)
            _outputPending = true
        }
    }

    // MARK: Queries

    var scrollbar: GhosttyTerminalScrollbar {
        locked {
            var s = GhosttyTerminalScrollbar()
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s)
            return s
        }
    }

    var title: String { string(GHOSTTY_TERMINAL_DATA_TITLE) }
    var pwd: String { string(GHOSTTY_TERMINAL_DATA_PWD) }

    private func string(_ key: GhosttyTerminalData) -> String {
        locked {
            var s = GhosttyString()
            guard ghostty_terminal_get(terminal, key, &s) == GHOSTTY_SUCCESS, let p = s.ptr, s.len > 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
        }
    }

    func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        locked {
            var m = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &m)
            return m.value
        }
    }

    var mouseTracking: Bool { bool(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING) }

    var isAlternateScreen: Bool {
        locked {
            var s = GhosttyTerminalScreen(0)
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &s)
            return s == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        }
    }

    private func bool(_ key: GhosttyTerminalData) -> Bool {
        locked {
            var b = false
            ghostty_terminal_get(terminal, key, &b)
            return b
        }
    }

    // MARK: Colors

    func setColors(foreground: GhosttyColorRgb, background: GhosttyColorRgb, cursor: GhosttyColorRgb, palette: [GhosttyColorRgb]) {
        locked {
            var fg = foreground, bg = background, cur = cursor
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cur)
            var full = palette
            // Keep the standard 256-color cube for 16…255.
            var defaults = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &defaults)
            if full.count < 256 { full += defaults[full.count...] }
            full.withUnsafeMutableBufferPointer { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
            _outputPending = true
        }
    }

    // MARK: Scrolling

    func scroll(_ tag: GhosttyTerminalScrollViewportTag, delta: Int = 0, row: Int = 0) {
        locked {
            var v = GhosttyTerminalScrollViewport()
            v.tag = tag
            if tag == GHOSTTY_SCROLL_VIEWPORT_ROW { v.value.row = row } else { v.value.delta = delta }
            ghostty_terminal_scroll_viewport(terminal, v)
            _outputPending = true
        }
    }

    // MARK: Input encoding

    struct Key {
        var action: GhosttyKeyAction
        var key: GhosttyKey
        var mods: GhosttyMods
        var consumedMods: GhosttyMods
        var text: String?
        var unshifted: UInt32
        var composing: Bool
    }

    func encode(_ k: Key, optionAsAlt: Bool) -> Data {
        locked {
            ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
            var alt = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
            ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt)
            ghostty_key_event_set_action(keyEvent, k.action)
            ghostty_key_event_set_key(keyEvent, k.key)
            ghostty_key_event_set_mods(keyEvent, k.mods)
            ghostty_key_event_set_consumed_mods(keyEvent, k.consumedMods)
            ghostty_key_event_set_composing(keyEvent, k.composing)
            ghostty_key_event_set_unshifted_codepoint(keyEvent, k.unshifted)
            var out = [CChar](repeating: 0, count: 128)
            var len = 0
            let result: GhosttyResult
            if let text = k.text, !text.isEmpty {
                result = text.withCString { p in
                    ghostty_key_event_set_utf8(keyEvent, p, strlen(p))
                    return ghostty_key_encoder_encode(keyEncoder, keyEvent, &out, out.count, &len)
                }
            } else {
                ghostty_key_event_set_utf8(keyEvent, nil, 0)
                result = ghostty_key_encoder_encode(keyEncoder, keyEvent, &out, out.count, &len)
            }
            guard result == GHOSTTY_SUCCESS, len > 0 else { return Data() }
            return out.withUnsafeBytes { Data($0.prefix(len)) }
        }
    }

    struct Mouse {
        var action: GhosttyMouseAction
        var button: GhosttyMouseButton?
        var mods: GhosttyMods
        var x: Float
        var y: Float
    }

    func encode(_ m: Mouse, size: GhosttyMouseEncoderSize, anyButtonPressed: Bool) -> Data {
        locked {
            ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
            var s = size
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &s)
            var pressed = anyButtonPressed
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
            var track = true
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track)
            ghostty_mouse_event_set_action(mouseEvent, m.action)
            if let b = m.button { ghostty_mouse_event_set_button(mouseEvent, b) } else { ghostty_mouse_event_clear_button(mouseEvent) }
            ghostty_mouse_event_set_mods(mouseEvent, m.mods)
            ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: m.x, y: m.y))
            var out = [CChar](repeating: 0, count: 64)
            var len = 0
            guard ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &out, out.count, &len) == GHOSTTY_SUCCESS, len > 0 else { return Data() }
            return out.withUnsafeBytes { Data($0.prefix(len)) }
        }
    }

    func encodeFocus(_ focused: Bool) -> Data {
        guard mode(1004) else { return Data() }
        var out = [CChar](repeating: 0, count: 8)
        var len = 0
        guard ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &out, out.count, &len) == GHOSTTY_SUCCESS else { return Data() }
        return out.withUnsafeBytes { Data($0.prefix(len)) }
    }

    /// Paste text as the program expects it (bracketed when it asked for it;
    /// unsafe control characters are neutralized by the encoder).
    func encodePaste(_ text: String) -> Data {
        let bracketed = mode(2004)
        var input = Array(text.utf8CString.dropLast())
        var out = [CChar](repeating: 0, count: input.count * 2 + 16)
        var len = 0
        let r = input.withUnsafeMutableBufferPointer { inp in
            ghostty_paste_encode(inp.baseAddress, inp.count, bracketed, &out, out.count, &len)
        }
        guard r == GHOSTTY_SUCCESS else { return Data(text.utf8) }
        return out.withUnsafeBytes { Data($0.prefix(len)) }
    }

    // MARK: Selection

    enum GestureKind { case press, drag, release }

    /// Feeds a selection gesture (click, double/triple click, drag) and
    /// applies the resulting selection to the terminal.
    func selectionGesture(_ kind: GestureKind, col: Int, row: Int, x: Double, y: Double,
                          timeNS: UInt64, repeatIntervalNS: UInt64,
                          geometry: GhosttySelectionGestureGeometry, rectangle: Bool) {
        locked {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.size
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: col), y: UInt32(clamping: row))
            let hasRef = ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS
            let event: GhosttySelectionGestureEvent = kind == .press ? gesturePress : kind == .drag ? gestureDrag : gestureRelease
            if hasRef { ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref) }
            else { ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil) }
            var pos = GhosttySurfacePosition(x: x, y: y)
            if kind != .release { ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos) }
            if kind == .press {
                var t = timeNS, interval = repeatIntervalNS
                var distance = 6.0
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &t)
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
            }
            if kind == .drag {
                var g = geometry
                var rect = rectangle
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &g)
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
            }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            let r = ghostty_selection_gesture_event(gesture, terminal, event, &selection)
            if r == GHOSTTY_SUCCESS {
                ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            } else if kind == .press {
                ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            }
            _outputPending = true
        }
    }

    func clearSelection() {
        locked {
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            _outputPending = true
        }
    }

    func selectAll() {
        locked {
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            if ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS {
                ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            }
            _outputPending = true
        }
    }

    var hasSelection: Bool {
        locked {
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        }
    }

    /// The selected text as plain text, or nil without a selection.
    var selectionText: String? {
        locked {
            var opts = GhosttyTerminalSelectionFormatOptions()
            opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            opts.trim = true
            opts.unwrap = true
            var buf: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, opts, &buf, &len) == GHOSTTY_SUCCESS,
                  let buf else { return nil }
            defer { ghostty_free(nil, buf, len) }
            return String(decoding: UnsafeBufferPointer(start: buf, count: len), as: UTF8.self)
        }
    }

    /// The OSC 8 hyperlink at a viewport cell, if any.
    func hyperlink(col: Int, row: Int) -> String? {
        locked {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.size
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: col), y: UInt32(clamping: row))
            guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
            var buf = [UInt8](repeating: 0, count: 4096)
            var len = 0
            guard ghostty_grid_ref_hyperlink_uri(&ref, &buf, buf.count, &len) == GHOSTTY_SUCCESS, len > 0 else { return nil }
            return String(decoding: buf.prefix(len), as: UTF8.self)
        }
    }

    /// Plain text of the whole screen including scrollback (debug, tests).
    var plainText: String {
        locked {
            var opts = GhosttyFormatterTerminalOptions()
            opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
            opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            opts.trim = true
            var formatter: GhosttyFormatter?
            guard ghostty_formatter_terminal_new(nil, &formatter, terminal, opts) == GHOSTTY_SUCCESS, let formatter else { return "" }
            defer { ghostty_formatter_free(formatter) }
            var buf: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_formatter_format_alloc(formatter, nil, &buf, &len) == GHOSTTY_SUCCESS, let buf else { return "" }
            defer { ghostty_free(nil, buf, len) }
            return String(decoding: UnsafeBufferPointer(start: buf, count: len), as: UTF8.self)
        }
    }
}
