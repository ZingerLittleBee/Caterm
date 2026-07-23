import SSHCommandBuilder
@testable import CatermMobile
import XCTest

final class MobileHostDraftTests: XCTestCase {
	func testPasswordDraftBuildsHostAndSecret() throws {
		var draft = MobileHostDraft()
		draft.label = "Prod"
		draft.hostname = "example.com"
		draft.port = "2222"
		draft.username = "deploy"
		draft.credential = .password(secret: "pw")

		let payload = try draft.build(mode: .add, allHosts: [])

		XCTAssertEqual(payload.host.name, "Prod")
		XCTAssertEqual(payload.host.hostname, "example.com")
		XCTAssertEqual(payload.host.port, 2222)
		XCTAssertEqual(payload.host.username, "deploy")
		XCTAssertEqual(payload.host.credential, .password)
		XCTAssertEqual(payload.secret, "pw")
		XCTAssertTrue(payload.host.credentialMaterialDirty)
	}

	func testChangingCredentialSourceMarksMaterialDirtyWithoutNewSecret() throws {
		let existing = SSHHost(
			id: UUID(),
			name: "Box",
			hostname: "box.example.com",
			username: "deploy",
			credential: .password,
			credentialMaterialDirty: false
		)
		var draft = MobileHostDraft(host: existing)
		draft.credential = .agent

		let payload = try draft.build(mode: .edit(existing), allHosts: [])

		XCTAssertEqual(payload.host.credential, .agent)
		XCTAssertNil(payload.secret)
		XCTAssertTrue(payload.host.credentialMaterialDirty)
	}

	func testMetadataOnlyEditPreservesCleanCredentialMaterial() throws {
		let existing = SSHHost(
			id: UUID(),
			name: "Old",
			hostname: "box.example.com",
			username: "deploy",
			credential: .password,
			credentialMaterialDirty: false
		)
		var draft = MobileHostDraft(host: existing)
		draft.label = "New"

		let payload = try draft.build(mode: .edit(existing), allHosts: [])

		XCTAssertFalse(payload.host.credentialMaterialDirty)
	}

	func testBlankLabelFallsBackToUserAtHost() throws {
		var draft = MobileHostDraft()
		draft.hostname = "box.local"
		draft.port = "22"
		draft.username = "root"
		draft.credential = .agent

		let payload = try draft.build(mode: .add, allHosts: [])

		XCTAssertEqual(payload.host.name, "root@box.local")
		XCTAssertNil(payload.secret)
	}

	func testInvalidPortThrows() {
		var draft = MobileHostDraft()
		draft.hostname = "box.local"
		draft.port = "70000"
		draft.username = "root"

		XCTAssertThrowsError(try draft.build(mode: .add, allHosts: [])) { error in
			XCTAssertEqual(error as? MobileHostDraft.ValidationError, .invalidPort)
		}
	}

	func testEditModePreservesHiddenHostFields() throws {
		let existing = SSHHost(
			id: UUID(),
			serverId: "server-1",
			name: "Old",
			hostname: "old.example.com",
			port: 22,
			username: "old-user",
			credential: .agent,
			updatedAt: Date(timeIntervalSince1970: 123),
			credentialMaterialDirty: true
		)
		var draft = MobileHostDraft(host: existing)
		draft.label = "New"
		draft.hostname = "new.example.com"
		draft.port = "2200"
		draft.username = "deploy"
		draft.credential = .keyFile(path: "/keys/id_ed25519", hasPassphrase: true, secret: "phrase")

		let payload = try draft.build(mode: .edit(existing), allHosts: [])

		XCTAssertEqual(payload.host.id, existing.id)
		XCTAssertEqual(payload.host.serverId, "server-1")
		XCTAssertEqual(payload.host.name, "New")
		XCTAssertEqual(payload.host.hostname, "new.example.com")
		XCTAssertEqual(payload.host.port, 2200)
		XCTAssertEqual(payload.host.username, "deploy")
		XCTAssertEqual(payload.host.credential, .keyFile(keyPath: "/keys/id_ed25519", hasPassphrase: true))
		XCTAssertEqual(payload.host.updatedAt, existing.updatedAt)
		XCTAssertTrue(payload.host.credentialMaterialDirty)
		XCTAssertEqual(payload.secret, "phrase")
	}

	func testAutomationRoundTripsThroughMobileDraft() throws {
		let automation = HostAutomation(
			isEnabled: true,
			startupSnippetID: UUID(),
			environment: [
				HostEnvironmentVariable(name: "REGION", value: "west")
			],
			reviewPolicy: .always,
			reconnectPolicy: .everyConnection
		)
		let existing = SSHHost(
			name: "Automated",
			hostname: "automated.example",
			username: "deploy",
			credential: .password,
			automation: automation
		)
		let draft = MobileHostDraft(host: existing)

		let payload = try draft.build(mode: .edit(existing), allHosts: [])

		XCTAssertEqual(draft.automation, automation)
		XCTAssertEqual(payload.host.automation, automation)
	}

	func testInvalidAutomationFailsInsteadOfSavingSilently() {
		var draft = MobileHostDraft()
		draft.hostname = "automated.example"
		draft.username = "deploy"
		draft.automation = HostAutomation(
			isEnabled: true,
			environment: [
				HostEnvironmentVariable(name: "1INVALID", value: "value")
			]
		)

		XCTAssertThrowsError(
			try draft.build(mode: .add, allHosts: [])
		) { error in
			guard case .invalidAutomation =
				error as? MobileHostDraft.ValidationError else {
				return XCTFail("Expected invalid automation, got \(error)")
			}
		}
	}
}
