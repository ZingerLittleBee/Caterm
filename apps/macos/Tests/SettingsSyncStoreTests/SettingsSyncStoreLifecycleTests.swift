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
		let (store, kvs, tokenStore, _) = try makeStore()
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") }
		)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.startSync()
		XCTAssertEqual(sync.startSyncCallCount, 2)
		XCTAssertEqual(sync.observersRegisteredCount, 1)
	}

	func test_signedOutCold_startSync_doesNotRegisterSyncObservers() async throws {
		let (store, kvs, tokenStore, _) = try makeStore()
		let session = AlwaysSignedOutSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { nil }
		)
		sync.installLifecycleObservers()
		await sync.startSync()
		XCTAssertEqual(sync.observersRegisteredCount, 0)
	}
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
