import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class KVSPullDispatchTests: XCTestCase {
    private func setup(
        initialSyncGrace: Duration = .zero
    ) async throws -> (SettingsSyncStore, SettingsStore, FakeKVS) {
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
            currentTokenProvider: { TestToken("A") },
            configuration: SettingsSyncConfiguration(
                bootTimeout: .milliseconds(10),
                initialSyncGrace: initialSyncGrace
            )
        )
        sync.installLifecycleObservers()
        await sync.startSync()
        return (sync, store, kvs)
    }

    func test_serverChange_appliesCloud() async throws {
        let (sync, store, kvs) = try await setup()
        var cloud = CatermSettings()
        cloud.global.fontSize = 42
        cloud.revision = "cloud-rev"
        cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
        postKVSExternalChange(reason: NSUbiquitousKeyValueStoreServerChange)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.settings.global.fontSize, 42)
        XCTAssertEqual(store.settings.revision, "cloud-rev")
        withExtendedLifetime(sync) {}
    }

    func test_initialSyncChange_extendsBarrier_thenApplies() async throws {
        let (sync, store, kvs) = try await setup(initialSyncGrace: .milliseconds(50))
        var cloud = CatermSettings()
        cloud.global.fontSize = 77
        cloud.revision = "after-grace"
        cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
        postKVSExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        XCTAssertTrue(sync.isPushSuspended)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.settings.global.fontSize, 77)
    }

    func test_quotaChange_doesNotApplyOrChangeSuspension() async throws {
        let (sync, store, _) = try await setup()
        let originalSize = store.settings.global.fontSize
        let originalSuspended = sync.isPushSuspended
        postKVSExternalChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.settings.global.fontSize, originalSize)
        XCTAssertEqual(sync.isPushSuspended, originalSuspended)
    }

    func test_editDuringInitialSyncGrace_doesNotBypassClassifier() async throws {
        // Regression for the C1 race: while .initialSyncChange grace is in flight,
        // a user edit must NOT take the suspendUntilFirstEdit unfreeze path. The
        // unfreeze path persists the current token and pushes unconditionally,
        // which would (1) leak the previous identity's data into the new identity's
        // KVS during a hidden mid-flight identity switch, and (2) bypass
        // classifyAndApply, which is the only place AccountSwitchHandler / schema
        // checks run on the pulled blob.
        let (sync, store, kvs) = try await setup(initialSyncGrace: .milliseconds(80))
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)

        postKVSExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        XCTAssertTrue(sync.isPushSuspended, "barrier active synchronously")
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "preconditions: KVS empty before edit")

        try await Task.sleep(for: .milliseconds(20))
        store.update { $0.global.fontSize = 7 }
        store.flushNow()
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "user edit during grace MUST NOT push via the unfreeze branch")
        XCTAssertTrue(sync.isPushSuspended, "barrier still active until grace expires")

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "after grace, classifier handles the local push via the control plane")
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
            currentTokenProvider: { TestToken("first") },
            configuration: SettingsSyncConfiguration(
                bootTimeout: .milliseconds(10),
                initialSyncGrace: .zero
            )
        )
        sync.installLifecycleObservers()
        await sync.startSync()
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        postKVSExternalChange(reason: NSUbiquitousKeyValueStoreAccountChange)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            ".accountChange routes via classifier; identitySame + cloud nil → push")
    }
}
