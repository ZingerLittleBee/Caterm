import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class IsDefaultSeedUneditedTests: XCTestCase {
	private func freshSeed() -> CatermSettings {
		var s = CatermSettings()
		s.global = CatermSettings.defaultsSeed
		s.seededByDefault = true
		s.firstUserEditedAt = nil
		s.seedVersion = 1
		s.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
		s.hostOverrides = [:]
		s.migrationsCompleted = []
		return s
	}

	func test_freshSeed_returnsTrue() {
		XCTAssertTrue(IsDefaultSeedUnedited.evaluate(
			freshSeed(),
			knownMigrations: ["settings-gui-v1"]
		))
	}

	func test_seededByDefaultFalse_returnsFalse() {
		var s = freshSeed()
		s.seededByDefault = false
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
	}

	func test_firstUserEditedAtSet_returnsFalse() {
		var s = freshSeed()
		s.firstUserEditedAt = Date()
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
	}

	func test_unknownSeedVersion_returnsFalse() {
		var s = freshSeed()
		s.seedVersion = 999
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
	}

	func test_unknownCanonicalHash_returnsFalse() {
		var s = freshSeed()
		s.canonicalSeedHash = "not-in-table"
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
	}

	func test_globalDoesNotMatchSeedSnapshot_returnsFalse() {
		var s = freshSeed()
		s.global.fontSize = 99
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
	}

	func test_hostOverridesNotEmpty_returnsFalse() {
		var s = freshSeed()
		s.hostOverrides = [HostId("h"): PartialSettings(fontSize: 14)]
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
	}

	func test_migrationsCompletedHasUnknownToken_returnsFalse() {
		var s = freshSeed()
		s.migrationsCompleted = ["unknown-future-migration"]
		XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: ["settings-gui-v1"]))
	}
}
