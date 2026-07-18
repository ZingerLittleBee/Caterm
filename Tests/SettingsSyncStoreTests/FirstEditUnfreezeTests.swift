import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class FirstEditUnfreezeTests: XCTestCase {
    func test_firstEditUnderSuspend_unfreezesPushesAndPersistsToken() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uf-\(UUID().uuidString).plist")
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev"
        let store = SettingsStore(settings: local, path: tmp)
        store.debounceInterval = .milliseconds(0)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "uf-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        tokenStore.persist(TestToken("user-X"))
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken("user-Y") },
            configuration: SettingsSyncConfiguration(
                bootTimeout: .milliseconds(10),
                initialSyncGrace: .zero
            )
        )
        sync.installLifecycleObservers()
        await sync.startSync()

        XCTAssertTrue(sync.isPushSuspended)
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
        guard case .token(let stillX) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(stillX.isEqual(TestToken("user-X")), "token MUST still be X pre-edit")

        store.update { $0.global.fontSize = 25 }
        store.flushNow()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "first edit must push the blob")
        XCTAssertFalse(sync.isPushSuspended)
        guard case .token(let nowY) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(nowY.isEqual(TestToken("user-Y")),
            "token advances to Y after first edit + push")
    }
}
