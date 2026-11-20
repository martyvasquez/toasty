import AppKit
import SwiftUI

/// The inspector's Tee-Up tab: prompts written ahead of time, each sent to
/// the open tab when its turn comes. The list is the workspace's, shared by
/// all of its tabs; a sent prompt leaves it.
///
/// A to-do list, as Things': every prompt is a one-line row with a box at
/// its start, and checking the box sends it. A click selects a row; a
/// double-click (or Return) opens it in place, as a card, to show and edit
/// all of it; Return or Esc closes it again, and so does a click anywhere
/// else (edits are kept as they're typed). "New Prompt" (or files dropped
/// on the tab) adds one, open.
struct TeeUpTab: View {
    @ObservedObject var workspace: Workspace
    /// Files are being dragged over the tab, or over one of its text fields.
    @State private var dropTargeted = false
    @State private var filesOverText = false
    /// The selected row (Things: a click selects, a double-click opens).
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool
    /// Where the rows are, so a double-click in the list's empty space (not
    /// on a row) starts a new prompt.
    @State private var rowsAnchor = ViewAnchor()

    var body: some View {
        VStack(spacing: 0) {
            if workspace.teeUps.isEmpty {
                InspectorEmpty(symbol: InspectorTab.teeUp.symbol, title: "Nothing Teed Up",
                               detail: "Write prompts ahead of time, then send each one to the open tab when you're ready.")
                    .background(DoubleClick { newAtEnd() })
            } else {
                list
            }
            if let feed = workspace.teeUpFeed {
                TeeUpFeedStatus(workspace: workspace, feed: feed).transition(.opacity)
            }
        }
        // Files dropped anywhere on the tab go on the open prompt, or
        // start a new one.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { workspace.attachToTeeUp($0) }
            return true
        }
        .overlay { if dropTargeted || filesOverText { DropTargetOverlay() } }
        .animation(.easeOut(duration: 0.12), value: dropTargeted || filesOverText)
        .animation(TeeUpStyle.open, value: workspace.teeUpEditingID)
        .animation(TeeUpStyle.open, value: workspace.teeUps.map(\.id))
    }

    /// The rows, then "New Prompt" (alone at the top of an empty tab).
    private var list: some View {
        let open = workspace.teeUpEditingID
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ReorderableStack(items: workspace.teeUps, spacing: 0,
                                     canDrag: { $0.id != open },
                                     move: { workspace.moveTeeUp($0, to: $1) }) { item, lifted in
                        let i = workspace.teeUps.firstIndex { $0.id == item.id } ?? 0
                        TeeUpCard(item: Binding(get: { workspace.teeUps.first { $0.id == item.id } ?? item },
                                                set: { workspace.updateTeeUp($0) }),
                                  open: open == item.id,
                                  selected: selection == item.id,
                                  focused: listFocused,
                                  target: workspace.selected?.title,
                                  lifted: lifted,
                                  canMoveUp: i > 0,
                                  canMoveDown: i < workspace.teeUps.count - 1,
                                  send: { workspace.sendTeeUp(item.id) },
                                  select: { select(item.id) },
                                  edit: { workspace.editTeeUp(item.id) },
                                  close: { refocus in
                                      guard workspace.teeUpEditingID == item.id else { return }
                                      // Left empty, it goes: the selection
                                      // goes back to the row above it.
                                      let ids = workspace.teeUps.map(\.id)
                                      let empty = workspace.teeUps.first { $0.id == item.id }?.isEmpty == true
                                      let above = ids.firstIndex(of: item.id).flatMap { $0 > 0 ? ids[$0 - 1] : nil }
                                      close()
                                      if refocus {
                                          if !empty { selectAfterEditing(item.id) }
                                          else if let above { selectAfterEditing(above) }
                                      }
                                  },
                                  move: { workspace.moveTeeUp(item.id, to: i + $0) },
                                  hold: { workspace.setTeeUpHeld(item.id, !item.isHeld) },
                                  delete: { workspace.removeTeeUp(item.id) },
                                  filesTargeted: $filesOverText)
                            .id(item.id)
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    }
                    // A click anywhere that isn't on a row (the list's empty
                    // space, the rest of the window) clears the selection.
                    .background { if selection != nil { ClickOutside { selection = nil } } }
                    .background(AnchorView(anchor: rowsAnchor))
                }
                .padding(.horizontal, Theme.Todo.inset)
                .padding(.bottom, Theme.Todo.inset)
                // Room for an open first row's card to grow into.
                .padding(.top, Theme.Todo.openWiden)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A double-click in the empty space under the rows starts a new
            // prompt at the end (as in Things).
            .background(DoubleClick(excluding: rowsAnchor) { newAtEnd() })
            // So does the keyboard going elsewhere.
            .onChange(of: listFocused) { _, focused in if !focused { selection = nil } }
            // The keyboard works the list as Things': arrows move the
            // selection, Return opens it, Delete deletes it.
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .onKeyPress(.return) {
                guard let id = selection, open == nil else { return .ignored }
                workspace.editTeeUp(id)
                return .handled
            }
            .onKeyPress(.delete) {
                guard let id = selection, open == nil else { return .ignored }
                let ids = workspace.teeUps.map(\.id)
                let i = ids.firstIndex(of: id) ?? 0
                workspace.removeTeeUp(id)
                let left = workspace.teeUps.map(\.id)
                selection = left.isEmpty ? nil : left[min(i, left.count - 1)]
                return .handled
            }
            // Space starts a new prompt right under the selected one (as
            // in Things).
            .onKeyPress(.space) {
                guard open == nil else { return .ignored }
                let after = selection
                selection = nil
                workspace.newTeeUp(after: after)
                return .handled
            }
            .onKeyPress(.escape) {
                guard selection != nil, open == nil else { return .ignored }
                selection = nil
                return .handled
            }
            // A prompt opened below the fold comes into view.
            .onChange(of: open) { _, id in
                guard let id else { return }
                selection = nil
                // The open prompt's editor has the keyboard: the list lets
                // go of it (or it takes it back from the editor).
                listFocused = false
                DispatchQueue.main.async { withAnimation(TeeUpStyle.open) { proxy.scrollTo(id) } }
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
            // A sent or deleted prompt takes its selection with it.
            .onChange(of: workspace.teeUps.map(\.id)) { _, ids in
                if let s = selection, !ids.contains(s) { selection = nil }
            }
        }
    }

    private func newAtEnd() {
        selection = nil
        workspace.newTeeUp()
    }

    private func select(_ id: UUID) {
        selection = id
        listFocused = true
    }

    /// Return or Esc in an open prompt: it stays selected and the list
    /// gets the keyboard, so Space starts the next one under it (Things'
    /// way of writing to-dos one after another). The editor lets go of the
    /// keyboard first; the list can't take it from the editor directly.
    private func selectAfterEditing(_ id: UUID) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        selection = id
        DispatchQueue.main.async {
            listFocused = true
            selection = id
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        guard workspace.teeUpEditingID == nil, !workspace.teeUps.isEmpty else { return .ignored }
        let ids = workspace.teeUps.map(\.id)
        guard let s = selection, let i = ids.firstIndex(of: s) else {
            selection = by > 0 ? ids.first : ids.last
            return .handled
        }
        selection = ids[max(0, min(ids.count - 1, i + by))]
        return .handled
    }

    /// Closes the open prompt. One left empty rolls all the way up as it
    /// fades, in one motion (as a cancelled Things to-do), and once it's
    /// nothing it's taken out of the list.
    private func close() {
        guard let id = workspace.teeUpEditingID else { return }
        let empty = workspace.teeUps.first { $0.id == id }?.isEmpty == true
        workspace.endTeeUpEdit(keepingEmpty: empty)
        guard empty else { return }
        if selection == id { selection = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + TeeUpStyle.openDuration) {
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) { workspace.removeTeeUpIfEmpty(id) }
        }
    }
}

