import XCTest
import CredentialSync
import CredentialSyncStore
import CredentialSyncTypes

@MainActor
final class CredentialSyncCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var prefsStore: CredentialSyncPreferencesStore!
    private var masterKeyStore: KeychainSyncMasterKeyStore!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "test-coord-\(UUID().uuidString)")!
        prefsStore = CredentialSyncPreferencesStore(defaults: defaults)
        masterKeyStore = KeychainSyncMasterKeyStore(
            service: "test-\(UUID().uuidString)",
            synchronizable: false
        )
    }

    func test_toggleOn_freshDevice_generatesKey_setsEnabled_setsFullScan() async throws {
        let preExisting = await masterKeyStore.loadAny()
        XCTAssertNil(preExisting)

        let coord = CredentialSyncCoordinator(
            prefsStore: prefsStore,
            masterKeyStore: masterKeyStore,
            iCloudKeychainAvailable: { true }
        )
        try await coord.enable()

        XCTAssertEqual(prefsStore.prefs.state, .enabled)
        XCTAssertTrue(prefsStore.prefs.credentialsNeedFullScan)
        let loaded = await masterKeyStore.loadAny()
        XCTAssertNotNil(loaded)
    }

    func test_toggleOn_keyAlreadyInICloudKeychain_setsEnabled_setsFullScan() async throws {
        let staged = try await masterKeyStore.generate()

        let coord = CredentialSyncCoordinator(
            prefsStore: prefsStore,
            masterKeyStore: masterKeyStore,
            iCloudKeychainAvailable: { true }
        )
        try await coord.enable()

        XCTAssertEqual(prefsStore.prefs.state, .enabled)
        XCTAssertTrue(prefsStore.prefs.credentialsNeedFullScan)

        // The key in the store should still be the originally staged one — enable()
        // must not have generated a new one.
        let loaded = await masterKeyStore.loadAny()
        XCTAssertEqual(loaded?.keyID, staged.keyID)
    }

    func test_toggleOn_iCloudKeychainUnavailable_throwsAndStaysDisabled() async {
        XCTAssertEqual(prefsStore.prefs.state, .disabled)

        let coord = CredentialSyncCoordinator(
            prefsStore: prefsStore,
            masterKeyStore: masterKeyStore,
            iCloudKeychainAvailable: { false }
        )

        do {
            try await coord.enable()
            XCTFail("enable() should have thrown")
        } catch CredentialSyncCoordinator.CoordinatorError.iCloudKeychainUnavailable {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(prefsStore.prefs.state, .disabled)
        XCTAssertFalse(prefsStore.prefs.credentialsNeedFullScan)
        let loaded = await masterKeyStore.loadAny()
        XCTAssertNil(loaded)
    }

    func test_toggleOff_setsDisabled_doesNotChangeFullScanFlag() {
        // Pre-set credentialsNeedFullScan=true to prove disable() preserves it.
        prefsStore.mutate {
            $0.state = .enabled
            $0.credentialsNeedFullScan = true
        }
        XCTAssertTrue(prefsStore.prefs.credentialsNeedFullScan)

        let coord = CredentialSyncCoordinator(
            prefsStore: prefsStore,
            masterKeyStore: masterKeyStore,
            iCloudKeychainAvailable: { true }
        )
        coord.disable()

        XCTAssertEqual(prefsStore.prefs.state, .disabled)
        XCTAssertTrue(prefsStore.prefs.credentialsNeedFullScan)
    }

    func test_masterKeyArrivesViaCheck_promotesWaitingForKeyToEnabled() async throws {
        prefsStore.mutate { $0.state = .waitingForKey(observedKeyID: nil) }

        let coord = CredentialSyncCoordinator(
            prefsStore: prefsStore,
            masterKeyStore: masterKeyStore,
            iCloudKeychainAvailable: { true }
        )

        // No key yet — should remain in waitingForKey.
        await coord.reconcileMasterKeyArrival()
        XCTAssertEqual(prefsStore.prefs.state, .waitingForKey(observedKeyID: nil))
        XCTAssertFalse(prefsStore.prefs.credentialsNeedFullScan)

        // Stage the key.
        _ = try await masterKeyStore.generate()

        await coord.reconcileMasterKeyArrival()
        XCTAssertEqual(prefsStore.prefs.state, .enabled)
        XCTAssertTrue(prefsStore.prefs.credentialsNeedFullScan)
    }
}
