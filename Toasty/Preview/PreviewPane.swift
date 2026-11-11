import AppKit
import SwiftUI
import WebKit

/// The right column while the preview has it: the active workspace's page.
/// Nothing is built (no web view, no page load) unless it's showing.
struct PreviewColumn: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ZStack {
            Color.claudeChrome.ignoresSafeArea()
            if let workspace = store.active { PreviewColumnWorkspace(workspace: workspace) }
        }
    }
}

private struct PreviewColumnWorkspace: View {
    @ObservedObject var workspace: Workspace
    /// While the page has the whole window it's shown by `PreviewDrawerPage`.
    @ObservedObject private var drawer = PreviewDrawer.shared

    var body: some View {
        if workspace.previewShowing, !drawer.active { PreviewPane(workspace: workspace, overWindow: false) }
    }
}

/// The workspace's page. Its controls (`PreviewToolbar`) are in the
/// titlebar row above the column.
struct PreviewPane: View {
    @ObservedObject var workspace: Workspace
    /// Which of the page's two places this is: across the window under the
    /// drawer (`PreviewDrawerPage`), or the right column.
    let overWindow: Bool

    var body: some View {
        PreviewContent(workspace: workspace, session: PreviewStore.shared.session(for: workspace), overWindow: overWindow)
            .id(workspace.id)
    }
}

private struct PreviewContent: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: PreviewSession
    let overWindow: Bool

    var body: some View {
        VStack(spacing: 0) {
            LoadingLine(session: session)
            if session.started {
                PreviewPage(workspace: workspace, session: session, overWindow: overWindow)
            } else {
                PreviewStart(workspace: workspace, session: session)
            }
        }
        .onAppear {
            // Pick up where the workspace left off.
            if !session.started, !session.address.isEmpty { session.open(session.address) }
        }
    }
}

/// Page loading progress, drawn over the toolbar's hairline.
private struct LoadingLine: View {
    @ObservedObject var session: PreviewSession

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(Color.accentColor)
                .frame(width: geo.size.width * session.progress, height: 2)
                .opacity(session.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: session.progress)
                .animation(.easeOut(duration: 0.3), value: session.isLoading)
        }
        .frame(height: 2)
    }
}

// MARK: - Toolbar

/// The preview's controls, shown in the titlebar row over its column.
struct PreviewToolbar: View {
    let workspace: Workspace
    @ObservedObject var session: PreviewSession
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            PreviewDrawerControls(workspace: workspace)
            PreviewIconButton(symbol: session.isLoading ? "xmark" : "arrow.clockwise",
                              help: session.isLoading ? "Stop" : "Reload") {
                if session.isLoading { session.stopLoading() } else { session.reload() }
            }
            .disabled(!session.started)

            TextField("localhost:3000", text: $session.address)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($addressFocused)
                .onSubmit {
                    session.open(session.address)
                    addressFocused = false
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                .padding(.horizontal, 4)
                .accessibilityLabel("Address")

            ForEach(PreviewViewport.allCases) { viewport in
                PreviewIconButton(symbol: viewport.symbol, help: "\(viewport.title) Size (⇧⌘M switches)",
                                  selected: session.viewport == viewport) {
                    session.setViewport(viewport)
                }
            }
            PreviewIconButton(symbol: session.commenting ? "plus.bubble.fill" : "plus.bubble",
                              help: session.commenting ? "Done Commenting (esc)" : "Comment on the Page",
                              tint: session.commenting ? .accentColor : nil) {
                session.setCommenting(!session.commenting)
            }
            .disabled(session.url == nil || session.failure != nil)
            PreviewIconButton(symbol: "arrow.up.forward.square", help: "Open in \(PreviewBrowser.name)") {
                if let url = session.url { NSWorkspace.shared.open(url) }
            }
            .disabled(session.url == nil)
        }
        .padding(.horizontal, 6)
    }
}

/// The user's default browser, for the "Open in …" button.
private enum PreviewBrowser {
    static var name: String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://localhost")!) else { return "Browser" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// A toolbar button like the inspector's and the terminal strip's.
struct PreviewIconButton: View {
    let symbol: String
    let help: String
    var selected = false
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(tint.map(AnyShapeStyle.init)
                    ?? (selected || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.09 : hovering && enabled ? 0.05 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Start

/// Before any page: where the dev server is, if a terminal said.
private struct PreviewStart: View {
    let workspace: Workspace
    @ObservedObject var session: PreviewSession
    @State private var addresses: [String] = []

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "safari")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Preview")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(addresses.isEmpty ? "Type your dev server's address in the bar above, or ask Claude to open it."
                                   : "Running in this workspace's terminal:")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(addresses, id: \.self) { address in
                Button(address) { session.open(address) }
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { addresses = PreviewStore.shared.localAddresses(in: workspace) }
    }
}

// MARK: - Page

private struct PreviewPage: View {
    let workspace: Workspace
    @ObservedObject var session: PreviewSession
    let overWindow: Bool

