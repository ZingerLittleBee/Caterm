import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class AccountSwitchInitialSyncGraceTests: XCTestCase {
    func test_accountSwitch_initialSyncChangeGivesGrace_thenForceApplies() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("asg-\(UUID().uuidString).plist")
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev"
        let store = SettingsStore(settings: local, path: tmp)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "asg-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        tokenStore.persist(TestToken("user-X"))
        let session = AlwaysSignedInSession()
        // Use a class-based holder so the closure can mutate identity post-boot.
        final class Holder { var id = "user-X" }
        let holder = Holder()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken(holder.id) }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(60)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()

        // Flip identity, plant cloud Y data
        holder.id = "user-Y"
        var cloudY = CatermSettings()
        cloudY.global.fontSize = 88
        cloudY.revision = "y-rev"
        cloudY.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloudY), forKey: SettingsSyncStore.kvsKey)

        // .initialSyncChange — barrier extends synchronously, then grace, then classifyAndApply.
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(sync.testPushSuspended, "barrier active during grace")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.settings.global.fontSize, 88, "force-applied after grace")
        guard case .token(let stored) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(stored.isEqual(TestToken("user-Y")), "token advanced to Y")
    }
}
