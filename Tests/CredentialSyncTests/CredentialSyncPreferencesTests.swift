import XCTest
import CredentialSyncStore

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
        XCTAssertFalse(prefs.cloudCredentialsCleared)
        XCTAssertEqual(prefs.hostsWithCloudPayload, [])
        XCTAssertEqual(prefs.decryptAttemptCounts, [:])
    }

    func test_save_thenLoad_roundTripsAllFields() {
        var prefs = CredentialSyncPreferences(defaults: defaults)
        let id = UUID()
        let id2 = UUID()
        prefs.state = .enabled
        prefs.credentialsNeedFullScan = true
        prefs.lastAppliedRevision[id] = 5
        prefs.deleteCredentialsFromCloudInProgress = DeletionProgress(pendingLocalHostIds: [id])
        prefs.corruptCredentials.insert(CorruptCredentialKey(hostId: id, revision: 5))
        prefs.cloudCredentialsCleared = true
        prefs.hostsWithCloudPayload = [id, id2]
        prefs.decryptAttemptCounts[CorruptCredentialKey(hostId: id, revision: 5)] = 2
        prefs.decryptAttemptCounts[CorruptCredentialKey(hostId: id2, revision: 1)] = 1
        prefs.save()

        let reloaded = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.state, .enabled)
        XCTAssertTrue(reloaded.credentialsNeedFullScan)
        XCTAssertEqual(reloaded.lastAppliedRevision[id], 5)
        XCTAssertEqual(reloaded.deleteCredentialsFromCloudInProgress?.pendingLocalHostIds, [id])
        XCTAssertEqual(reloaded.corruptCredentials, [CorruptCredentialKey(hostId: id, revision: 5)])
        XCTAssertTrue(reloaded.cloudCredentialsCleared)
        XCTAssertEqual(reloaded.hostsWithCloudPayload, [id, id2])
        XCTAssertEqual(reloaded.decryptAttemptCounts[CorruptCredentialKey(hostId: id, revision: 5)], 2)
        XCTAssertEqual(reloaded.decryptAttemptCounts[CorruptCredentialKey(hostId: id2, revision: 1)], 1)
    }

    /// The 3-strike corrupt-credential bound must survive relaunch: the
    /// counter is persisted, so a permanently-undecryptable blob reaches
    /// the escape hatch instead of aborting the host-sync cycle on every
    /// cold start forever.
    func test_decryptAttemptCounter_survivesReload() {
        let id = UUID()
        let key = CorruptCredentialKey(hostId: id, revision: 9)
        var prefs = CredentialSyncPreferences(defaults: defaults)
        prefs.decryptAttemptCounts[key] = 1
        prefs.save()

        var reloaded = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.decryptAttemptCounts[key], 1,
                       "counter must persist across a simulated relaunch")
        reloaded.decryptAttemptCounts[key] = 2
        reloaded.save()

        let again = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(again.decryptAttemptCounts[key], 2)
    }

    /// Backwards-compat: a UserDefaults blob written by the pre-cloudCleared
    /// app version (no `cloudCredentialsCleared` / `hostsWithCloudPayload`
    /// keys) must decode with both fields defaulting to safe values. Without
    /// `decodeIfPresent` the upgrade path would throw and silently reset
    /// every field to defaults.
    func test_loadLegacyBlob_withoutNewKeys_defaultsToFalseAndEmptySet() throws {
        // Hand-craft a JSON payload that omits the new keys.
        let id = UUID()
        let json = """
        {
          "state": { "tag": "enabled" },
          "lastAppliedRevision": { "\(id.uuidString)": 3 },
          "credentialsNeedFullScan": false,
          "corruptCredentials": []
        }
        """
        defaults.set(json.data(using: .utf8)!, forKey: "catermCredentialSyncPreferences")

        let reloaded = CredentialSyncPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.state, .enabled)
        XCTAssertEqual(reloaded.lastAppliedRevision[id], 3)
        XCTAssertFalse(reloaded.cloudCredentialsCleared,
                       "missing cloudCredentialsCleared must decode as false")
        XCTAssertEqual(reloaded.hostsWithCloudPayload, [],
                       "missing hostsWithCloudPayload must decode as empty set")
        XCTAssertEqual(reloaded.decryptAttemptCounts, [:],
                       "missing decryptAttemptCounts must decode as empty dict")
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

    func test_identityBoundState_ignoresFreshReceivingSetup() {
        var prefs = CredentialSyncPreferences(defaults: defaults)
        prefs.state = .enabled
        prefs.credentialsNeedFullScan = true

        XCTAssertFalse(prefs.hasIdentityBoundState)
    }

    func test_identityBoundState_detectsAccountScopedProgress() {
        var prefs = CredentialSyncPreferences(defaults: defaults)
        prefs.state = .pausedByRemote(seenTombstoneRevision: 3)
        XCTAssertTrue(prefs.hasIdentityBoundState)

        prefs.state = .enabled
        prefs.lastAppliedRevision[UUID()] = 9
        XCTAssertTrue(prefs.hasIdentityBoundState)
    }
}