private enum TeeUpStyle {
    static let fontSize = Theme.Size.body
    /// From an open card's top to the composer: its first line is centered
    /// in a row's height, `Theme.Todo.cardTop` inside the card.
    static var cardTop: CGFloat {
        Theme.Todo.cardTop + (Theme.Todo.rowHeight - lineHeight) / 2 - composerInset - baselineShift
    }
    /// The text's least height: the first line, the gap, and room for more.
    static var minText: CGFloat {
        composerInset * 2 + lineHeight + Theme.Todo.titleSpacing + Theme.Todo.notesMinHeight
    }
    /// The composer sets its text this much lower in a line than a label
    /// does (measured), so an open row's text lines up with the closed one.
    static let baselineShift: CGFloat = 3
    static var cardLeading: CGFloat { Theme.Todo.rowLeading + Theme.Todo.openWiden }
    /// The text's margin from an open card's right edge (Things' 16).
    static let textTrailing: CGFloat = 16
    /// The composer's own space above its first line.
    static let composerInset: CGFloat = 3
    /// One line of body text in the composer.
    static let lineHeight: CGFloat = 17
    static let pictureSize: CGFloat = 36
    /// The editor's line pitch at `fontSize`, as it draws (measured on
    /// screen), for the stand-in text shown while a card animates.
    static let editorLinePitch: CGFloat = 20
    /// A row opening and closing (Things': about a quarter second).
    /// Measured from Things at 60fps: a quartic ease-out, most of the way
    /// in the first 100ms, settled by a quarter second (snappy, then soft).
    static let openDuration: TimeInterval = 0.26
    static let open = Animation.timingCurve(0.25, 1, 0.5, 1, duration: openDuration)
}

