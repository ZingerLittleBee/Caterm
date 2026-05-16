import Foundation
import SettingsStore

public enum IsDefaultSeedUnedited {
	/// True iff `settings` is identical to a known historical default seed
	/// AND has no user-driven edits AND uses no migrations beyond the
	/// caller-supplied set of known-at-this-app-version migration tokens.
	/// Composite: any single failed clause flips the result to false.
	public static func evaluate(
		_ settings: CatermSettings,
		knownMigrations: Set<String>
	) -> Bool {
		guard settings.seededByDefault else { return false }
		guard settings.firstUserEditedAt == nil else { return false }
		guard KnownSeedTable.versions.contains(settings.seedVersion) else { return false }
		guard KnownSeedTable.hashes.contains(settings.canonicalSeedHash) else { return false }
		guard let entry = KnownSeedTable.entry(forVersion: settings.seedVersion),
			entry.snapshot == settings.global else { return false }
		guard settings.hostOverrides.isEmpty else { return false }
		guard settings.migrationsCompleted.isSubset(of: knownMigrations) else { return false }
		return true
	}
}
