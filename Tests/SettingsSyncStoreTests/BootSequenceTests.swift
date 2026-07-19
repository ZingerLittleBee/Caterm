import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class BootSequenceTests: XCTestCase {
	private func makeStore(
		local: CatermSettings = CatermSettings(),
		kvsBlob: Data? = nil,
		currentToken: (NSObject & NSCoding & NSCopying)? = nil,
		persistedToken: PersistedTokenLoad = .none,
		signedIn: Bool = true
	) throws -> (SettingsSyncStore, SettingsStore, FakeKVS, IdentityTokenStore) {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("boot-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: local, path: tmp)
		let kvs = FakeKVS()
		if let b = kvsBlob { kvs.set(b, forKey: SettingsSyncStore.kvsKey) }
		let defaults = UserDefaults(suiteName: "boot-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		switch persistedToken {
		case .none: break
		case .archiveFailed: tokenStore.persistSentinel()
		case .token(let t): tokenStore.persist(t)
		}
		let session: AccountSessionProviding = signedIn ? AlwaysSignedInSession() : AlwaysSignedOutSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session,
			tokenStore: tokenStore,
			currentTokenProvider: { currentToken },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .milliseconds(50),
				initialSyncGrace: .milliseconds(10)
			)
		)
		sync.installLifecycleObservers()
		return (sync, store, kvs, tokenStore)
	}

	private func encodedBlob(revision: String, fontSize: Int = 99) throws -> Data {
		var s = CatermSettings()
		s.global.fontSize = fontSize
		s.revision = revision
		s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		return try SettingsBlobCodec.encode(s)
	}

	func test_boot_firstObservation_emptyKVS_realLocal_pushesAndPersistsToken() async throws {
		var local = CatermSettings()
		local.global.fontSize = 17
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "local-r"
		let curr = TestToken("user-A")
		let (sync, _, kvs, tokenStore) = try makeStore(
			local: local, kvsBlob: nil, currentToken: curr, persistedToken: .none
		)
		await sync.startSync()
		let blob = kvs.data(forKey: SettingsSyncStore.kvsKey)
		XCTAssertNotNil(blob)
		guard case .token(let t) = tokenStore.loadPersisted() else {
			XCTFail("token not persisted"); return
		}
		XCTAssertTrue(t.isEqual(curr))
		XCTAssertFalse(sync.isPushSuspended)
	}

	func test_boot_identityChanged_yEmpty_doesNotPersistToken_staysSuspended() async throws {
		var local = CatermSettings()
		local.global.fontSize = 17
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "x-rev"
		let prevToken = TestToken("user-X")
		let currToken = TestToken("user-Y")
		let (sync, _, kvs, tokenStore) = try makeStore(
			local: local, kvsBlob: nil,
			currentToken: currToken, persistedToken: .token(prevToken)
		)
		await sync.startSync()
		XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
		guard case .token(let stored) = tokenStore.loadPersisted() else {
			XCTFail("token missing"); return
		}
		XCTAssertTrue(stored.isEqual(prevToken),
			"token must NOT advance until user accepts identity Y by editing")
		XCTAssertTrue(sync.isPushSuspended)
	}

	func test_boot_identityChanged_yHasData_forceApplies_persistsNewToken() async throws {
		let blob = try encodedBlob(revision: "y-rev", fontSize: 21)
		var local = CatermSettings()
		local.global.fontSize = 17
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "x-rev-newer-than-y"
		let prevToken = TestToken("user-X")
		let currToken = TestToken("user-Y")
		let (sync, store, _, tokenStore) = try makeStore(
			local: local, kvsBlob: blob,
			currentToken: currToken, persistedToken: .token(prevToken)
		)
		await sync.startSync()
		XCTAssertEqual(store.settings.global.fontSize, 21)
		XCTAssertEqual(store.settings.revision, "y-rev")
		guard case .token(let stored) = tokenStore.loadPersisted() else {
			XCTFail("token missing"); return
		}
		XCTAssertTrue(stored.isEqual(currToken))
		XCTAssertFalse(sync.isPushSuspended)
	}

	func test_boot_unknownPrevious_routesViaAccountSwitchHandler() async throws {
		var local = CatermSettings()
		local.global.fontSize = 17
		local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		local.revision = "x-rev"
		let curr = TestToken("user-A")
		let (sync, _, kvs, tokenStore) = try makeStore(
			local: local, kvsBlob: nil, currentToken: curr,
			persistedToken: .archiveFailed
		)
		await sync.startSync()
		XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
		XCTAssertEqual(tokenStore.loadPersisted(), .archiveFailed,
			"sentinel preserved; token not advanced under unknownPrevious + Y empty")
		XCTAssertTrue(sync.isPushSuspended)
	}
}
