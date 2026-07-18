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
}

private final class CountingKVS: KVSProtocol {
	private var storage: [String: Data] = [:]
	private(set) var setCallCount = 0

	func data(forKey key: String) -> Data? { storage[key] }

	func set(_ data: Data, forKey key: String) {
		setCallCount += 1
		storage[key] = data
	}

	func removeObject(forKey key: String) {
		storage.removeValue(forKey: key)
	}

	func synchronize() -> Bool { true }

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
