import SwiftUI

/// The inspector's Tee-Up tab: prompts written ahead of time, each sent to
/// the open tab when its turn comes. The list is the workspace's, shared by
/// all of its tabs; a sent prompt leaves it.
///
/// Like a to-do list: every prompt is a one-line card. Clicking one opens
/// it in place to show and edit all of it; Return, Esc or a click anywhere
/// else closes it (edits are kept as they're typed). "New Prompt" (or
/// files dropped on the tab) adds a card, open.
struct TeeUpTab: View {
    @ObservedObject var workspace: Workspace
    /// Files are being dragged over the tab, or over one of its text fields.
    @State private var dropTargeted = false
    @State private var filesOverText = false

    var body: some View {
        VStack(spacing: 0) {
            list
            if workspace.teeUps.isEmpty {
                InspectorEmpty(symbol: InspectorTab.teeUp.symbol, title: "Nothing Teed Up",
                               detail: "Write prompts ahead of time, then send each one to the open tab when you're ready.")
            }
            if !workspace.teeUps.isEmpty || workspace.teeUpFeed != nil || workspace.teeUpFeedNote != nil {
                TeeUpFeedBar(workspace: workspace)
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

    /// The cards, then "New Prompt" (alone at the top of an empty tab).
    private var list: some View {
        let open = workspace.teeUpEditingID
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: TeeUpStyle.gap) {
                    ReorderableStack(items: workspace.teeUps, spacing: TeeUpStyle.gap,
                                     canDrag: { $0.id != open },
                                     move: { workspace.moveTeeUp($0, to: $1) }) { item, lifted in
                        let i = workspace.teeUps.firstIndex { $0.id == item.id } ?? 0
                        TeeUpCard(item: Binding(get: { workspace.teeUps.first { $0.id == item.id } ?? item },
                                                set: { workspace.updateTeeUp($0) }),
                                  open: open == item.id,
                                  target: workspace.selected?.title,
                                  lifted: lifted,
                                  canMoveUp: i > 0,
                                  canMoveDown: i < workspace.teeUps.count - 1,
                                  send: { workspace.sendTeeUp(item.id) },
                                  edit: { workspace.editTeeUp(item.id) },
                                  close: { if workspace.teeUpEditingID == item.id { close() } },
                                  move: { workspace.moveTeeUp(item.id, to: i + $0) },
                                  hold: { workspace.setTeeUpHeld(item.id, !item.isHeld) },
                                  delete: { workspace.removeTeeUp(item.id) },
                                  filesTargeted: $filesOverText)
                            .id(item.id)
                            .transition(.opacity)
                    }
                    TeeUpNewRow { workspace.newTeeUp() }
                }
                .padding(TeeUpStyle.margin)
            }
            .scrollBounceBehavior(.basedOnSize)
            // An empty tab is the row and, below it, the message.
            .frame(maxHeight: workspace.teeUps.isEmpty ? TeeUpStyle.rowHeight + TeeUpStyle.margin * 2 : .infinity)
            // A prompt opened below the fold comes into view.
            .onChange(of: open) { _, id in
                guard let id else { return }
                DispatchQueue.main.async { withAnimation(TeeUpStyle.open) { proxy.scrollTo(id) } }
            }
        }
    }

    private func close() {
        workspace.endTeeUpEdit()
    }
}

private enum TeeUpStyle {
    /// Around the list and the editor.
    static let margin: CGFloat = 10
    /// Between cards.
    static let gap: CGFloat = 6
    /// A card's text from its edge.
    static let inset: CGFloat = 12
    /// Every closed card.
    static let rowHeight: CGFloat = 36
    static let fontSize: CGFloat = 13
    /// Above an editor's text, so its first line is where a closed card's is.
    static let textTop: CGFloat = 3.5
    static let pictureSize: CGFloat = 36
    /// A card opening and closing.
    static let open = Animation.smooth(duration: 0.28)
}

/// A card: the composer's surface at inspector size.
private struct TeeUpSurface: ViewModifier {
    var lifted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous)
        content
            .background(shape.fill(Color.claudeField))
            // What's inside an opening card is uncovered, not squeezed.
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
    }
}

// MARK: - Card

/// One teed-up prompt. Closed, every card is the same: one line, an
/// attachment count, and send. Open, it's the whole prompt, editable.
private struct TeeUpCard: View {
    @Binding var item: TeeUp
    let open: Bool
    /// The open tab's title: where Send goes (nil with no tab open).
    let target: String?
    /// Picked up, being dragged to a new place.
    let lifted: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let send: () -> Void
    let edit: () -> Void
    let close: () -> Void
    let move: (Int) -> Void
    let hold: () -> Void
    let delete: () -> Void
    @Binding var filesTargeted: Bool
    @State private var hovering = false

    private var sendHelp: String {
        target.map { "Send to “\($0)”" } ?? "Open a tab to send this"
    }

    private var attachmentCount: Int { item.images.count + item.files.count }

