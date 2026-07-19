import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class PushPlaneTests: XCTestCase {
    private func makeStore() async throws -> (SettingsSyncStore, SettingsStore, FakeKVS) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        store.debounceInterval = .milliseconds(0)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session,
            tokenStore: tokenStore,
            currentTokenProvider: { TestToken("A") },
            configuration: SettingsSyncConfiguration(
                bootTimeout: .milliseconds(10),
                initialSyncGrace: .zero
            )
        )
        sync.installLifecycleObservers()
        await sync.startSync()
        return (sync, store, kvs)
    }

    func test_userEdit_postBoot_isPushed() async throws {
        let (sync, store, kvs) = try await makeStore()
        XCTAssertFalse(sync.isPushSuspended)
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        store.update { $0.global.fontSize = 18 }
        store.flushNow()
        try await Task.sleep(for: .milliseconds(50))
        let blob = kvs.data(forKey: SettingsSyncStore.kvsKey)
        XCTAssertNotNil(blob, "user edit while not suspended must push")
    }

    func test_syncSourcedChange_isNotRePushed() async throws {
        let (_, store, kvs) = try await makeStore()
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        var fromCloud = CatermSettings()
        fromCloud.global.fontSize = 33
        fromCloud.revision = "from-cloud"
        try store.replaceFromSync(fromCloud)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "sync-sourced change must not loop back into a push")
    }

}