// MARK: - Row

/// One teed-up prompt. Closed, a row: the box, its first line, a mark for
/// attachments. Open, a card with all of it, editable, and its actions.
private struct TeeUpCard: View {
    @Binding var item: TeeUp
    let open: Bool
    let selected: Bool
    /// The list has the keyboard: the selection is blue rather than gray.
    let focused: Bool
    /// The open tab's title: where Send goes (nil with no tab open).
    let target: String?
    /// Picked up, being dragged to a new place.
    let lifted: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let send: () -> Void
    let select: () -> Void
    let edit: () -> Void
    /// Closes it; true selects it and gives the list the keyboard (Return
    /// and Esc), false leaves both alone (a click elsewhere).
    let close: (Bool) -> Void
    let move: (Int) -> Void
    let hold: () -> Void
    let delete: () -> Void
    @Binding var filesTargeted: Bool
    @State private var height: CGFloat = ClaudeComposer.minHeight
    /// The card's shape, animated toward `open` (opening grows it from the
    /// row; closing shrinks it back, its contents staying till it's a row).
    @State private var expanded = false
    @State private var collapsing = false
    /// Closed empty: it rolls up to nothing as it fades (and the list then
    /// takes it out), in one motion with the rest of its close.
    @State private var vanishing = false
    /// The editor is shown only once the card is fully open: while it
    /// grows or shrinks, a SwiftUI copy of the text stands in (an AppKit
    /// view doesn't move or clip with SwiftUI's animation). The editor is
    /// there all along, hidden, so typing goes in from the first moment.
    @State private var editorShown = false
    /// Asks the editor for the keyboard: on opening, after the list has let
    /// go of it (which could otherwise take it back), and again once open.
    @State private var focusRequest = 0
    /// The row's width in the list (the open card is wider by its margins).
    @State private var slotWidth: CGFloat = 0

    private var attachmentCount: Int { item.images.count + item.files.count }