    var body: some View {
        Group {
            if open {
                TeeUpEditor(item: $item, placeholder: "Prompt", focusToken: 0,
                            onReturn: close, onEscape: close, onBlur: close,
                            filesTargeted: $filesTargeted) {
                    TeeUpIconButton(symbol: "trash", help: "Delete", action: delete)
                    sendButton(ready: target != nil)
                }
                // A click anywhere else in the window closes it.
                .background { ClickOutside(action: close) }
                .transition(.opacity)
            } else {
                closed.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(TeeUpSurface(lifted: lifted))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: lifted)
        .onTapGesture { if !open { edit() } }
        .contextMenu {
            Button(sendHelp, action: send).disabled(target == nil)
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
    }

    private var closed: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: TeeUpStyle.fontSize))
                .foregroundStyle(item.text.isEmpty || item.isHeld ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.isHeld {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help("Held back from Auto-Send")
                    .accessibilityLabel("Held back from Auto-Send")
            }
            if attachmentCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "paperclip").font(.system(size: 10.5, weight: .medium))
                    if attachmentCount > 1 {
                        Text("\(attachmentCount)").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    }
                }
                .foregroundStyle(.tertiary)
                .help(attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments")
            }
            sendButton(ready: hovering && target != nil)
        }
        .padding(.leading, TeeUpStyle.inset)
        .padding(.trailing, 7)
        .frame(height: TeeUpStyle.rowHeight)
        .help(item.text)
    }

    /// The first line that says something.
    private var title: String {
        let line = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if !line.isEmpty { return line }
        return attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments"
    }

    private func sendButton(ready: Bool) -> some View {
        Button(action: send) {
            ZStack {
                Circle().fill(ready ? Color.accentColor : Color.primary.opacity(0.10))
                Image(systemName: "arrow.up")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ready ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .help(sendHelp)
        .accessibilityLabel("Send")
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
                   !self.convert(self.bounds, to: nil).contains(event.locationInWindow) {
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

/// Under the list: Auto-Send's switch and what it's doing. Off, it's one
/// quiet button; on, it names the tab, counts down to the next prompt, and
/// is where to pause. (Laid out like the inspector's Terminal footer.)
private struct TeeUpFeedBar: View {
    @ObservedObject var workspace: Workspace
    @State private var hovering = false

    var body: some View {
        let feed = workspace.teeUpFeed
        let left = workspace.teeUps.filter { !$0.isHeld }.count
        HStack(spacing: 6) {
            if let feed {
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                Group {
                    if let at = feed.nextAt {
                        TimelineView(.periodic(from: .now, by: 0.25)) { context in
                            Text("Next in \(max(1, Int(at.timeIntervalSince(context.date).rounded(.up))))s")
                                .monospacedDigit()
                        }
                    } else {
                        Text("Sending to “\(workspace.teeUpFeedTab?.title ?? "")”")
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                Text("· \(left) left").font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize()
                Spacer(minLength: 8)
                barButton("Pause", help: "Stop sending automatically. Claude finishes what it has.") {
                    workspace.stopTeeUpFeed()
                }
            } else {
                Button { workspace.requestTeeUpFeed() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play").font(.system(size: 10))
                        Text("Auto-Send…").font(.system(size: 12))
                    }
                    .foregroundStyle(hovering && canStart ? .primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .onHover { hovering = $0 }
                .help(startHelp)
                if let note = workspace.teeUpFeedNote {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .overlay(alignment: .top) { Rectangle().fill(Color.claudeSeparator).frame(height: 0.5) }
        .animation(.easeOut(duration: 0.15), value: feed)
    }

    private var canStart: Bool { workspace.selected != nil && workspace.nextTeeUpToFeed != nil }

    private var startHelp: String {
        guard let tab = workspace.selected else { return "Open a tab to send prompts to" }
        guard workspace.nextTeeUpToFeed != nil else { return "Every prompt is held back" }
        return "Send these to “\(tab.title)” one after another, each when Claude finishes the one before"
    }

    private func barButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .help(help)
    }
}

/// "New Prompt": a row the size of a card, under the last one.
private struct TeeUpNewRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                Text("New Prompt").font(.system(size: TeeUpStyle.fontSize))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .padding(.horizontal, TeeUpStyle.inset)
            .frame(height: TeeUpStyle.rowHeight)
            .background(RoundedRectangle(cornerRadius: ClaudeStyle.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("New Prompt (⌃⌘\(InspectorTab.teeUp.shortcut))")
    }
}

/// A quiet icon button for an open card's bottom row.
private struct TeeUpIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Editor

/// A prompt being written or edited: its text, then its pictures and
/// files, then a row with attach on the left and `trailing` on the right.
/// Pictures can be pasted; files can be pasted, dropped or picked.
private struct TeeUpEditor<Trailing: View>: View {
    @Binding var item: TeeUp
    let placeholder: String
    let focusToken: Int
    let onReturn: () -> Void
    let onEscape: () -> Void
    var onBlur: (() -> Void)?
    @Binding var filesTargeted: Bool
    @ViewBuilder var trailing: () -> Trailing
    @State private var height: CGFloat = ClaudeComposer.minHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClaudeComposer(
                text: $item.text,
                height: $height,
                placeholder: placeholder,
                focusToken: focusToken,
                onSubmit: onReturn,
                onEscape: { onEscape(); return true },
                onShiftTab: {},
                onPasteImage: { item.attach($0) },
                onFiles: { item.attach($0) },
                onFilesTargeted: { filesTargeted = $0 },
                fontSize: TeeUpStyle.fontSize,
                onBlur: onBlur)
                .frame(height: min(height, 200))
                .padding(.horizontal, TeeUpStyle.inset)
                // The first line sits where a closed card's one line does.
                .padding(.top, TeeUpStyle.textTop)

            if !item.images.isEmpty || !item.files.isEmpty {
                TeeUpAttachments(item: $item)
                    .padding(.horizontal, TeeUpStyle.inset)
                    .padding(.top, 8)
            }

            HStack(spacing: 4) {
                TeeUpIconButton(symbol: "plus", help: "Attach Files…", action: pick)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.leading, TeeUpStyle.inset - 6)
            .padding(.trailing, 7)
            .padding(.top, 4)
            .padding(.bottom, 7)
        }
        .animation(TeeUpStyle.open, value: height)
        .animation(TeeUpStyle.open, value: item.images.count + item.files.count)
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
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Group {
            if let image = TeeUpImages.image(name) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: TeeUpStyle.pictureSize, height: TeeUpStyle.pictureSize)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
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
