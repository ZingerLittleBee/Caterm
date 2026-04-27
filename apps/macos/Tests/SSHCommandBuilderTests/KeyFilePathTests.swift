import XCTest
@testable import SSHCommandBuilder

final class KeyFilePathTests: XCTestCase {
    func testKeyFileWithoutPassphrase() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u",
                        credential: .keyFile(keyPath: "/Users/u/.ssh/id_ed25519",
                                             hasPassphrase: false))
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertTrue(result.command.contains("PreferredAuthentications=publickey"))
        XCTAssertTrue(result.command.contains("PasswordAuthentication=no"))
        XCTAssertTrue(result.command.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(result.command.contains("-i '/Users/u/.ssh/id_ed25519'"))
        // No env when no passphrase
        XCTAssertTrue(result.env.isEmpty)
    }

    func testKeyFileWithPassphraseSetsAskpass() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u",
                        credential: .keyFile(keyPath: "/path/key", hasPassphrase: true))
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/askpass",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        let envDict = Dictionary(uniqueKeysWithValues: result.env.map { ($0.0, $0.1) })
        XCTAssertEqual(envDict["SSH_ASKPASS"], "/askpass")
        XCTAssertEqual(envDict["CATERM_ASKPASS_KIND"], "passphrase")
    }

    func testKeyFilePathWithSpaces() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u",
                        credential: .keyFile(keyPath: "/Users/My User/.ssh/id_rsa",
                                             hasPassphrase: false))
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        // Path quoted exactly once, intact
        XCTAssertTrue(result.command.contains("-i '/Users/My User/.ssh/id_rsa'"))
    }
}
