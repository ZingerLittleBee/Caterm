import XCTest
import SettingsStore
@testable import SettingsSyncStore

/// FakeKVS that broadcasts external-change notifications to all observers.
/// Models the cross-Mac KVS rendezvous behavior in unit-test land.
@MainActor
final class SharedFakeKVS: @preconcurrency KVSProtocol {
	private var storage: [String: Data] = [:]
	public init() {}
	public func data(forKey key: String) -> Data? { storage[key] }
	public func set(_ data: Data, forKey key: String) {
		storage[key] = data
		broadcast(reason: NSUbiquitousKeyValueStoreServerChange)
	}
	public func removeObject(forKey key: String) {
		storage.removeValue(forKey: key)
		broadcast(reason: NSUbiquitousKeyValueStoreServerChange)
	}
	public func synchronize() -> Bool { true }
	public func dictionaryRepresentation() -> [String: Any] { storage }

	public func broadcast(reason: Int) {
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
		)
	}
}

@MainActor
final class TwoMacIntegrationTests: XCTestCase {
	private struct Mac {
		let store: SettingsStore
		let sync: SettingsSyncStore
		let kvs: SharedFakeKVS
		let tokenStore: IdentityTokenStore
	}

	private func makeMac(
		kvs: SharedFakeKVS,
		local: CatermSettings = CatermSettings(),
		currentToken: NSObject & NSCoding & NSCopying = TestToken("shared")
	) -> Mac {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("mac-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: local, path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "mac-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { currentToken }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(0)
		sync.installLifecycleObservers()
		return Mac(store: store, sync: sync, kvs: kvs, tokenStore: tokenStore)
	}

	private func realLocal(font: Int, revision: String) -> CatermSettings {
		var s = CatermSettings()
		s.global.fontSize = font
		s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		s.revision = revision
		return s
	}

	func test_scenario1_basicPropagate() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "a-1"))
		let B = makeMac(kvs: kvs, local: CatermSettings())
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		await B.sync.startSync(); await B.sync.testWaitForBootDecision()

		A.store.update { $0.global.fontSize = 22 }
		A.store.flushNow()
		try await Task.sleep(for: .milliseconds(80))

		XCTAssertEqual(B.store.settings.global.fontSize, 22)
	}

	func test_scenario2_concurrentBothEdit_revisionLWW() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "rev-A-old"))
		let B = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "rev-Z-newer"))
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		await B.sync.startSync(); await B.sync.testWaitForBootDecision()
		try await Task.sleep(for: .milliseconds(80))
		let blob = try SettingsBlobCodec.decode(kvs.data(forKey: SettingsSyncStore.kvsKey)!)
		XCTAssertEqual(blob.revision, "rev-Z-newer")
	}

	func test_scenario3_antiSeedPollution() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 21, revision: "a-real"))
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		var bSeed = CatermSettings.empty
		bSeed.global = CatermSettings.defaultsSeed
		bSeed.seededByDefault = true
		bSeed.seedVersion = 1
		bSeed.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
		bSeed.revision = "b-seed-newer-than-a"
		let B = makeMac(kvs: kvs, local: bSeed)
		await B.sync.startSync(); await B.sync.testWaitForBootDecision()
		XCTAssertEqual(B.store.settings.global.fontSize, 21,
			"B must apply A's real cloud data, not push its newer-revision default seed")
	}

	func test_scenario4_clockTamperedSeedStillYields() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 21, revision: "a-real"))
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		var bSeed = CatermSettings.empty
		bSeed.global = CatermSettings.defaultsSeed
		bSeed.seededByDefault = true
		bSeed.seedVersion = 1
		bSeed.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
		bSeed.revision = "z-future-clock-revision"
		let B = makeMac(kvs: kvs, local: bSeed)
		await B.sync.startSync(); await B.sync.testWaitForBootDecision()
		XCTAssertEqual(B.store.settings.global.fontSize, 21,
			"isDefaultSeedUnedited doesn't depend on time — still yields to cloud")
	}

	func test_scenario5_accountSwitch_yHasData_forceApply() async throws {
		let kvs = SharedFakeKVS()
		let xDefaults = UserDefaults(suiteName: "x-\(UUID().uuidString)")!
		let macXTokenStore = IdentityTokenStore(userDefaults: xDefaults)
		macXTokenStore.persist(TestToken("user-X"))

		var local = CatermSettings()
		local.global.fontSize = 99
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "z-newer-than-y"

		var cloudY = CatermSettings()
		cloudY.global.fontSize = 42
		cloudY.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloudY.revision = "y-old"
		kvs.set(try SettingsBlobCodec.encode(cloudY), forKey: SettingsSyncStore.kvsKey)

		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("as-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: local, path: tmp)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: macXTokenStore,
			currentTokenProvider: { TestToken("user-Y") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(0)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()

		XCTAssertEqual(store.settings.global.fontSize, 42, "force-apply Y, ignored revision LWW")
		XCTAssertEqual(store.settings.revision, "y-old")
		guard case .token(let t) = macXTokenStore.loadPersisted() else {
			XCTFail("token missing"); return
		}
		XCTAssertTrue(t.isEqual(TestToken("user-Y")), "advanced to Y after force-apply")
	}

	func test_scenario6_accountSwitch_yEmpty_firstEditPushes() async throws {
		let kvs = SharedFakeKVS()
		let defaults = UserDefaults(suiteName: "y-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		tokenStore.persist(TestToken("user-X"))
		var local = CatermSettings()
		local.global.fontSize = 17
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "x-r"
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("y-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: local, path: tmp)
		store.debounceInterval = .milliseconds(0)
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

		XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
		XCTAssertTrue(sync.testPushSuspended)
		if case .token(let t) = tokenStore.loadPersisted() {
			XCTAssertTrue(t.isEqual(TestToken("user-X")), "still X pre-edit")
		}

		store.update { $0.global.fontSize = 28 }
		store.flushNow()
		try await Task.sleep(for: .milliseconds(50))
		XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
		XCTAssertFalse(sync.testPushSuspended)
	}

	func test_scenario7_catermICloudAccountChanged_doesNotTriggerSwitch() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "a-1"),
						currentToken: TestToken("user-A"))
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		XCTAssertFalse(A.sync.testPushSuspended)
		NotificationCenter.default.post(name: .catermICloudAccountChanged, object: nil)
		try await Task.sleep(for: .milliseconds(50))
		XCTAssertFalse(A.sync.testPushSuspended,
			".catermICloudAccountChanged with same identity must NOT trigger any account-switch flow")
	}

	func test_scenario8_initialSyncWriteBarrier() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "a-1"))
		A.sync.testInitialSyncTimeout = .milliseconds(80)
		A.sync.testInitialSyncGrace = .milliseconds(0)
		let pushTask = Task { await A.sync.startSync() }
		try await Task.sleep(for: .milliseconds(10))
		A.store.update { $0.global.fontSize = 99 }
		A.store.flushNow()
		XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
			"observer-plane push must be suspended during boot wait")
		await pushTask.value
		await A.sync.testWaitForBootDecision()
		XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
	}

	func test_scenario8a_firstObservation_pushesViaControlPlane() async throws {
		let kvs = SharedFakeKVS()
		let A = makeMac(kvs: kvs, local: realLocal(font: 17, revision: "a-1"),
						currentToken: TestToken("first-time"))
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
			"firstObservation routes via BootstrapDecider; cloud nil + local real → pushLocal")
		if case .token(let t) = A.tokenStore.loadPersisted() {
			XCTAssertTrue(t.isEqual(TestToken("first-time")),
				"firstObservation accepts identity → token persisted")
		} else {
			XCTFail("token not persisted")
		}
	}

	func test_scenario8b_archiveFailureSentinel_routesSafely() async throws {
		let kvs = SharedFakeKVS()
		let defaults = UserDefaults(suiteName: "af-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		tokenStore.persistSentinel()
		var local = CatermSettings()
		local.global.fontSize = 17
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "x-r"
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("af-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: local, path: tmp)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("any") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(0)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()
		XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
			"unknownPrevious + Y empty → suspendUntilFirstEdit; do NOT push")
		XCTAssertEqual(tokenStore.loadPersisted(), .archiveFailed,
			"sentinel preserved; do not advance")
	}

	func test_scenario9_schemaVersionReject() async throws {
		let kvs = SharedFakeKVS()
		var future = CatermSettings()
		future.version = 3
		future.global.fontSize = 88
		future.revision = "future"
		future.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		kvs.set(try SettingsBlobCodec.encode(future), forKey: SettingsSyncStore.kvsKey)
		let A = makeMac(kvs: kvs, local: realLocal(font: 17, revision: "a-r"))
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		XCTAssertEqual(A.store.settings.global.fontSize, 17,
			"v2 client rejects v3 blob; local untouched")
	}

	func test_scenario10_migrationsCompletedDoesNotSync() async throws {
		let kvs = SharedFakeKVS()
		var aLocal = realLocal(font: 17, revision: "a-r")
		aLocal.migrationsCompleted = ["settings-gui-v1"]
		let A = makeMac(kvs: kvs, local: aLocal)
		let B = makeMac(kvs: kvs, local: CatermSettings())
		await A.sync.startSync(); await A.sync.testWaitForBootDecision()
		await B.sync.startSync(); await B.sync.testWaitForBootDecision()
		try await Task.sleep(for: .milliseconds(80))
		XCTAssertFalse(B.store.settings.migrationsCompleted.contains("settings-gui-v1"),
			"migrationsCompleted is local-only and must NOT propagate via sync")
	}
}
