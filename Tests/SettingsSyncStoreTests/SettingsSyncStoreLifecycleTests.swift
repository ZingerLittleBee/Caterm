import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class SettingsSyncStoreLifecycleTests: XCTestCase {
	private func makeStore() throws -> (SettingsStore, FakeKVS, IdentityTokenStore, UserDefaults) {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("ss-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: CatermSettings(), path: tmp)
		let kvs = FakeKVS()
		let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		return (store, kvs, tokenStore, defaults)
	}

	func test_init_doesNotRegisterAnyObservers() throws {
		let (store, kvs, tokenStore, _) = try makeStore()
		let session = AlwaysSignedInSession()
		let _ = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { nil }
		)
		XCTAssertFalse(session.refreshCalled)
	}

	func test_startSync_isIdempotent() async throws {
		let (store, _, tokenStore, _) = try makeStore()
		store.debounceInterval = .zero
		let kvs = CountingKVS()
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.startSync()
		let baselineSetCount = kvs.setCallCount

		store.update { $0.global.fontSize = 19 }
		store.flushNow()
		try await Task.sleep(for: .milliseconds(30))

		XCTAssertEqual(kvs.setCallCount, baselineSetCount + 1)
	}

	func test_signedOutCold_startSync_doesNotRegisterSyncObservers() async throws {
		let (store, kvs, tokenStore, _) = try makeStore()
		let session = AlwaysSignedOutSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { nil },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)
		sync.installLifecycleObservers()
		await sync.startSync()

		var cloud = CatermSettings()
		cloud.global.fontSize = 42
		cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloud.revision = "cloud"
		kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
		postKVSExternalChange(reason: NSUbiquitousKeyValueStoreServerChange)
		try await Task.sleep(for: .milliseconds(30))

		XCTAssertNotEqual(store.settings.global.fontSize, 42)
	}

	func test_synchronizeNow_requestsKVSAndAppliesNewerCloudSettings() async throws {
		let (store, _, tokenStore, _) = try makeStore()
		store.debounceInterval = .zero
		let kvs = CountingKVS()
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: session,
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)
		await sync.startSync()
		let baselineSynchronizeCount = kvs.synchronizeCallCount

		var cloud = store.settings
		cloud.global.fontSize = 42
		cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloud.revision = "cloud-manual-refresh"
		kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)

		await sync.synchronizeNow()

		XCTAssertEqual(kvs.synchronizeCallCount, baselineSynchronizeCount + 1)
		XCTAssertEqual(store.settings.global.fontSize, 42)
	}

	func test_synchronizeNow_reportsLocalKVSPersistenceFailure() async throws {
		let (store, _, tokenStore, _) = try makeStore()
		let kvs = CountingKVS()
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: AlwaysSignedInSession(),
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)
		await sync.startSync()
		kvs.synchronizeResult = false

		let result = await sync.synchronizeNow()

		guard case .failed = result else {
			return XCTFail("Expected KVS persistence failure to reach the caller")
		}
	}

	func test_startSyncAndReport_surfacesQuarantinedCloudSettings() async throws {
		let (store, _, tokenStore, _) = try makeStore()
		let kvs = CountingKVS()
		kvs.set(Data("not a settings blob".utf8), forKey: SettingsSyncStore.kvsKey)
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: AlwaysSignedInSession(),
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)

		let result = await sync.startSyncAndReport()

		guard case .failed = result else {
			return XCTFail("Expected quarantined settings to reach the caller")
		}
		XCTAssertEqual(sync.syncState, .quarantined)
	}

	func test_startSyncAndReport_reportsInitialKVSPersistenceFailure() async throws {
		let (store, _, tokenStore, _) = try makeStore()
		let kvs = CountingKVS()
		kvs.synchronizeResult = false
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: AlwaysSignedInSession(),
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)

		let result = await sync.startSyncAndReport()

		guard case .failed = result else {
			return XCTFail("Expected initial KVS persistence failure to reach the caller")
		}
		guard case .failed = sync.lastExecutionResult else {
			return XCTFail("Expected initial KVS failure to remain observable")
		}
	}

	func test_externalPullPublishesQuarantineAndRecovery() async throws {
		let (store, kvs, tokenStore, _) = try makeStore()
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: AlwaysSignedInSession(),
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .zero,
				initialSyncGrace: .zero
			)
		)
		await sync.startSync()

		var future = store.settings
		future.version += 1
		future.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		future.revision = "future"
		kvs.set(try SettingsBlobCodec.encode(future), forKey: SettingsSyncStore.kvsKey)
		postKVSExternalChange(reason: NSUbiquitousKeyValueStoreServerChange)
		try await Task.sleep(for: .milliseconds(30))

		guard case .failed = sync.lastExecutionResult else {
			return XCTFail("Expected external incompatible settings to publish failure")
		}

		var compatible = store.settings
		compatible.firstUserEditedAt = Date(timeIntervalSince1970: 2)
		compatible.revision = "recovered"
		kvs.set(try SettingsBlobCodec.encode(compatible), forKey: SettingsSyncStore.kvsKey)
		postKVSExternalChange(reason: NSUbiquitousKeyValueStoreServerChange)
		try await Task.sleep(for: .milliseconds(30))

		guard case .upToDate = sync.lastExecutionResult else {
			return XCTFail("Expected a compatible external pull to publish recovery")
		}
	}
}

private final class CountingKVS: KVSProtocol {
	private var storage: [String: Data] = [:]
	private(set) var setCallCount = 0
	private(set) var synchronizeCallCount = 0
	var synchronizeResult = true

	func data(forKey key: String) -> Data? { storage[key] }

	func set(_ data: Data, forKey key: String) {
		setCallCount += 1
		storage[key] = data
	}

	func removeObject(forKey key: String) {
		storage.removeValue(forKey: key)
	}

	func synchronize() -> Bool {
		synchronizeCallCount += 1
		return synchronizeResult
	}

	func dictionaryRepresentation() -> [String: Any] { storage }
}

// MARK: - Test doubles
final class AlwaysSignedInSession: AccountSessionProviding {
	var isSignedIn: Bool = true
	var refreshCalled = false
	func refresh() async { refreshCalled = true }
}

final class AlwaysSignedOutSession: AccountSessionProviding {
	var isSignedIn: Bool = false
	func refresh() async {}
}

final class TestToken: NSObject, NSCoding, NSCopying {
	let id: String
	init(_ id: String) { self.id = id }
	required init?(coder: NSCoder) { self.id = coder.decodeObject(forKey: "i") as? String ?? "" }
	func encode(with coder: NSCoder) { coder.encode(id, forKey: "i") }
	func copy(with zone: NSZone? = nil) -> Any { TestToken(id) }
	override func isEqual(_ object: Any?) -> Bool { (object as? TestToken)?.id == id }
}
