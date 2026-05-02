import XCTest
@testable import CredentialSync

final class CredentialSyncPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test-\(UUID())")!
    }

    func test_default_isDisabled_noFlags() {
        let prefs = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(prefs.state, .disabled)
        XCTAssertFalse(prefs.credentialsNeedFullScan)
        XCTAssertNil(prefs.deleteCredentialsFromCloudInProgress)
        XCTAssertEqual(prefs.lastAppliedRevision, [:])
        XCTAssertEqual(prefs.corruptCredentials, [])
    }

    func test_save_thenLoad_roundTripsAllFields() {
        var prefs = CredentialSyncPreferences(defaults: defaults)
        let id = UUID()
        prefs.state = .enabled
        prefs.credentialsNeedFullScan = true
        prefs.lastAppliedRevision[id] = 5
        prefs.deleteCredentialsFromCloudInProgress = DeletionProgress(pendingLocalHostIds: [id])
        prefs.corruptCredentials.insert(CorruptCredentialKey(hostId: id, revision: 5))
        prefs.save()

        let reloaded = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.state, .enabled)
        XCTAssertTrue(reloaded.credentialsNeedFullScan)
        XCTAssertEqual(reloaded.lastAppliedRevision[id], 5)
        XCTAssertEqual(reloaded.deleteCredentialsFromCloudInProgress?.pendingLocalHostIds, [id])
        XCTAssertEqual(reloaded.corruptCredentials, [CorruptCredentialKey(hostId: id, revision: 5)])
    }

    func test_pausedByRemote_keepsTombstoneRev() {
        var prefs = CredentialSyncPreferences(defaults: defaults)
        prefs.state = .pausedByRemote(seenTombstoneRevision: 7)
        prefs.save()
        let reloaded = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.state, .pausedByRemote(seenTombstoneRevision: 7))
    }

    func test_waitingForKey_keepsObservedKeyID() {
        var prefs = CredentialSyncPreferences(defaults: defaults)
        prefs.state = .waitingForKey(observedKeyID: "key-abc")
        prefs.save()
        let reloaded = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.state, .waitingForKey(observedKeyID: "key-abc"))
    }
}
