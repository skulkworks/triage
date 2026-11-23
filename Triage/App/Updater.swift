import Sparkle

/// Sparkle updates from https://updates.skulkworks.dev/triage/appcast.xml (see Resources/Info.plist).
@Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    private(set) var canCheck = false
    private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // The Dev build shares the released app's feed, so left alone it would call the released
        // version an update and install it over the build products. Check for Updates still works.
        #if DEBUG
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
