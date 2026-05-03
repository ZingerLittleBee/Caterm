import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class BootstrapDeciderTests: XCTestCase {
	private let knownMigrations: Set<String> = ["settings-gui-v1"]

	private func freshSeed() -> CatermSettings {
		var s = CatermSettings()
		s.global = CatermSettings.defaultsSeed
		s.seededByDefault = true
		s.seedVersion = 1
		s.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
		s.revision = "local-rev"
		return s
	}

	private func realEdits(revision: String = "local-rev",
						  firstEdit: Date = Date(timeIntervalSince1970: 1)) -> CatermSettings {
		var s = freshSeed()
		s.global.fontSize = 99
		s.seededByDefault = false
		s.firstUserEditedAt = firstEdit
		s.canonicalSeedHash = ""
		s.revision = revision
		return s
	}

	private func cloud(revision: String, version: Int = 2) -> SyncableSettings {
		var c = SyncableSettings(from: realEdits(revision: revision))
		c.version = version
		return c
	}

	private let bootStartedAt = Date(timeIntervalSince1970: 100_000_000)

	func test_branch1_cloudNil_localSeed_returnsNoOp() {
		let d = BootstrapDecider.decide(
			local: freshSeed(), cloud: nil,
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .noOp)
		XCTAssertFalse(d.finalSuspensionState)
		XCTAssertTrue(d.acceptIdentity)
	}

	func test_branch2_cloudNil_localReal_returnsPushLocal() {
		let d = BootstrapDecider.decide(
			local: realEdits(), cloud: nil,
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .pushLocal)
		XCTAssertTrue(d.acceptIdentity)
	}

	func test_branch3_cloudReal_localSeed_returnsApplyCloud() {
		let d = BootstrapDecider.decide(
			local: freshSeed(), cloud: cloud(revision: "cloud-rev"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action.tag, "applyCloud")
		XCTAssertTrue(d.acceptIdentity)
	}

	func test_branch4_cloudReal_localReal_cloudNewer_returnsApplyCloud() {
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "a"), cloud: cloud(revision: "z"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action.tag, "applyCloud")
	}

	func test_branch5_cloudReal_localReal_localNewer_returnsPushLocal() {
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "z"), cloud: cloud(revision: "a"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .pushLocal)
	}

	func test_branch6_cloudReal_localReal_revisionEqual_returnsNoOp() {
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "same"), cloud: cloud(revision: "same"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .noOp)
	}

	func test_branch7_cloudSchemaNewer_returnsRejectMerge() {
		let d = BootstrapDecider.decide(
			local: realEdits(), cloud: cloud(revision: "z", version: 3),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .rejectMerge(reason: .schemaNewerThanLocal))
		XCTAssertTrue(d.acceptIdentity, "schema-newer in same identity still accepts identity")
		XCTAssertFalse(d.finalSuspensionState)
	}

	func test_branch8_clockSkewSanity_localFirstEditAfterBoot_prefersLocal() {
		// local revision lower (cloud appears newer), but local.firstUserEditedAt
		// is after bootStartedAt — clock has been rewound; trust local.
		let after = bootStartedAt.addingTimeInterval(60)
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "a", firstEdit: after),
			cloud: cloud(revision: "z"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .pushLocal)
	}
}