    var body: some View {
        // One view that changes size, as Things' to-dos: the first line
        // never fades (closed and open, it's in the same place in the
        // row), the card grows from the row around it, uncovering the rest,
        // and moves down with the space it opens above itself.
        Group {
            if open || collapsing { card.transition(.identity) } else { row.transition(.identity) }
        }
        .frame(height: expanded ? nil : (vanishing ? 0 : Theme.Todo.rowHeight), alignment: .top)
        .padding(.top, expanded ? Theme.Todo.cardTop : 0)
        .padding(.leading, expanded ? TeeUpStyle.cardLeading : Theme.Todo.rowLeading)
        .padding(.trailing, expanded ? TeeUpStyle.textTrailing : Theme.Todo.rowTrailing)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? Theme.Todo.cardRadius : Theme.Radius.row, style: .continuous))
        .background { background }
        // Fades evenly as it rolls up (the roll itself is quick to start),
        // so it's seen to shrink away rather than blink out.
        .opacity(vanishing ? 0 : 1)
        // A prompt that appears open (a new one) grows from its row, as
        // the others do.
        .onAppear {
            guard open else { return }
            DispatchQueue.main.async {
                focusRequest += 1
                withAnimation(TeeUpStyle.open) { expanded = true } completion: {
                    guard self.open else { return }
                    var now = Transaction()
                    now.disablesAnimations = true
                    withTransaction(now) { editorShown = true }
                    focusRequest += 1
                }
            }
        }
        .onChange(of: open) { _, open in
            if open {
                collapsing = false
                vanishing = false
                DispatchQueue.main.async { focusRequest += 1 }
                withAnimation(TeeUpStyle.open) { expanded = true } completion: {
                    guard self.open else { return }
                    var now = Transaction()
                    now.disablesAnimations = true
                    withTransaction(now) { editorShown = true }
                    focusRequest += 1
                }
            } else {
                collapsing = true
                if item.isEmpty {
                    withAnimation(.linear(duration: TeeUpStyle.openDuration)) { vanishing = true }
                }
                // The stand-in takes over at once (not faded).
                var now = Transaction()
                now.disablesAnimations = true
                withTransaction(now) { editorShown = false }
                withAnimation(TeeUpStyle.open) { expanded = false } completion: {
                    if !self.open { collapsing = false }
                }
            }
        }
        // A click anywhere else in the window closes an open row.
        .background { if open { ClickOutside(action: { close(false) }) } }
        // Open, it grows past its neighbors and moves them aside.
        .padding(.horizontal, expanded ? -Theme.Todo.openWiden : 0)
        // Open, it's set apart above and below (as Things': the rows above
        // stay put, the ones below move down).
        .padding(.vertical, expanded ? Theme.Todo.openSpace : 0)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slotWidth = $0 }
        .contentShape(Rectangle())
        // A click selects; a double-click opens (AppKit's click count, so
        // it follows the system's double-click speed).
        .onTapGesture { if !open { select() } }
        .background { if !open { DoubleClick(action: edit) } }
        .animation(.easeOut(duration: 0.15), value: lifted)
        .contextMenu {
            Button(TeeUpBox.sendHelp(target), action: send).disabled(target == nil)
            Divider()
            if !open { Button("Edit", action: edit) }
            Button("Move Up") { move(-1) }.disabled(!canMoveUp)
            Button("Move Down") { move(1) }.disabled(!canMoveDown)
            Divider()
            Toggle("Hold Back from Auto-Send", isOn: Binding(get: { item.isHeld }, set: { _ in hold() }))
            Divider()
            Button("Delete", action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
        // The card's surface fades in as it grows (and out as it shrinks).
        RoundedRectangle(cornerRadius: expanded ? Theme.Todo.cardRadius : Theme.Radius.row, style: .continuous)
            .fill(Theme.Todo.card)
            .opacity(expanded ? 1 : 0)
        if open {
            EmptyView()
        } else if lifted {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.Tooltip.background)
                .popoverShadow()
        } else if selected {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(focused ? Theme.Todo.selection : Theme.Todo.selectionInactive)
                // The selection moves at once, never fades along with an
                // opening or closing row.
                .transition(.identity)
        }
    }

    private var box: some View {
        TeeUpBox(held: item.isHeld, target: target, send: send)
    }

    private var row: some View {
        HStack(spacing: Theme.Todo.boxGap) {
            box
            Text(title)
                .font(.toasty(TeeUpStyle.fontSize))
                .foregroundStyle(item.text.isEmpty || item.isHeld ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            // Marks right after the title, as Things' notes mark: more
            // than one line, and attachments.
            if hasMore {
                mark("doc", "More than one line")
            }
            if attachmentCount > 0 {
                mark("paperclip", attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments")
            }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.Todo.rowHeight)
        .help(item.text)
    }

    private func mark(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.toasty(Theme.Size.caption, .medium))
            .foregroundStyle(Theme.Todo.mark)
            .padding(.leading, 1)
            .help(help)
            .accessibilityLabel(help)
    }

    /// The prompt goes on past its first line.
    private var hasMore: Bool {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline)
    }

    /// The first line that says something.
    private var title: String {
        let line = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if !line.isEmpty { return line }
        if attachmentCount == 0 { return "New Prompt" }
        return attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments"
    }

    /// Open: the box beside the whole prompt, its pictures and files under
    /// the text, and its actions, faint, at the bottom right (as Things'
    /// open to-do).
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: Theme.Todo.boxGap) {
                box.padding(.top, TeeUpStyle.composerInset + (TeeUpStyle.lineHeight - Theme.Todo.box) / 2 + 3)
                ClaudeComposer(
                    text: $item.text,
                    height: $height,
                    placeholder: "New Prompt",
                    focusToken: focusRequest,
                    onSubmit: { close(true) },
                    onEscape: { close(true); return true },
                    onShiftTab: {},
                    onPasteImage: { item.attach($0) },
                    onFiles: { item.attach($0) },
                    onFilesTargeted: { filesTargeted = $0 },
                    fontSize: TeeUpStyle.fontSize,
                    onBlur: { close(false) },
                    titleSpacing: Theme.Todo.titleSpacing,
                    concealed: !editorShown)
                    .frame(height: max(TeeUpStyle.minText, min(height, 200)))
            }
            // The first line where a closed row's is (the card's own top
            // margin is outside).
            .padding(.top, TeeUpStyle.cardTop - Theme.Todo.cardTop)
            .allowsHitTesting(open)

            if !editorShown { textCopy.allowsHitTesting(false).transition(.identity) }
            }

            if !item.images.isEmpty || !item.files.isEmpty {
                TeeUpAttachments(item: $item)
                    .padding(.leading, Theme.Todo.box + Theme.Todo.boxGap)
                    .padding(.top, 8)
            }

            // Things' open to-do: its actions in a row at the bottom right.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                TeeUpIconButton(symbol: "paperclip", help: "Attach Files…", action: pick)
                TeeUpIconButton(symbol: item.isHeld ? "play" : "pause",
                                help: item.isHeld ? "Include in Auto-Send" : "Hold Back from Auto-Send",
                                action: hold)
            }
            .padding(.top, Theme.Space.m)
            .padding(.trailing, Theme.Todo.actionTrailing - TeeUpStyle.textTrailing)
            .padding(.bottom, Theme.Todo.actionBottom)
        }
        .animation(TeeUpStyle.open, value: height)
        .animation(TeeUpStyle.open, value: attachmentCount)
    }

    /// The open prompt as the editor lays it out, in SwiftUI: shown while
    /// the card grows and shrinks. The first line is the closed row's (on
    /// the same pixels as the editor's), the rest under it at the editor's
    /// line height, after the title's gap.
    private var textCopy: some View {
        let lines = item.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        let rest = lines.count > 1 ? String(lines[1]) : ""
        let font = NSFont.systemFont(ofSize: TeeUpStyle.fontSize)
        let line = TeeUpStyle.editorLinePitch
        let natural = ClaudeTypography.naturalLineHeight(font)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Todo.boxGap) {
                box
                Text(first.isEmpty ? "New Prompt" : first)
                    .font(.toasty(TeeUpStyle.fontSize))
                    .foregroundStyle(first.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: Theme.Todo.rowHeight)
            if !rest.isEmpty {
                Text(rest)
                    .font(.toasty(TeeUpStyle.fontSize))
                    .lineSpacing(line - natural)
                    // Wrapped at the open card's width throughout, as the
                    // editor wraps it (not re-wrapped as the card grows).
                    .frame(width: textWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Todo.box + Theme.Todo.boxGap)
                    // Its first line centered where the editor's second is:
                    // a line and the title's gap below the first.
                    .padding(.top, line + Theme.Todo.titleSpacing - (Theme.Todo.rowHeight + natural) / 2)
            }
        }
    }

    /// The editor's width in the open card.
    private var textWidth: CGFloat {
        max(0, slotWidth + Theme.Todo.openWiden * 2 - TeeUpStyle.cardLeading - TeeUpStyle.textTrailing
            - Theme.Todo.box - Theme.Todo.boxGap)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            item.attach(panel.urls)
        }
    }
}

