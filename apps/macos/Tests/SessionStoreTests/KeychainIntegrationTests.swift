import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import KeychainStore

@MainActor
final class KeychainIntegrationTests: XCTestCase {
    var sut: SessionStore!
    var tmpHostsURL: URL!
    var ephemeralService: String!

    override func setUp() async throws {
        ephemeralService = "com.caterm.test.\(UUID().uuidString)"
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-int-\(UUID()).json")
        let kc = KeychainStore(service: ephemeralService, accessGroup: nil)
        sut = SessionStore(
            askpassPath: "/x", knownHostsCaterm: "/A",
            knownHostsUser: "/B", accessGroup: nil,
            hostsURL: tmpHostsURL, keychain: kc
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpHostsURL)
        // Best-effort: clear any test items still in login keychain
        if let kc = sut?.keychain {
            try? kc.deleteAll(prefix: "")
        }
    }

    func testDeleteHostWipesKeychain() throws {
        let host = SSHHost(name: "t", hostname: "h", port: 22, username: "u",
                           credential: .password)
        try sut.addHost(host)
        try sut.setHostSecret("p", hostId: host.id, kind: .password)
        XCTAssertEqual(try sut.keychain.get(account: "\(host.id.uuidString).password"), "p")

        try sut.deleteHost(id: host.id)
        XCTAssertThrowsError(try sut.keychain.get(account: "\(host.id.uuidString).password"))
    }

    func testSetHostSecretRoundtrip() throws {
        let id = UUID()
        try sut.setHostSecret("p@ss", hostId: id, kind: .password)
        XCTAssertEqual(try sut.keychain.get(account: "\(id.uuidString).password"), "p@ss")
    }

    func testSetPassphraseRoundtrip() throws {
        let id = UUID()
        try sut.setHostSecret("phrase!", hostId: id, kind: .keyPassphrase)
        XCTAssertEqual(try sut.keychain.get(account: "\(id.uuidString).keyPassphrase"), "phrase!")
    }

    func testDeleteHostWipesBothPasswordAndPassphrase() throws {
        let host = SSHHost(name: "t", hostname: "h", port: 22, username: "u",
                           credential: .keyFile(keyPath: "/x", hasPassphrase: true))
        try sut.addHost(host)
        try sut.setHostSecret("p1", hostId: host.id, kind: .password)
        try sut.setHostSecret("p2", hostId: host.id, kind: .keyPassphrase)
        try sut.deleteHost(id: host.id)
        XCTAssertThrowsError(try sut.keychain.get(account: "\(host.id.uuidString).password"))
        XCTAssertThrowsError(try sut.keychain.get(account: "\(host.id.uuidString).keyPassphrase"))
    }
}
