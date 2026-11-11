import AppKit
import Sparkle
import SwiftUI

/// Updates, through Sparkle.
///
/// The feed is the newest GitHub release's `appcast.xml` (Info.plist:
/// `SUFeedURL`), which `scripts/release.sh --publish` writes and signs; every
/// push to `main` publishes one (`scripts/publish-on-push.sh`). Toasty checks
/// hourly. An update downloads quietly and installs when Toasty quits, so
/// nothing running is interrupted; Toasty ▸ Check for Updates… installs one
/// right away.
///
/// Only the released app updates itself. Toasty Debug is a separate app that
/// a release must never replace, so there the updater stays off unless a
/// test feed is named:
///
///     defaults write com.martyvasquez.toasty.debug ToastyUpdateFeedURL http://localhost:8000/appcast.xml
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// A feed to use instead of the released one (testing).
    nonisolated private static var feedOverride: String? {
        UserDefaults.standard.string(forKey: "ToastyUpdateFeedURL").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether this copy of Toasty updates itself (see above).
    static let isAvailable: Bool = {
        if AppDelegate.isRunningTests { return false }
        #if DEBUG
        return feedOverride != nil
        #else
        return true
        #endif
    }()

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var canCheck = false

    /// Starts the hourly checks. Called once, at launch.
    func start() {
        guard Self.isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        canCheck = controller.updater.canCheckForUpdates
        observations = [
            controller.updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                DispatchQueue.main.async { self?.canCheck = value }
            },
        ]
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// Settings ▸ General. Sparkle keeps both in the app's defaults.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride
    }
}

extension Updater: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }
}

/// Settings ▸ General: how updates arrive.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = Updater.shared

    /// The section's height in the General pane.
    static let height: CGFloat = 162

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
            Toggle("Install updates automatically", isOn: Binding(
                get: { updater.installsAutomatically }, set: { updater.installsAutomatically = $0 }))
                .disabled(!updater.checksAutomatically)
        } header: {
            Text("Updates")
        } footer: {
            Text("Toasty checks every hour. An update installs the next time Toasty quits, so nothing you have running is interrupted. To update now, choose Toasty ▸ Check for Updates…")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
