import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class QuarantineAndApplyFailureTests: XCTestCase {
	private struct DummyError: Error {}

	private func realLocal(font: Int = 17, revision: String = "x-rev") -> CatermSettings {
		var s = CatermSettings()
		s.global.fontSize = font
		s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		s.revision = revision
		return s
	}

	// MARK: - Schema reject + user edit must NOT clobber cloud (fix #1)

	func test_schemaReject_subsequentUserEdit_doesNotPushOverFutureCloud() async throws {
		// Stage v3 cloud (newer schema than local v2). Boot must quarantine.
		let kvs = FakeKVS()
		var futureCloud = CatermSettings()
		futureCloud.version = 3
		futureCloud.global.fontSize = 88
		futureCloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		futureCloud.revision = "future-rev"
		let futureBlob = try SettingsBlobCodec.encode(futureCloud)
		kvs.set(futureBlob, forKey: SettingsSyncStore.kvsKey)

		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("q-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "x-rev"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "q-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(0)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()

		XCTAssertEqual(sync.syncState, .quarantined,
			"v3 cloud against v2 local must quarantine")
		// User edits while quarantined.
		store.update { $0.global.fontSize = 7 }
		store.flushNow()
		try await Task.sleep(for: .milliseconds(50))

		// Cloud blob MUST still be the v3 one — user edit must not push.
		let kvsBlob = try XCTUnwrap(kvs.data(forKey: SettingsSyncStore.kvsKey),
			"cloud blob disappeared")
		XCTAssertEqual(kvsBlob, futureBlob,
			"user edit while quarantined must NOT push v2 over v3 cloud")
		XCTAssertEqual(sync.syncState, .quarantined,
			"quarantine sticks across user edits — only the next pull can clear it")
	}

	// MARK: - Cloud unreadable cross-identity (fix #2)

	func test_unreadableCloud_crossIdentity_doesNotPersistTokenOrPushOnEdit() async throws {
		// Cross-identity boot with cloud Y present-but-unreadable.
		let kvs = FakeKVS()
		// Plant garbage that fails decode but is non-empty.
		let garbage = Data([0x00, 0xFF, 0x00, 0xFF])
		kvs.set(garbage, forKey: SettingsSyncStore.kvsKey)

		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("u-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "x-rev"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "u-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		tokenStore.persist(TestToken("user-X"))
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-Y") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(0)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()

		XCTAssertEqual(sync.syncState, .quarantined,
			"unreadable Y on a cross-identity boot must quarantine, not suspendUntilFirstEdit")
		// Token MUST still be X — we did NOT consume Y data, so we must not
		// claim Y identity has been accepted.
		guard case .token(let t) = tokenStore.loadPersisted() else {
			return XCTFail("token state lost")
		}
		XCTAssertTrue(t.isEqual(TestToken("user-X")),
			"unreadable Y must NOT advance the persisted token to Y")

		// User edits — must not push (quarantined).
		store.update { $0.global.fontSize = 9 }
		store.flushNow()
		try await Task.sleep(for: .milliseconds(50))

		XCTAssertEqual(kvs.data(forKey: SettingsSyncStore.kvsKey), garbage,
			"user edit while quarantined must NOT clobber the unreadable Y blob")
	}

	// MARK: - Apply failure must NOT persist token / clear suspension (fix #4)

	func test_applyCloudFailure_doesNotPersistTokenAndStaysSuspended() async throws {
		// Force replaceFromSync to throw by pointing the plist path at a file
		// inside an invalid parent that cannot be created.
		let unwritable = URL(fileURLWithPath: "/dev/null/no-way-this-exists/settings.plist")

		let kvs = FakeKVS()
		// Cloud Y is real and decodable — boot would normally force-apply it.
		var cloudY = CatermSettings()
		cloudY.version = 2
		cloudY.global.fontSize = 42
		cloudY.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloudY.revision = "y-rev"
		kvs.set(try SettingsBlobCodec.encode(cloudY), forKey: SettingsSyncStore.kvsKey)

		let store = SettingsStore(settings: realLocal(font: 17, revision: "x-rev"),
								  path: unwritable)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "af-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		tokenStore.persist(TestToken("user-X"))
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-Y") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(0)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()

		// The decision was forceApply(Y) + acceptIdentity=true + finalState=active.
		// But replaceFromSync threw, so:
		// - syncState must NOT have advanced to .active (rolled back)
		// - tokenStore must NOT have been advanced to Y
		XCTAssertNotEqual(sync.syncState, .active,
			"apply failure must NOT clear suspension; the decision was rolled back")
		guard case .token(let t) = tokenStore.loadPersisted() else {
			return XCTFail("token state lost")
		}
		XCTAssertTrue(t.isEqual(TestToken("user-X")),
			"apply failure must NOT persist the new identity token")
		// And local store still holds X data.
		XCTAssertEqual(store.settings.global.fontSize, 17)
	}
}
