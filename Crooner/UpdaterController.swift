import Sparkle
import SwiftUI

/// Wraps Sparkle's `SPUStandardUpdaterController` for use in SwiftUI.
///
/// Instantiated once in `AppDelegate` and injected as an `@EnvironmentObject` so
/// `SettingsView` can bind its "Check for Updates" button to `canCheckForUpdates`.
/// The updater starts automatically on init and checks for updates on launch.
@MainActor
final class UpdaterController: ObservableObject {

    private let sparkle: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the UI can disable the button
    /// while a check is already in flight.
    @Published private(set) var canCheckForUpdates = false

    init() {
        sparkle = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // KVO-observe the ObjC property so changes propagate to SwiftUI.
        observation = sparkle.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Triggers a user-initiated update check (shows Sparkle's standard UI).
    func checkForUpdates() {
        sparkle.checkForUpdates(nil)
    }
}
