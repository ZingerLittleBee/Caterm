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

	private func cloud(revision: String, version: Int = 2) -> CloudReadResult {
		var c = SyncableSettings(from: realEdits(revision: revision))
		c.version = version
		return .decoded(c)
	}

	private struct DummyError: Error {}

	private let bootStartedAt = Date(timeIntervalSince1970: 100_000_000)

	func test_branch1_cloudAbsent_localSeed_returnsNoOp() {
		let d = BootstrapDecider.decide(
			local: freshSeed(), cloud: .absent,
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .noOp)
		XCTAssertEqual(d.finalState, .active)
		XCTAssertTrue(d.acceptIdentity)
	}

	func test_branch2_cloudAbsent_localReal_returnsPushLocal() {
		let d = BootstrapDecider.decide(
			local: realEdits(), cloud: .absent,
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .pushLocal)
		XCTAssertEqual(d.finalState, .active)
		XCTAssertTrue(d.acceptIdentity)
	}

	func test_branch3_cloudReal_localSeed_returnsApplyCloud() {
		let d = BootstrapDecider.decide(
			local: freshSeed(), cloud: cloud(revision: "cloud-rev"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action.tag, "applyCloud")
		XCTAssertEqual(d.finalState, .active)
		XCTAssertTrue(d.acceptIdentity)
	}

	func test_branch4_cloudReal_localReal_cloudNewer_returnsApplyCloud() {
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "a"), cloud: cloud(revision: "z"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action.tag, "applyCloud")
		XCTAssertEqual(d.finalState, .active)
	}

	func test_branch5_cloudReal_localReal_localNewer_returnsPushLocal() {
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "z"), cloud: cloud(revision: "a"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .pushLocal)
		XCTAssertEqual(d.finalState, .active)
	}

	func test_branch6_cloudReal_localReal_revisionEqual_returnsNoOp() {
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "same"), cloud: cloud(revision: "same"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .noOp)
	}

	func test_branch7_cloudSchemaNewer_returnsRejectMerge_quarantined() {
		let d = BootstrapDecider.decide(
			local: realEdits(), cloud: cloud(revision: "z", version: 3),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .rejectMerge(reason: .schemaNewerThanLocal))
		XCTAssertEqual(d.finalState, .quarantined,
			"schema-newer must quarantine — pushing local would clobber the v3 cloud")
		XCTAssertTrue(d.acceptIdentity, "schema-newer in same identity still accepts identity")
	}

	func test_branch8_clockSkewSanity_localFirstEditAfterBoot_prefersLocal() {
		let after = bootStartedAt.addingTimeInterval(60)
		let d = BootstrapDecider.decide(
			local: realEdits(revision: "a", firstEdit: after),
			cloud: cloud(revision: "z"),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .pushLocal)
	}

	func test_branch9_cloudUnreadable_returnsRejectMerge_quarantined() {
		let d = BootstrapDecider.decide(
			local: realEdits(), cloud: .unreadable(DummyError()),
			bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
		)
		XCTAssertEqual(d.action, .rejectMerge(reason: .unreadableCloud))
		XCTAssertEqual(d.finalState, .quarantined,
			"undecodable cloud must quarantine — pushing local would overwrite a blob we can't read")
		XCTAssertTrue(d.acceptIdentity)
	}
}
