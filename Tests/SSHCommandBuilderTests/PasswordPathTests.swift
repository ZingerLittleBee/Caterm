import XCTest
@testable import SSHCommandBuilder

final class PasswordPathTests: XCTestCase {
    let host = Host(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        name: "test", hostname: "host.example.com", port: 22,
        username: "alice", credential: .password
    )

    func testCommandStringContainsAllRequiredOptions() {
        let result = SSHCommandBuilder.build(
            host: host,
            askpassPath: "/usr/local/bin/caterm-askpass",
            knownHostsCaterm: "/Users/alice/Library/Application Support/Caterm/known_hosts",
            knownHostsUser: "/Users/alice/.ssh/known_hosts"
        )

        let cmd = result.command
        XCTAssertTrue(cmd.contains("/usr/bin/ssh"))
        XCTAssertTrue(cmd.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(cmd.contains("PreferredAuthentications=password,keyboard-interactive"))
        XCTAssertTrue(cmd.contains("PubkeyAuthentication=no"))
        XCTAssertFalse(cmd.contains("KbdInteractiveAuthentication=no"))
        XCTAssertTrue(cmd.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(cmd.contains("'alice'@'host.example.com'"))
        XCTAssertTrue(cmd.contains("-p 22"))
    }

    func testHybridKnownHostsTwoFiles() {
        let result = SSHCommandBuilder.build(
            host: host,
            askpassPath: "/x/askpass",
            knownHostsCaterm: "/A/known_hosts",
            knownHostsUser: "/B/known_hosts"
        )
        XCTAssertTrue(result.command.contains("UserKnownHostsFile=/A/known_hosts /B/known_hosts"))
    }

	func testKnownHostsPathWithSpacesUsesInnerSSHConfigQuoting() {
		let catermPath = "/Users/alice/Library/Application Support/Caterm/known_hosts"
		let userPath = "/Users/alice/.ssh/known_hosts"
		let result = SSHCommandBuilder.build(
			host: host,
			askpassPath: "/x/askpass",
			knownHostsCaterm: catermPath,
			knownHostsUser: userPath
		)
		let option = "UserKnownHostsFile=\"\(catermPath)\" \(userPath)"

		XCTAssertTrue(result.command.contains("-o \(ShellQuote.posix(option))"))
	}

    func testEnvVarsContainAskpass() {
        let result = SSHCommandBuilder.build(
            host: host,
            askpassPath: "/usr/local/bin/caterm-askpass",
            knownHostsCaterm: "/A", knownHostsUser: "/B"
        )
        let envDict = Dictionary(uniqueKeysWithValues: result.env.map { ($0.0, $0.1) })
        XCTAssertEqual(envDict["SSH_ASKPASS"], "/usr/local/bin/caterm-askpass")
        XCTAssertEqual(envDict["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(envDict["CATERM_HOST_ID"], "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(envDict["CATERM_ASKPASS_KIND"], "password")
    }

	func testIdentityCredentialLookupUsesExplicitKeychainLocation() throws {
		let result = try SSHCommandBuilder.buildValidated(
			host: host,
			askpassPath: "/x/askpass",
			knownHostsCaterm: "/A",
			knownHostsUser: "/B",
			credentialLookup: .init(
				service: "com.caterm.identities",
				passwordAccount: "identity.material.password",
				useDataProtectionKeychain: true
			)
		)
		let environment = Dictionary(uniqueKeysWithValues: result.env)

		XCTAssertEqual(
			environment["CATERM_ASKPASS_SERVICE"],
			"com.caterm.identities"
		)
		XCTAssertEqual(
			environment["CATERM_ASKPASS_ACCOUNT"],
			"identity.material.password"
		)
		XCTAssertEqual(
			environment["CATERM_ASKPASS_DATA_PROTECTION"],
			"1"
		)
		XCTAssertNil(environment["CATERM_HOST_ID"])
	}

    func testNonDefaultPort() {
        var h = host
        h.port = 2222
        let result = SSHCommandBuilder.build(
            host: h, askpassPath: "/x", knownHostsCaterm: "/A", knownHostsUser: "/B"
        )
        XCTAssertTrue(result.command.contains("-p 2222"))
    }
}