    var body: some View {
        GeometryReader { geo in
            let fit = session.viewport.fit(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.claudeChrome
                PreviewWebHost(session: session, page: fit.page, overWindow: overWindow)
                    .frame(width: fit.display.width, height: fit.display.height)
                    .overlay(Rectangle().strokeBorder(Color.claudeSeparator, lineWidth: 0.5)
                        .opacity(fit.display.width < geo.size.width - 1 || fit.display.height < geo.size.height - 1 ? 1 : 0))
                    .offset(x: fit.display.minX, y: fit.display.minY)
                if let failure = session.failure {
                    PreviewFailure(failure: failure) { session.open(failure.address) }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(Color.claudeChrome)
                } else if let pick = session.pick {
                    let field = CommentField.frame(for: pick.rect, fit: fit, pane: geo.size)
                    CommentField { note, send in
                        Task { await session.comment(note, in: workspace, send: send) }
                    } cancel: {
                        session.cancelPick()
                    }
                    .frame(width: field.width, height: field.height)
                    .offset(x: field.minX, y: field.minY)
                    .id(pick)
                }
            }
        }
        .clipped()
    }
}

private struct PreviewFailure: View {
    let failure: PreviewSession.Failure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            InspectorEmpty(symbol: "exclamationmark.triangle", title: "Can't Open \(failure.address)", detail: failure.reason)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again", action: retry)
                .controlSize(.small)
                .padding(.top, -14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where a comment is typed: a small field by the thing that was picked.
/// Return sends it to the conversation; ⇧Return adds it to the composer
/// instead (to send several together); Esc drops the pick.
private struct CommentField: View {
    let submit: (_ note: String, _ send: Bool) -> Void
    let cancel: () -> Void
    @State private var note = ""
    @FocusState private var focused: Bool

    static let height: CGFloat = 34

    /// Under the pick when there's room, else above it; always in the pane.
    static func frame(for rect: CGRect, fit: PreviewViewport.Fit, pane: CGSize) -> CGRect {
        let shown = CGRect(x: fit.display.minX + rect.minX * fit.scale, y: fit.display.minY + rect.minY * fit.scale,
                           width: rect.width * fit.scale, height: rect.height * fit.scale)
        let width = min(300, max(120, pane.width - 16))
        let x = min(max(8, shown.midX - width / 2), max(8, pane.width - width - 8))
        var y = shown.maxY + 8
        if y + height > pane.height - 8 { y = shown.minY - 8 - height }
        y = min(max(8, y), max(8, pane.height - height - 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.bubble")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            TextField("Comment for Claude", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .onSubmit { submit(note, !NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand(perform: cancel)
            Text("↩").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("Return sends the comment to Claude. Shift-Return adds it to the message box instead, to send several together.")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.claudeField)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - Web view host

/// Shows the session's web view at the page's real size, drawn to fit.
private struct PreviewWebHost: NSViewRepresentable {
    let session: PreviewSession
    let page: CGSize
    let overWindow: Bool

    func makeNSView(context: Context) -> PreviewStage { PreviewStage() }

    func updateNSView(_ stage: PreviewStage, context: Context) {
        // The page changes places (window or column) a moment before the
        // place it left is taken down: that one mustn't take the web view back.
        guard PreviewDrawer.shared.active == overWindow else { return }
        stage.show(session, page: page)
    }

    static func dismantleNSView(_ stage: PreviewStage, coordinator: ()) {
        stage.clear()
    }
}

/// Holds a web view laid out at the page's size (what the site sees) and
/// scaled to this view's size (what the pane has room for), so a 1280-wide
/// desktop page is still 1280 wide to its CSS in a 400-point sidebar, and
/// pictures of it are taken at full size.
final class PreviewStage: NSView {
    private let canvas = PreviewCanvas()
    private weak var session: PreviewSession?
    private var page: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ session: PreviewSession, page: CGSize) {
        self.page = page
        if self.session !== session { clear() }
        self.session = session
        session.stage = self
        let web = session.web()
        if web.superview !== canvas { canvas.addSubview(web) }
        needsLayout = true
    }

    /// Give the web view back (the pane closed or shows another workspace):
    /// it keeps running at its nominal size.
    func clear() {
        guard let session else { return }
        self.session = nil
        if session.stage === self { session.stage = nil }
        if let web = session.webView, web.superview === canvas {
            web.removeFromSuperview()
            web.frame = NSRect(origin: .zero, size: session.viewport.nominal)
        }
    }

    override func layout() {
        super.layout()
        guard page.width > 0, page.height > 0, bounds.width > 0 else { return }
        canvas.frame = bounds
        canvas.setBoundsOrigin(.zero)
        canvas.setBoundsSize(page)
        session?.webView?.frame = NSRect(origin: .zero, size: page)
    }
}

private final class PreviewCanvas: NSView {
    override var isFlipped: Bool { true }
}
