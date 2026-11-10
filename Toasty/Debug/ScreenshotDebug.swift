#if DEBUG
import AppKit

/// Debug commands for ⇧⌘0 screenshots: the parts that can be tested without
/// dragging over the screen.
enum ScreenshotDebug {
    typealias E = DebugControl.DebugError

    static func install() {
        DebugControl.register("screenshotState") { _ in
            ["hotKeyRegistered": ScreenshotCapture.shared.isHotKeyRegistered,
             "global": ScreenshotSettings.shared.global,
             "permission": CGPreflightScreenCaptureAccess()]
        }

        // Attach a picture file as a finished capture would: {"cmd":"screenshotAttach","path":"/x.png"}
        DebugControl.register("screenshotAttach") { cmd in
            guard let path = cmd["path"] as? String,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw E("path required") }
            return ["attached": ScreenshotCapture.shared.attach(data)]
        }

        // {"cmd":"screenshotGlobal","on":false}
        DebugControl.register("screenshotGlobal") { cmd in
            ScreenshotSettings.shared.global = cmd["on"] as? Bool ?? true
            return ["hotKeyRegistered": ScreenshotCapture.shared.isHotKeyRegistered]
        }
    }
}
#endif