/// A prompt's box, as Things' checkbox: checking it sends the prompt. Held
/// back from Auto-Send, its outline is dashed (Things' "later" box). Under
/// the pointer it shows the arrow; checked, it fills with the accent for a
/// moment before the prompt goes.
private struct TeeUpBox: View {
    let held: Bool
    let target: String?
    let send: () -> Void
    @State private var hovering = false
    @State private var checked = false

    static func sendHelp(_ target: String?) -> String {
        target.map { "Send to “\($0)”" } ?? "Open a tab to send this"
    }

    var body: some View {
        let side = Theme.Todo.box - 2
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        let ready = target != nil
        Button {
            guard ready, !checked else { return }
            withAnimation(.easeOut(duration: 0.12)) { checked = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { send() }
        } label: {
            ZStack {
                shape.fill(checked ? Color.accentColor : Color.clear)
                shape.strokeBorder(checked ? Color.accentColor : (hovering && ready ? Color.secondary : Theme.Todo.mark),
                                   style: StrokeStyle(lineWidth: 1.25, dash: held && !checked ? [2, 2] : []))
                if checked || (hovering && ready) {
                    Image(systemName: "arrow.up")
                        .font(.toasty(Theme.Glyph.small, .bold))
                        .foregroundStyle(checked ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: side, height: side)
            .frame(width: Theme.Todo.box, height: Theme.Todo.box)
            .contentShape(Rectangle())
            .opacity(ready ? 1 : 0.5)
        }
        .buttonStyle(TeeUpBoxStyle())
        .onHover { hovering = $0 }
        .tooltip(ready ? "Send" : "Nothing to Send To",
                 detail: ready ? "To “\(target!)”\(held ? ". Held back from Auto-Send." : "")" : "Open a tab to send this prompt to.")
        .accessibilityLabel("Send")
    }
}

/// The box grows a little while it's pressed (as Things' checkboxes).
private struct TeeUpBoxStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.2 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Calls `action` for a double-click on the view it's the background of
/// (the clicks still go where they're aimed).
private struct DoubleClick: NSViewRepresentable {
    /// Double-clicks on this view don't count (the rows, inside the list's
    /// empty space).
    var excluding: ViewAnchor? = nil
    let action: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.action = action
        view.excluding = excluding
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var action: () -> Void = {}
        var excluding: ViewAnchor?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            // On the second click's release: once the click is done with,
            // so whatever it lands on can't take the keyboard back from a
            // prompt this opens.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if let self, let window = self.window, event.window === window, event.clickCount == 2,
                   self.convert(self.bounds, to: nil).contains(event.locationInWindow),
                   !(self.excluding?.contains(event.locationInWindow) ?? false) {
                    DispatchQueue.main.async { self.action() }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Calls `action` for a click in its window that isn't on the view it's
/// the background of: whatever is there (another card, the conversation,
/// the sidebar, empty space) still gets the click.
private struct ClickOutside: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) { view.action = action }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, let window = self.window, event.window === window,
                   !self.convert(self.bounds, to: nil).contains(event.locationInWindow),
                   !KeepsTeeUpOpen.contains(event.locationInWindow, in: window) {
                    // After the click has gone where it was aimed: closing
                    // first would move things from under the pointer.
                    DispatchQueue.main.async { self.action() }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // Only watches: clicks on the card go to the card.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The Tee-Up tab's buttons in the inspector's footer, at its right end
/// (as New Heading in the sidebar's): New Prompt and Auto-Send; while
/// Auto-Send runs, Pause (or Resume) and Stop in Auto-Send's place.
struct TeeUpBarButtons: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 0) {
            if let id = workspace.teeUpEditingID {
                // As Things' toolbar while a to-do is open: the open
                // prompt's actions in place of the list's.
                openActions(id)
            } else {
                listActions
            }
        }
        // Clicking these doesn't close the open prompt they act on.
        .background(KeepsTeeUpOpen())
    }

    @ViewBuilder private func openActions(_ id: UUID) -> some View {
        let item = workspace.teeUps.first { $0.id == id }
        button("arrow.up", Tooltip(title: "Send", detail: workspace.selected.map { "To “\($0.title)”." } ?? "Open a tab to send this prompt to.")) {
            _ = workspace.sendTeeUp(id)
        }
        .disabled(workspace.selected == nil || item?.isEmpty != false)
        button("trash", Tooltip(title: "Delete", detail: "Delete this prompt.")) { workspace.removeTeeUp(id) }
        button("ellipsis", Tooltip(title: "More")) { more(id) }
    }

    /// The open prompt's other actions, in a menu under the pointer.
    private func more(_ id: UUID) {
        guard let i = workspace.teeUps.firstIndex(where: { $0.id == id }) else { return }
        let item = workspace.teeUps[i]
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Move Up", enabled: i > 0) { workspace.moveTeeUp(id, to: i - 1) })
        menu.addItem(ActionMenuItem("Move Down", enabled: i < workspace.teeUps.count - 1) { workspace.moveTeeUp(id, to: i + 1) })
        menu.addItem(.separator())
        let hold = ActionMenuItem("Hold Back from Auto-Send") { workspace.setTeeUpHeld(id, !item.isHeld) }
        hold.state = item.isHeld ? .on : .off
        menu.addItem(hold)
        menu.addItem(ActionMenuItem("Attach Files…") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.begin { if $0 == .OK { workspace.attachToTeeUp(panel.urls) } }
        })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @ViewBuilder private var listActions: some View {
            button("plus", Tooltip(title: "New Prompt", shortcut: "⌃⌘\(InspectorTab.teeUp.shortcut)",
                                   detail: "Write a prompt to send later.")) { workspace.newTeeUp() }
            if let feed = workspace.teeUpFeed {
                if feed.paused != nil {
                    button("play", Tooltip(title: "Resume", detail: "Carry on sending to “\(tab)”.")) { workspace.resumeTeeUpFeed() }
                        .disabled(workspace.nextTeeUpToFeed == nil)
                } else {
                    button("pause", Tooltip(title: "Pause",
                                            detail: "Send nothing more to “\(tab)” until you resume. Claude finishes what it has.")) {
                        workspace.pauseTeeUpFeed()
                    }
                }
                button("stop", Tooltip(title: "Stop Auto-Send", detail: "The prompts that are left stay teed up.")) {
                    workspace.stopTeeUpFeed()
                }
            } else {
                button("play", Tooltip(title: "Auto-Send", detail: startHelp)) { workspace.requestTeeUpFeed() }
                    .disabled(!canStart)
            }
    }

    /// The capsule's width: callers shift the buttons by its margin so the
    /// last glyph, not its capsule, ends on their edge.
    static let width: CGFloat = 32
    static var margin: CGFloat { (width - Theme.Sidebar.iconSize) / 2 }

    private func button(_ symbol: String, _ tooltip: Tooltip, action: @escaping () -> Void) -> some View {
        BarIconButton(symbol: symbol, tooltip: tooltip, glyphSize: Theme.Size.body,
                      size: CGSize(width: Self.width, height: Theme.Control.height), action: action)
    }

    private var tab: String { workspace.teeUpFeedTab?.title ?? "" }

    private var canStart: Bool { workspace.selected != nil && workspace.nextTeeUpToFeed != nil }

    private var startHelp: String {
        guard let selected = workspace.selected else { return "Open a tab to send prompts to." }
        guard !workspace.teeUps.isEmpty else { return "Tee up a prompt first." }
        guard workspace.nextTeeUpToFeed != nil else { return "Every prompt is held back." }
        return "Send these to “\(selected.title)” one after another, each when Claude finishes the one before."
    }
}

/// While Auto-Send runs: what it's doing, and below it why it paused (or
/// what the reply check decided), in full. A quiet line under the list.
private struct TeeUpFeedStatus: View {
    @ObservedObject var workspace: Workspace
    let feed: TeeUpFeed

    var body: some View {
        let detail = (feed.paused ?? feed.verdict).flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.xs) {
                Group {
                    if feed.paused != nil {
                        Text("Paused")
                    } else if let at = feed.nextAt {
                        TimelineView(.periodic(from: .now, by: 0.25)) { context in
                            Text("Next in \(max(1, Int(at.timeIntervalSince(context.date).rounded(.up))))s")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    } else if feed.checking != nil {
                        Text("Checking Claude's reply…")
                    } else {
                        Text("Sending to “\(workspace.teeUpFeedTab?.title ?? "")”")
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                Text("· \(workspace.teeUps.filter { !$0.isHeld }.count) left").foregroundStyle(.tertiary).fixedSize()
            }
            if let detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.toasty(Theme.Size.meta))
        .padding(.horizontal, Theme.Inspector.edge)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of an open row's actions: a faint icon that turns blue under the
/// pointer (as Things' open to-do's).
private struct TeeUpIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.toasty(Theme.Sidebar.iconSize, .regular))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.headingBlue) : AnyShapeStyle(Theme.Todo.action))
                .frame(width: Theme.Todo.actionSlot, height: Theme.Todo.actionSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Attachments

/// An open prompt's pictures and files, each with a remove button.
private struct TeeUpAttachments: View {
    @Binding var item: TeeUp

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.images, id: \.self) { name in
                    picture(name)
                        .overlay(alignment: .topTrailing) {
                            RemoveAttachmentButton(label: "Remove Image") { item.images.removeAll { $0 == name } }
                        }
                }
                ForEach(item.files, id: \.self) { path in
                    AttachedFileChip(url: URL(fileURLWithPath: path), height: TeeUpStyle.pictureSize)
                        .overlay(alignment: .topTrailing) {
                            RemoveAttachmentButton(label: "Remove \((path as NSString).lastPathComponent)") {
                                item.files.removeAll { $0 == path }
                            }
                        }
                }
            }
            // Room for the remove buttons, which sit over the corners.
            .padding(.top, 5).padding(.trailing, 5)
        }
        .padding(.top, -5)
    }

    private func picture(_ name: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        return Group {
            if let image = TeeUpImages.image(name) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.Fill.subtle
            }
        }
        .frame(width: TeeUpStyle.pictureSize, height: TeeUpStyle.pictureSize)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Stroke.border))
        .accessibilityLabel("Picture")
    }
}

