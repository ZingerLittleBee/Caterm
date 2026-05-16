import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import KeychainStore

@MainActor
final class SessionStoreCredentialOnlyTests: XCTestCase {
    var sut: SessionStore!
    var tmpHostsURL: URL!
    var ephemeralService: String!

    override func setUp() async throws {
        ephemeralService = "com.caterm.test.\(UUID().uuidString)"
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-credonly-\(UUID()).json")
        let kc = KeychainStore(service: ephemeralService, accessGroup: nil)
        sut = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A",
            knownHostsUser: "/B", accessGroup: nil,
            hostsURL: tmpHostsURL, keychain: kc
        )
    }

    override func tearDown() async throws {
        // Restore parent dir perms in case a test left them locked.
        let parent = tmpHostsURL.deletingLastPathComponent()
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: parent.path
        )
        try? FileManager.default.removeItem(at: tmpHostsURL)
        if let kc = sut?.keychain {
            try? kc.deleteAll(prefix: "")
        }
    }

    /// Pin the "no sync side-effect" invariant: setCredentialOnly must
    /// not advance updatedAt. (If it did, a Sync Now after credential
    /// setup would push spurious server updates.)
    func testSetCredentialOnlyChangesCredentialButNotUpdatedAt() throws {
        let host = SSHHost(name: "t", hostname: "h", port: 22, username: "u",
                           credential: .password)
        try sut.addHost(host)
        let before = sut.hosts[0].updatedAt

        try sut.setCredentialOnly(.agent, for: host.id)

        XCTAssertEqual(sut.hosts[0].credential, .agent)
        XCTAssertEqual(sut.hosts[0].updatedAt, before,
                       "updatedAt must not advance on credential-only change")

        // Persistence reflects the new credential too.
        let reloaded = try HostPersistence.load(from: tmpHostsURL)
        XCTAssertEqual(reloaded.first?.credential, .agent)
    }

    func testSetCredentialOnlyNonexistentHostIsNoOp() throws {
        let host = SSHHost(name: "t", hostname: "h", port: 22, username: "u",
                           credential: .password)
        try sut.addHost(host)
        let snapshot = sut.hosts

        try sut.setCredentialOnly(.agent, for: UUID())  // unrelated UUID

        XCTAssertEqual(sut.hosts.count, snapshot.count)
        XCTAssertEqual(sut.hosts[0].credential, .password)
    }

    /// Pin the copy-save-assign atomicity claim: when HostPersistence.save
    /// throws (here: parent dir read-only), the in-memory hosts array
    /// must remain at its pre-call state.
    ///
    /// Note: we use a dedicated nested tmpDir (a directory we create and
    /// therefore own), because FileManager cannot chmod the system-managed
    /// temporaryDirectory itself (EPERM). The named sub-dir is ours to lock.
    func testSetCredentialOnlyRollsBackOnSaveFailure() throws {
        // Create a dedicated parent directory we own so chmod is permitted.
        let ownedParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedParent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: ownedParent.path
            )
            try? FileManager.default.removeItem(at: ownedParent)
        }

        let rollbackHostsURL = ownedParent.appendingPathComponent("hosts.json")
        let kc = KeychainStore(service: ephemeralService, accessGroup: nil)
        let rollbackSUT = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A",
            knownHostsUser: "/B", accessGroup: nil,
            hostsURL: rollbackHostsURL, keychain: kc
        )

        let host = SSHHost(name: "t", hostname: "h", port: 22, username: "u",
                           credential: .password)
        try rollbackSUT.addHost(host)
        XCTAssertEqual(rollbackSUT.hosts[0].credential, .password)

        // Delete the hosts file so createDirectory is needed on the next
        // save, then lock the parent to prevent it.
        try FileManager.default.removeItem(at: rollbackHostsURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: ownedParent.path
        )

        // HostPersistence.save uses non-atomic data.write(to:), and
        // createDirectory runs before that. Locking the parent dir
        // read-only forces createDirectory to throw EACCES.
        XCTAssertThrowsError(
            try rollbackSUT.setCredentialOnly(.agent, for: host.id),
            "save() should throw when parent dir is read-only"
        )
        XCTAssertEqual(rollbackSUT.hosts[0].credential, .password,
                       "in-memory state must be unchanged after save failure")
    }
}
