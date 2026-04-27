import XCTest
@testable import SSHCommandBuilder

final class AgentPathTests: XCTestCase {
    func testAgentSetsBatchMode() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertTrue(result.command.contains("BatchMode=yes"))
    }

    func testAgentNoIdentityFile() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertFalse(result.command.contains(" -i "))
    }

    func testAgentNoAskpassEnv() {
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertTrue(result.env.isEmpty)
    }

    func testAgentDoesNotForbidPubkey() {
        // Agent path uses pubkey auth — must NOT have PubkeyAuthentication=no
        let host = Host(id: UUID(), name: "x", hostname: "h", port: 22,
                        username: "u", credential: .agent)
        let result = SSHCommandBuilder.build(host: host, askpassPath: "/x",
                                             knownHostsCaterm: "/A", knownHostsUser: "/B")
        XCTAssertFalse(result.command.contains("PubkeyAuthentication=no"))
    }
}
