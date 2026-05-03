import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class KVSPullDispatchTests: XCTestCase {
    private func setup() async throws -> (SettingsSyncStore, SettingsStore, FakeKVS) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        store.debounceInterval = .milliseconds(0)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "pull-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session,
            tokenStore: tokenStore,
            currentTokenProvider: { TestToken("A") }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()
        return (sync, store, kvs)
    }

    func test_serverChange_appliesCloud() async throws {
        let (sync, store, kvs) = try await setup()
        var cloud = CatermSettings()
        cloud.global.fontSize = 42
        cloud.revision = "cloud-rev"
        cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreServerChange)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.settings.global.fontSize, 42)
        XCTAssertEqual(store.settings.revision, "cloud-rev")
    }

    func test_initialSyncChange_extendsBarrier_thenApplies() async throws {
        let (sync, store, kvs) = try await setup()
        sync.testInitialSyncGrace = .milliseconds(50)
        var cloud = CatermSettings()
        cloud.global.fontSize = 77
        cloud.revision = "after-grace"
        cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        XCTAssertTrue(sync.testPushSuspended)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.settings.global.fontSize, 77)
    }

    func test_quotaChange_doesNotApplyOrChangeSuspension() async throws {
        let (sync, store, _) = try await setup()
        let originalSize = store.settings.global.fontSize
        let originalSuspended = sync.testPushSuspended
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.settings.global.fontSize, originalSize)
        XCTAssertEqual(sync.testPushSuspended, originalSuspended)
    }

    func test_accountChange_reclassifies_firstObservation_pushesViaBootstrap() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-\(UUID().uuidString).plist")
        var local = CatermSettings()
        local.global.fontSize = 19
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "fresh"
        let store = SettingsStore(settings: local, path: tmp)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "ac-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken("first") }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreAccountChange)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            ".accountChange routes via classifier; identitySame + cloud nil → push")
    }
}
