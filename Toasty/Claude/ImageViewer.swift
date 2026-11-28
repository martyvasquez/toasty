import AppKit
import SwiftUI

/// A picture you attached, seen again at full size: click a thumbnail (in a
/// sent message or the composer) and it opens over the window, dimmed
/// behind. Esc, Space, or a click outside the picture closes it.
final class ImageViewer: ObservableObject {
    static let shared = ImageViewer()

    @Published private(set) var image: NSImage?
    /// The window it opened in: the others' overlays stay out of it.
    private(set) weak var window: NSWindow?
    private var keyMonitor: Any?

    func show(_ image: NSImage, in window: NSWindow? = NSApp.keyWindow) {
        self.window = window
        self.image = image
        guard keyMonitor == nil else { return }
        // Wherever focus is (the composer, a terminal), Esc and Space close
        // it, and other typing doesn't land behind it. ⌘ shortcuts pass.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.image != nil, e.window === self.window else { return e }
            if e.modifierFlags.contains(.command) { return e }
            if e.keyCode == 53 || e.keyCode == 49 { self.close() }   // Esc, Space
            return nil
        }
    }

    func close() {
        image = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Over the whole window while a picture is open.
struct ImageViewerOverlay: View {
    @ObservedObject private var viewer = ImageViewer.shared
    /// This overlay's window, to show only the picture opened in it.
    let window: () -> NSWindow?

    var body: some View {
        ZStack {
            if let image = viewer.image, viewer.window === window() {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { viewer.close() }
                    .transition(.opacity)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // Never blown up past its own size: a small screenshot
                    // stays sharp.
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    // Clicking the picture itself doesn't close it.
                    .onTapGesture {}
                    .padding(.horizontal, 64)
                    .padding(.vertical, 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .accessibilityLabel("Attached image")
            }
        }
        .animation(.easeOut(duration: 0.16), value: viewer.image)
    }
}

/// Clicks pass through while no picture is open.
final class ImageViewerHostingView: NSHostingView<ImageViewerOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard ImageViewer.shared.image != nil, ImageViewer.shared.window === window else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
