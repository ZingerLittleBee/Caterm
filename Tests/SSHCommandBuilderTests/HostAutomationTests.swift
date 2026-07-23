import XCTest
@testable import SSHCommandBuilder

final class HostAutomationTests: XCTestCase {
	func testValidationPreservesOrderedNonSecretEnvironment() throws {
		let snippetID = UUID()
		let firstID = UUID()
		let secondID = UUID()
		let automation = HostAutomation(
			isEnabled: true,
			startupSnippetID: snippetID,
			environment: [
				HostEnvironmentVariable(
					id: firstID,
					name: "DEPLOY_REGION",
					value: "eu-west-1"
				),
				HostEnvironmentVariable(
					id: secondID,
					name: "FEATURE_FLAG",
					value: "enabled"
				),
			],
			reviewPolicy: .always,
			reconnectPolicy: .oncePerSession
		)

		let validated = try automation.validated()

		XCTAssertEqual(validated.startupSnippetID, snippetID)
		XCTAssertEqual(validated.environment.map(\.id), [firstID, secondID])
		XCTAssertEqual(
			validated.environment.map(\.name),
			["DEPLOY_REGION", "FEATURE_FLAG"]
		)
	}

	func testValidationRejectsInvalidDuplicateAndControlCharacterEnvironment() {
		XCTAssertThrowsError(try enabledEnvironment(
			(name: "1INVALID", value: "value")
		).validated()) { error in
			XCTAssertEqual(
				error as? HostAutomationValidationError,
				.invalidEnvironmentName("1INVALID")
			)
		}

		XCTAssertThrowsError(try HostAutomation(
			isEnabled: true,
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "one"),
				HostEnvironmentVariable(name: "REGION", value: "two"),
			]
		).validated()) { error in
			XCTAssertEqual(
				error as? HostAutomationValidationError,
				.duplicateEnvironmentName("REGION")
			)
		}

		XCTAssertThrowsError(try enabledEnvironment(
			(name: "REGION", value: "west\nInjected yes")
		).validated()) { error in
			XCTAssertEqual(
				error as? HostAutomationValidationError,
				.invalidEnvironmentValue("REGION")
			)
		}
	}

	func testLegacyHostDecodesWithDisabledAutomation() throws {
		let legacyJSON = """
		{
		  "id": "\(UUID().uuidString)",
		  "name": "Legacy",
		  "hostname": "legacy.example",
		  "port": 22,
		  "username": "deploy",
		  "credential": { "password": {} },
		  "createdAt": 770000000,
		  "updatedAt": 770000000
		}
		""".data(using: .utf8)!

		let host = try JSONDecoder().decode(SSHHost.self, from: legacyJSON)

		XCTAssertEqual(host.automation, .disabled)
	}

	func testHostAutomationRoundTripsWithoutCredentialMaterial() throws {
		let automation = HostAutomation(
			isEnabled: true,
			startupSnippetID: UUID(),
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "west")
			],
			reviewPolicy: .always,
			reconnectPolicy: .everyConnection
		)
		let host = SSHHost(
			name: "Automated",
			hostname: "automation.example",
			username: "deploy",
			credential: .password,
			automation: automation
		)

		let encoded = try JSONEncoder().encode(host)
		let decoded = try JSONDecoder().decode(SSHHost.self, from: encoded)

		XCTAssertEqual(decoded.automation, automation)
		XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
	}

	func testDirectAndChainBuildersSendEnabledEnvironmentThroughSetEnv() throws {
		var target = SSHHost(
			name: "Target",
			hostname: "target.example",
			username: "deploy",
			credential: .agent,
			automation: enabledEnvironment(
				(name: "REGION", value: "west coast"),
				(name: "FEATURE", value: "on")
			)
		)
		let direct = SSHCommandBuilder.build(
			host: target,
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/tmp/caterm-known-hosts",
			knownHostsUser: "/tmp/user-known-hosts"
		)
		XCTAssertTrue(direct.command.contains("SetEnv=REGION=west coast"))
		XCTAssertTrue(direct.command.contains("SetEnv=FEATURE=on"))

		let jump = SSHHost(
			name: "Jump",
			hostname: "jump.example",
			username: "deploy",
			credential: .agent
		)
		target.jumpHostId = jump.id
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: target,
			ancestors: [jump],
			configSink: sink,
			askpassPath: "/tmp/askpass",
			knownHostsCaterm: "/tmp/caterm-known-hosts",
			knownHostsUser: "/tmp/user-known-hosts",
			terminfoDump: ""
		)
		let config = try XCTUnwrap(sink.writes.first?.1)
		let targetBlock = config.components(
			separatedBy: "Host caterm-h-\(target.id.uuidString)"
		).last ?? ""
		XCTAssertTrue(targetBlock.contains("SetEnv \"REGION=west coast\""))
		XCTAssertTrue(targetBlock.contains("SetEnv FEATURE=on"))
	}

	private func enabledEnvironment(
		_ pairs: (name: String, value: String)...
	) -> HostAutomation {
		HostAutomation(
			isEnabled: true,
			environment: pairs.map {
				HostEnvironmentVariable(name: $0.name, value: $0.value)
			}
		)
	}
}
