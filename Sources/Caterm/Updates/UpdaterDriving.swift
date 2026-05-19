import Foundation

/// The subset of `SPUUpdater` the app drives. Abstracted so the menu/UI
/// logic is unit-testable without booting a real Sparkle updater (which
/// reads the bundle Info.plist and warns when SUFeedURL/SUPublicEDKey
/// are absent in a test bundle).
@MainActor
protocol UpdaterDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}