// MARK: - Reordering

/// A column of rows that are dragged up and down to reorder them, like the
/// tabs in the titlebar (`FittingTabStrip`): the dragged row follows the
/// pointer, the others step aside, and the order changes when it's let go.
/// Rows can be any height.
private struct ReorderableStack<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    let items: [Item]
    let spacing: CGFloat
    var canDrag: (Item) -> Bool = { _ in true }
    /// Put the row at this index.
    let move: (Item.ID, Int) -> Void
    /// A row; the flag says it's picked up.
    @ViewBuilder let row: (Item, Bool) -> Row

    private struct Drag {
        let id: Item.ID
        /// Where it was picked up.
        let from: Int
        /// How far it is from its own place.
        var y: CGFloat = 0
        /// Let go: it has its new place, and is sliding the rest of the way.
        var settling = false
    }

    @State private var dragState: Drag?
    @State private var heights: [Item.ID: CGFloat] = [:]

    /// The drag, while its row is still in the list.
    private var drag: Drag? {
        dragState.flatMap { d in items.contains { $0.id == d.id } ? d : nil }
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let dragged = drag?.id == item.id
                row(item, dragged && drag?.settling == false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[item.id] = $0 }
                    .offset(y: offset(of: i))
                    .zIndex(dragged ? 1 : 0)
                    // The dragged row stays under the pointer while the
                    // others slide.
                    .transaction { if dragged, drag?.settling == false { $0.animation = nil } }
                    .gesture(reorder(item, at: i), including: canDrag(item) ? .all : .subviews)
            }
        }
    }

    private var layout: ReorderLayout {
        ReorderLayout(heights: items.map { heights[$0.id] ?? 0 }, spacing: spacing)
    }

    /// How far row `i` is drawn from its place: the dragged row by the
    /// drag, the rows it has passed by its height the other way.
    private func offset(of i: Int) -> CGFloat {
        guard let drag, items.indices.contains(drag.from) else { return 0 }
        if items[i].id == drag.id { return drag.y }
        return drag.settling ? 0 : layout.offset(of: i, from: drag.from, y: drag.y)
    }

    private func reorder(_ item: Item, at i: Int) -> some Gesture {
        // Global: the row moves with the drag, so its own coordinates do too.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let layout = layout
                var d = drag ?? Drag(id: item.id, from: i)
                guard d.id == item.id, !d.settling, items.indices.contains(d.from) else { return }
                let before = layout.target(from: d.from, y: d.y)
                d.y = layout.clamped(value.translation.height, from: d.from)
                if drag == nil || layout.target(from: d.from, y: d.y) != before {
                    withAnimation(.easeInOut(duration: 0.15)) { dragState = d }
                } else {
                    dragState = d
                }
            }
            .onEnded { _ in
                let layout = layout
                guard var d = drag, d.id == item.id, !d.settling else { return }
                let to = layout.target(from: d.from, y: d.y)
                // The others are already drawn where the new order puts
                // them, so that happens at once; the dragged row slides
                // from where it was let go.
                d.y -= layout.shift(from: d.from, to: to)
                d.settling = true
                var now = Transaction()
                now.disablesAnimations = true
                withTransaction(now) {
                    dragState = d
                    move(item.id, to)
                }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { dragState = nil }
                }
            }
    }
}

