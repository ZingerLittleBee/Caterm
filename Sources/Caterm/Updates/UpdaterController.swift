import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater and exposes only what the menu needs.
/// Production path constructs `SPUStandardUpdaterController(startingUpdater:
/// true, ...)`, which begins background scheduled checks immediately
/// (cadence governed by Info.plist `SUEnableAutomaticChecks` /
/// `SUScheduledCheckInterval`). Tests inject a fake `UpdaterDriving`.
@MainActor
final class UpdaterController: ObservableObject {
    private let updater: any UpdaterDriving

    /// Test/explicit-injection initializer.
    init(updater: any UpdaterDriving) {
        self.updater = updater
    }

    /// Production initializer: boots the real Sparkle updater.
    convenience init() {
        self.init(updater: SparkleUpdaterAdapter())
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() { updater.checkForUpdates() }
}

/// Adapts `SPUStandardUpdaterController` to `UpdaterDriving`.
@MainActor
private final class SparkleUpdaterAdapter: UpdaterDriving {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
