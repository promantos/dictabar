import Foundation
import Sparkle

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var lastStatus = "Ready"
    @Published private(set) var isChecking = false

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    func configure(automaticallyChecks: Bool) {
        controller.updater.automaticallyChecksForUpdates = automaticallyChecks
    }

    func check(includePrereleases _: Bool, openWhenAvailable _: Bool = true) async {
        guard controller.updater.canCheckForUpdates else {
            lastStatus = "Update check is already running."
            return
        }
        isChecking = true
        controller.checkForUpdates(nil)
        lastStatus = "Sparkle is checking for updates."
        isChecking = false
    }
}