/// Where the rows of a column sit while one of them is dragged to a new
/// place. Rows can be any height.
struct ReorderLayout {
    let heights: [CGFloat]
    let spacing: CGFloat

    /// Where row `i` starts, from the top of the column.
    func top(_ i: Int) -> CGFloat {
        heights[..<i].reduce(0) { $0 + $1 + spacing }
    }

    /// The place the row from `from`, dragged by `y`, would take if let go
    /// now: it takes a row's place once its leading edge is past that
    /// row's middle.
    func target(from: Int, y: CGFloat) -> Int {
        let start = top(from) + y, end = start + heights[from]
        var to = from
        if y > 0 {
            for i in heights.indices.dropFirst(from + 1) where end > top(i) + heights[i] / 2 { to = i }
        } else if y < 0 {
            for i in heights.indices.prefix(from).reversed() where start < top(i) + heights[i] / 2 { to = i }
        }
        return to
    }

    /// How far a row's place moves when it goes from `from` to `to`.
    func shift(from: Int, to: Int) -> CGFloat {
        if to > from { return heights[(from + 1)...to].reduce(0) { $0 + $1 + spacing } }
        if to < from { return -heights[to..<from].reduce(0) { $0 + $1 + spacing } }
        return 0
    }

    /// A drag of `y`, kept inside the column.
    func clamped(_ y: CGFloat, from: Int) -> CGFloat {
        max(shift(from: from, to: 0), min(shift(from: from, to: heights.count - 1), y))
    }

