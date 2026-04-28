import Combine
import Foundation

/// User-configurable sync preferences, persisted to UserDefaults.
///
/// Single source of truth for the "Background sync" toggle in
/// `SyncSettingsView`. Owned by `CatermApp` as a `@StateObject` and
/// injected into `HostSyncStore` so the store can react to toggle
/// changes via `$periodicSyncEnabled`.
@MainActor
public final class SyncPreferences: ObservableObject {
    private static let periodicEnabledKey = "catermPeriodicSyncEnabled"
    private let defaults: UserDefaults

    @Published public var periodicSyncEnabled: Bool {
        didSet {
            defaults.set(periodicSyncEnabled, forKey: Self.periodicEnabledKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.periodicEnabledKey) as? Bool
        self.periodicSyncEnabled = stored ?? true
    }
}
