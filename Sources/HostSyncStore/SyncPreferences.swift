import Combine
import Foundation

/// User-configurable sync preferences, persisted to UserDefaults.
///
/// Single source of truth for the "Background sync" toggle in
/// `SyncSettingsView`. Owned by `CatermApp` as a `@StateObject` and
/// injected into `HostSyncStore` so the store can react to toggle
/// changes via `$periodicSyncEnabled`.
///
/// v1.6 added `installTerminfoEnabled` — the naming-mismatch with the
/// type is acknowledged tech debt; rename to `Preferences` deferred to
/// v1.7 (see v1.6 spec §2 non-goals).
@MainActor
public final class SyncPreferences: ObservableObject {
    private static let periodicEnabledKey = "catermPeriodicSyncEnabled"
    public static let notifyOnFailureKey = "catermNotifyOnFailureEnabled"
    private static let installTerminfoEnabledKey = "catermInstallTerminfoEnabled"
    private static let autoUploadDefaultKeysEnabledKey = "catermAutoUploadDefaultKeysEnabled"
    private let defaults: UserDefaults

    @Published public var periodicSyncEnabled: Bool {
        didSet {
            defaults.set(periodicSyncEnabled, forKey: Self.periodicEnabledKey)
        }
    }

    @Published public var notifyOnFailureEnabled: Bool {
        didSet {
            defaults.set(notifyOnFailureEnabled, forKey: Self.notifyOnFailureKey)
        }
    }

    /// v1.6 — when true, every SSH session emits an inline wrapper that
    /// idempotently installs `xterm-ghostty` terminfo on the remote and
    /// sends `TERM=xterm-ghostty`. Default false (opt-in: we don't mutate
    /// remote filesystems without consent).
    @Published public var installTerminfoEnabled: Bool {
        didSet {
            defaults.set(installTerminfoEnabled, forKey: Self.installTerminfoEnabledKey)
        }
    }

    /// v1.7 — opt-in. When false (default), keys discovered by scanning the
    /// user's `~/.ssh` directory are NEVER uploaded to iCloud, even if one of
    /// them successfully authenticates. When true, a scanned default key that
    /// produced a successful connection may be promoted to a synced managed
    /// credential for that host. Keys that never produced a successful
    /// connection are never synced regardless of this setting.
    @Published public var autoUploadDefaultKeysEnabled: Bool {
        didSet {
            defaults.set(autoUploadDefaultKeysEnabled, forKey: Self.autoUploadDefaultKeysEnabledKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.periodicEnabledKey) as? Bool
        self.periodicSyncEnabled = stored ?? true
        let storedNotifyOnFailure = defaults.object(forKey: Self.notifyOnFailureKey) as? Bool
        self.notifyOnFailureEnabled = storedNotifyOnFailure ?? false
        // `bool(forKey:)` returns false when the key is absent — that IS the
        // default we want (opt-in), so no `?? false` fallback needed.
        self.installTerminfoEnabled = defaults.bool(forKey: Self.installTerminfoEnabledKey)
        // Absent key → false (opt-in: never auto-upload default keys without
        // explicit consent).
        self.autoUploadDefaultKeysEnabled = defaults.bool(forKey: Self.autoUploadDefaultKeysEnabledKey)
    }
}