    /// How far another row steps aside for the dragged one.
    func offset(of i: Int, from: Int, y: CGFloat) -> CGFloat {
        let to = target(from: from, y: y), step = heights[from] + spacing
        if from < i, i <= to { return -step }
        if to <= i, i < from { return step }
        return 0
    }
}

/// Marks a region (the footer's buttons for the open prompt) where a click
/// doesn't count as a click outside the open prompt.
private struct KeepsTeeUpOpen: NSViewRepresentable {
    @MainActor private static var regions: [WeakView] = []

    private struct WeakView { weak var view: NSView? }

    func makeNSView(context: Context) -> NSView {
        let v = Region()
        Self.regions.removeAll { $0.view == nil }
        Self.regions.append(WeakView(view: v))
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {}

    @MainActor static func contains(_ point: NSPoint, in window: NSWindow) -> Bool {
        regions.contains { r in
            guard let v = r.view, v.window === window, !v.isHiddenOrHasHiddenAncestor else { return false }
            return v.convert(v.bounds, to: nil).contains(point)
        }
    }

    private final class Region: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A menu item that runs a closure (the item keeps its target alive).
@MainActor private func ActionMenuItem(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) -> NSMenuItem {
    let target = MenuAction(handler)
    let item = NSMenuItem(title: title, action: enabled ? #selector(MenuAction.run) : nil, keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.isEnabled = enabled
    return item
}

private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

/// A view's place in its window, for probes that need to know where it is
/// (set by `AnchorView` placed behind it).
@MainActor private final class ViewAnchor {
    weak var view: NSView?

    func contains(_ point: NSPoint) -> Bool {
        guard let view, view.window != nil else { return false }
        return view.convert(view.bounds, to: nil).contains(point)
    }
}

private struct AnchorView: NSViewRepresentable {
    let anchor: ViewAnchor

    func makeNSView(context: Context) -> NSView {
        let v = Passthrough()
        anchor.view = v
        return v
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    private final class Passthrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
