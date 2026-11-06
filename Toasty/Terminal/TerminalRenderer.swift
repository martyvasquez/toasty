import AppKit
import CoreText
import GhosttyVt

/// One row of the grid, copied out of libghostty-vt's render state so the
/// row can be drawn (and redrawn) without touching the terminal.
struct TerminalRow: Equatable {
    struct Cell: Equatable {
        var text: String = ""
        var fg: TerminalTheme.RGB?
        var bg: TerminalTheme.RGB?
        var bold = false
        var italic = false
        var faint = false
        var inverse = false
        var invisible = false
        var strikethrough = false
        var overline = false
        var underline: Int32 = 0
        var underlineColor: TerminalTheme.RGB?
        /// Occupies two columns (the next cell is its spacer).
        var wide = false
    }

    var cells: [Cell] = []
    /// Inclusive selected column range, if the row is (partly) selected.
    var selection: ClosedRange<Int>?
}

/// Reads the render state into row snapshots and draws rows with Core Text,
/// every glyph pinned to its cell so fallback fonts (CJK, emoji, symbols)
/// keep the grid.
@MainActor
final class TerminalRenderer {
    private(set) var rows: [TerminalRow] = []
    private(set) var cols = 0
    var font = TerminalFont()
    var theme = TerminalTheme.dark

    struct Cursor: Equatable {
        var visible = false
        var x = 0, y = 0
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        var blinking = false
        var wideTail = false
    }
    private(set) var cursor = Cursor()

    /// Rows whose snapshot changed in the last `update`.
    private(set) var changedRows = IndexSet()

    /// Pulls a new frame from the render state. Returns rows to redraw.
    func update(from vt: VTTerminal) -> IndexSet {
        let state = vt.renderState!
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)

