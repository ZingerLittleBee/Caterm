import XCTest
@testable import SSHCommandBuilder

final class SSHConnectionPolicyTests: XCTestCase {
	private func host(_ credential: CredentialSource) -> SSHHost {
		SSHHost(
			id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
			name: "Host",
			hostname: "host.example.com",
			username: "alice",
			credential: credential
		)
	}

	private func configLines(for credential: CredentialSource) throws -> [String] {
		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host(credential),
			role: .target,
			knownHostsFiles: ["/caterm/known_hosts", "/user/known_hosts"]
		)
		return try plan.options.map { try $0.configLine() }
	}

	func testPasswordPolicy() throws {
		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host(.password),
			role: .target,
			knownHostsFiles: ["/caterm/known_hosts", "/user/known_hosts"]
		)
		let lines = try plan.options.map { try $0.configLine() }

		XCTAssertEqual(plan.credentialKind, .password)
		XCTAssertTrue(lines.contains("PreferredAuthentications password,keyboard-interactive"))
		XCTAssertTrue(lines.contains("PubkeyAuthentication no"))
		XCTAssertTrue(lines.contains("NumberOfPasswordPrompts 1"))
	}

	func testPasswordlessKeyPolicy() throws {
		let lines = try configLines(for: .keyFile(
			keyPath: "/Users/alice/.ssh/id_ed25519",
			hasPassphrase: false
		))
		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host(.keyFile(keyPath: "/key", hasPassphrase: false)),
			role: .target,
			knownHostsFiles: ["/caterm/known_hosts", "/user/known_hosts"]
		)

		XCTAssertNil(plan.credentialKind)
		XCTAssertTrue(lines.contains("IdentitiesOnly yes"))
		XCTAssertTrue(lines.contains("PreferredAuthentications publickey"))
		XCTAssertTrue(lines.contains("PasswordAuthentication no"))
		XCTAssertTrue(lines.contains("KbdInteractiveAuthentication no"))
		XCTAssertTrue(lines.contains("IdentityFile /Users/alice/.ssh/id_ed25519"))
	}

	func testPassphrasedKeyPolicyRequestsPassphrase() {
		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host(.keyFile(keyPath: "/key", hasPassphrase: true)),
			role: .target,
			knownHostsFiles: ["/caterm/known_hosts", "/user/known_hosts"]
		)

		XCTAssertEqual(plan.credentialKind, .keyPassphrase)
	}

	func testAgentPolicyUsesBatchModeWithoutDisablingPublicKey() throws {
		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host(.agent),
			role: .target,
			knownHostsFiles: ["/caterm/known_hosts", "/user/known_hosts"]
		)
		let lines = try plan.options.map { try $0.configLine() }

		XCTAssertNil(plan.credentialKind)
		XCTAssertTrue(lines.contains("BatchMode yes"))
		XCTAssertFalse(lines.contains(where: { $0.hasPrefix("IdentityFile ") }))
		XCTAssertFalse(lines.contains("PubkeyAuthentication no"))
	}

	func testKnownHostsFilesRemainSeparateAcrossRenderers() throws {
		let files = [
			"/Users/alice/Library/Application Support/Caterm/known_hosts",
			#"/Users/alice/SSH\ Files/known_hosts"#,
		]
		let plan = SSHConnectionPolicy.interactiveHostPlan(
			for: host(.agent),
			role: .target,
			knownHostsFiles: files
		)
		guard let option = plan.options.first(where: {
			if case .option(keyword: "UserKnownHostsFile") = $0.kind { return true }
			return false
		}) else {
			return XCTFail("missing UserKnownHostsFile option")
		}

		XCTAssertEqual(
			try option.configLine(),
			#"UserKnownHostsFile "/Users/alice/Library/Application Support/Caterm/known_hosts" "/Users/alice/SSH\\ Files/known_hosts""#
		)
		XCTAssertEqual(
			try option.invocationArguments(),
			[
				"-o",
				#"UserKnownHostsFile="/Users/alice/Library/Application Support/Caterm/known_hosts" "/Users/alice/SSH\\ Files/known_hosts""#,
			]
		)
	}
}
