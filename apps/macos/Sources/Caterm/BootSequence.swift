import ConfigStore
import Foundation
import SettingsStore

/// One-shot startup sequence that loads settings, runs the legacy → plist
/// migration, persists any settings the migration produced, renders the
/// managed snapshot, and regenerates the per-host theme patches.
///
/// Wired into `AppDelegate.applicationDidFinishLaunching` by a later UI task
/// (Task 25 or whatever first needs the SettingsStore at app level). Phase 5
/// deliberately keeps this standalone so it can be exercised by unit tests
/// without having to construct a full AppDelegate.
@MainActor
public enum BootSequence {
	@discardableResult
	public static func run(
		settingsPlistURL: URL,
		userConfigURL: URL,
		managedSnapshotURL: URL,
		perHostDirectory: URL
	) throws -> SettingsStore {
		// 1. Load (or seed) settings.plist
		let store = try SettingsStore.load(from: settingsPlistURL)
		var settings = store.settings

		// 2. Migration (one-shot, gated by token)
		_ = try SettingsMigrationStep.runIfNeeded(
			userConfigPath: userConfigURL,
			settings: &settings
		)

		// 3. Persist any settings the migration produced
		if settings != store.settings {
			try store.save(settings)
		}

		// 4. Render managed snapshot
		try ConfigStore.renderManagedSnapshot(from: settings.global, to: managedSnapshotURL)

		// 5. Regenerate per-host patches from plist
		try ConfigStore.regeneratePerHostPatches(from: settings, in: perHostDirectory)

		return store
	}
}