        var colsN: UInt16 = 0, rowsN: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &colsN)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowsN)
        var full = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
        if Int(colsN) != cols || Int(rowsN) != rows.count {
            cols = Int(colsN)
            rows = Array(repeating: TerminalRow(), count: Int(rowsN))
            full = true
        }

        var changed = IndexSet()
        var c = GhosttyRenderStateCursor()
        c.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c)
        let newCursor = Cursor(visible: c.visible && c.viewport_has_value, x: Int(c.viewport_x), y: Int(c.viewport_y),
                               style: c.visual_style, blinking: c.blinking, wideTail: c.wide_tail)
        if newCursor != cursor {
            if cursor.visible { changed.insert(cursor.y) }
            if newCursor.visible { changed.insert(newCursor.y) }
            cursor = newCursor
        }

        guard dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE || full else { return changed }

        var iterator = vt.rowIterator
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator)
        var cellsHandle = vt.rowCells
        var y = 0
        var codepoints = [UInt32](repeating: 0, count: 32)
        while ghostty_render_state_row_iterator_next(iterator) {
            defer { y += 1 }
            guard y < rows.count else { break }
            var rowDirty = false
            ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            guard rowDirty || full else { continue }

            var row = TerminalRow()
            row.cells.reserveCapacity(cols)
            var sel = GhosttyRenderStateRowSelection()
            sel.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            if ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS {
                row.selection = Int(sel.start_x)...Int(sel.end_x)
            }
            ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle)
            while ghostty_render_state_row_cells_next(cellsHandle) {
                var cell = TerminalRow.Cell()
                var len: UInt32 = 0
                ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
                if len > 0 {
                    if Int(len) > codepoints.count { codepoints = [UInt32](repeating: 0, count: Int(len)) }
                    ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &codepoints)
                    var s = String.UnicodeScalarView()
                    for i in 0..<Int(len) { if let u = Unicode.Scalar(codepoints[i]) { s.append(u) } }
                    cell.text = String(s)
                    if codepoints[0] >= 0x1100 {
                        var raw = GhosttyCell()
                        ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                        var wide = GHOSTTY_CELL_WIDE_NARROW
                        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                        cell.wide = wide == GHOSTTY_CELL_WIDE_WIDE
                    }
                }
                var styled = false
                ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
                var rgb = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb) == GHOSTTY_SUCCESS {
                    cell.bg = .init(rgb)
                }
                if styled {
                    if ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) == GHOSTTY_SUCCESS {
                        cell.fg = .init(rgb)
                    }
                    var style = GhosttyStyle()
                    style.size = MemoryLayout<GhosttyStyle>.size
                    ghostty_render_state_row_cells_get(cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                    cell.bold = style.bold
                    cell.italic = style.italic
                    cell.faint = style.faint
                    cell.inverse = style.inverse
                    cell.invisible = style.invisible
                    cell.strikethrough = style.strikethrough
                    cell.overline = style.overline
                    cell.underline = style.underline
                    if style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB {
                        cell.underlineColor = .init(style.underline_color.value.rgb)
                    } else if style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE {
                        cell.underlineColor = theme.palette.indices.contains(Int(style.underline_color.value.palette))
                            ? theme.palette[Int(style.underline_color.value.palette)] : nil
                    }
                }
                row.cells.append(cell)
            }
            var clean = false
            ghostty_render_state_row_set(iterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
            if row != rows[y] || full {
                rows[y] = row
                changed.insert(y)
            }
        }
        var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
        return changed
    }

    // MARK: Drawing

    struct DrawOptions {
        var cursorShown: Bool
        var focused: Bool
        var markedText: String?
        var scale: CGFloat
    }

    /// Draws one row whose top-left cell corner is at `origin` in a flipped
    /// context. The row's background spans `fullWidth` (the padding too).
    func draw(row y: Int, in ctx: CGContext, origin: CGPoint, fullWidth: CGFloat, options: DrawOptions) {
        guard rows.indices.contains(y) else { return }
        let row = rows[y]
        let cw = font.cellWidth, ch = font.cellHeight
        let defaultBG = theme.background, defaultFG = theme.foreground

        func colors(_ cell: TerminalRow.Cell, col: Int) -> (fg: TerminalTheme.RGB, bg: TerminalTheme.RGB?) {
            var fg = cell.fg ?? defaultFG
            var bg = cell.bg
            if cell.inverse {
                let oldBG = bg ?? defaultBG
                bg = fg
                fg = oldBG
            }
            if let sel = row.selection, sel.contains(col) {
                bg = theme.selectionBackground
                fg = theme.selectionForeground
            }
            return (fg, bg)
        }

        // Backgrounds, merged into runs.
        var col = 0
        while col < row.cells.count {
            let (_, bg) = colors(row.cells[col], col: col)
            var end = col + 1
            while end < row.cells.count, colors(row.cells[end], col: end).bg == bg { end += 1 }
            if let bg, bg != defaultBG {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(cellRect(col, span: end - col, origin: origin, scale: options.scale))
            }
            col = end
        }

        let cursorHere = options.cursorShown && cursor.visible && cursor.y == y
        let cursorCol = cursor.wideTail ? cursor.x - 1 : cursor.x
        let blockCursor = cursorHere && options.focused && cursor.style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
            && options.markedText == nil
        let cursorWidth = CGFloat(row.cells.indices.contains(cursorCol) && row.cells[cursorCol].wide ? 2 : 1) * cw
        if blockCursor {
            ctx.setFillColor(theme.cursor.cgColor)
            ctx.fill(CGRect(x: origin.x + CGFloat(cursorCol) * cw, y: origin.y, width: cursorWidth, height: ch))
        }

        // Text, in runs of the same font and color.
        let baselineY = origin.y + font.baseline
        col = 0
        while col < row.cells.count {
            let cell = row.cells[col]
            if cell.text.isEmpty || cell.invisible || cell.text == " " { col += 1; continue }
            var (fg, _) = colors(cell, col: col)
            if blockCursor && col == cursorCol { fg = theme.cursorText }
            if TerminalSprites.handles(cell.text) {
                TerminalSprites.draw(cell.text, in: ctx,
                                     rect: cellRect(col, span: 1, origin: origin, scale: options.scale),
                                     color: cell.faint ? fg.cgColor(alpha: 0.5) : fg.cgColor, scale: options.scale)
                col += 1
                continue
            }
            let ctFont = font.font(bold: cell.bold, italic: cell.italic)
            var text = ""
            var columns: [Int] = []   // UTF-16 offset → column
            var end = col
            while end < row.cells.count {
                let c = row.cells[end]
                var (cfg, _) = colors(c, col: end)
                if blockCursor && end == cursorCol { cfg = theme.cursorText }
                if c.text.isEmpty { end += 1; continue }
                if c.invisible || TerminalSprites.handles(c.text) || c.bold != cell.bold || c.italic != cell.italic || c.faint != cell.faint || cfg != fg { break }
                text += c.text
                columns += Array(repeating: end, count: c.text.utf16.count)
                end += c.wide ? 2 : 1
            }
            if !text.isEmpty {
                drawText(text, columns: columns, cells: row.cells, font: ctFont,
                         color: cell.faint ? fg.cgColor(alpha: 0.5) : fg.cgColor,
                         in: ctx, originX: origin.x, baselineY: baselineY)
            }
            col = max(end, col + 1)
        }

        // Decorations.
        for (i, cell) in row.cells.enumerated() where cell.underline != 0 || cell.strikethrough || cell.overline {
            let (fg, _) = colors(cell, col: i)
            let x = origin.x + CGFloat(i) * cw
            let w = cw * (cell.wide ? 2 : 1)
            let t = font.underlineThickness
            if cell.underline != 0 {
                ctx.setStrokeColor((cell.underlineColor ?? fg).cgColor)
                ctx.setLineWidth(t)
                let uy = baselineY - font.underlinePosition + t / 2 + 0.5
                switch cell.underline {
                case 2: // double
                    ctx.strokeLineSegments(between: [CGPoint(x: x, y: uy - 1), CGPoint(x: x + w, y: uy - 1),
                                                     CGPoint(x: x, y: uy + 1.5), CGPoint(x: x + w, y: uy + 1.5)])
                case 3: // curly
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: x, y: uy))
                    let step = w / 2
                    path.addQuadCurve(to: CGPoint(x: x + step, y: uy), control: CGPoint(x: x + step / 2, y: uy - 2))
                    path.addQuadCurve(to: CGPoint(x: x + w, y: uy), control: CGPoint(x: x + step * 1.5, y: uy + 2))
                    ctx.addPath(path)
                    ctx.strokePath()
                default:
                    ctx.strokeLineSegments(between: [CGPoint(x: x, y: uy), CGPoint(x: x + w, y: uy)])
                }
            }
            ctx.setStrokeColor(fg.cgColor)
            ctx.setLineWidth(t)
            if cell.strikethrough {
                let sy = (baselineY - CTFontGetXHeight(font.regular) / 2).rounded() + 0.5
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: sy), CGPoint(x: x + w, y: sy)])
            }
            if cell.overline {
                ctx.strokeLineSegments(between: [CGPoint(x: x, y: origin.y + t / 2), CGPoint(x: x + w, y: origin.y + t / 2)])
            }
        }

        // Non-block cursors, and the hollow block when unfocused.
        if cursorHere && !blockCursor && options.markedText == nil {
            let x = origin.x + CGFloat(cursorCol) * cw
            ctx.setFillColor(theme.cursor.cgColor)
            ctx.setStrokeColor(theme.cursor.cgColor)
            if !options.focused || cursor.style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW {
                ctx.setLineWidth(1)
                ctx.stroke(CGRect(x: x + 0.5, y: origin.y + 0.5, width: cursorWidth - 1, height: ch - 1))
            } else if cursor.style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR {
                ctx.fill(CGRect(x: x, y: origin.y, width: 2, height: ch))
            } else if cursor.style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE {
                ctx.fill(CGRect(x: x, y: origin.y + ch - 2, width: cursorWidth, height: 2))
            }
        }

        // IME preedit at the cursor.
        if let marked = options.markedText, !marked.isEmpty, cursor.y == y {
            let x = origin.x + CGFloat(cursor.x) * cw
            let attr = NSAttributedString(string: marked, attributes: [.font: font.regular, .foregroundColor: NSColor(cgColor: defaultFG.cgColor)!])
            let line = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.setFillColor(defaultBG.cgColor)
            ctx.fill(CGRect(x: x, y: origin.y, width: CGFloat(width), height: ch))
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(line, ctx)
            ctx.setStrokeColor(defaultFG.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: origin.y + ch - 1.5), CGPoint(x: x + CGFloat(width), y: origin.y + ch - 1.5)])
        }
    }

    /// A run of cells, its left and right edges on device pixels so that
    /// neighboring fills (blocks, backgrounds) meet without seams.
    private func cellRect(_ col: Int, span: Int, origin: CGPoint, scale: CGFloat) -> CGRect {
        let x0 = ((origin.x + CGFloat(col) * font.cellWidth) * scale).rounded() / scale
        let x1 = ((origin.x + CGFloat(col + span) * font.cellWidth) * scale).rounded() / scale
        return CGRect(x: x0, y: origin.y, width: x1 - x0, height: font.cellHeight)
    }

    private func drawText(_ text: String, columns: [Int], cells: [TerminalRow.Cell], font ctFont: CTFont,
                          color: CGColor, in ctx: CGContext, originX: CGFloat, baselineY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: ctFont, .ligature: 0]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let cw = font.cellWidth
        ctx.setFillColor(color)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            var runFont = (runAttrs[kCTFontAttributeName] as! CTFont?) ?? ctFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)

            // Fallback glyphs wider than their cells (emoji, some symbols)
            // are scaled down to fit.
            var scale: CGFloat = 1
            var clusterStartX: [Int: CGFloat] = [:]
            for i in 0..<count {
                let si = indices[i]
                guard si < columns.count else { continue }
                let column = columns[si]
                let span = cells.indices.contains(column) && cells[column].wide ? 2.0 : 1.0
                if clusterStartX[column] == nil {
                    clusterStartX[column] = positions[i].x
                    let maxWidth = span * cw
                    if advances[i].width > maxWidth * 1.05 { scale = min(scale, maxWidth / advances[i].width) }
                }
            }
            if scale < 1 { runFont = CTFontCreateCopyWithAttributes(runFont, CTFontGetSize(runFont) * scale, nil, nil) }

            var drawn = [CGPoint](repeating: .zero, count: count)
            for i in 0..<count {
                let si = indices[i]
                let column = si < columns.count ? columns[si] : 0
                let span = cells.indices.contains(column) && cells[column].wide ? 2.0 : 1.0
                let start = clusterStartX[column] ?? positions[i].x
                let firstAdvance = advances[i].width * scale
                let centering = positions[i].x == start ? max(0, (span * cw - firstAdvance) / 2) : 0
                drawn[i] = CGPoint(x: originX + CGFloat(column) * cw + (positions[i].x - start) * scale + centering,
                                   y: baselineY)
            }
            // Flip each glyph upright in the flipped context.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: baselineY * 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            for i in 0..<count { drawn[i].y = baselineY }
            CTFontDrawGlyphs(runFont, glyphs, drawn, count, ctx)
            ctx.restoreGState()
        }
    }
}
