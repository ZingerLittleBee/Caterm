import XCTest
@testable import Caterm
@testable import SSHCommandBuilder

/// Regression tests for `HostFormView.buildHost`. The .edit code path must
/// preserve hidden fields (`serverId`, `createdAt`, `credentialMaterialDirty`)
/// from the existing host. Constructing a fresh `SSHHost` with the default
/// initializer erased `serverId`, which caused the next sync pass to treat
/// the renamed host as a new local insert and re-pull the original CloudKit
/// record as a duplicate (Plan C scenario-3 regression, fixed 2026-05-02).
@MainActor
final class HostFormBuildHostTests: XCTestCase {

	func testEditModePreservesHiddenFields() {
		let id = UUID()
		let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
		let updatedAt = Date(timeIntervalSince1970: 1_710_000_000)
		let original = SSHHost(
			id: id,
			serverId: "0EB876B3-C20A-490A-93AF-14FA7B10E6F4",
			name: "old-label",
			hostname: "old.example.com",
			port: 2200,
			username: "olduser",
			credential: .password,
			createdAt: createdAt,
			updatedAt: updatedAt,
			credentialMaterialDirty: true
		)

		let result = HostFormView.buildHost(
			mode: .edit(original),
			name: "new-label",
			hostname: "new.example.com",
			port: 22,
			username: "newuser",
			credential: .password
		)

		// Visible fields updated.
		XCTAssertEqual(result.id, id)
		XCTAssertEqual(result.name, "new-label")
		XCTAssertEqual(result.hostname, "new.example.com")
		XCTAssertEqual(result.port, 22)
		XCTAssertEqual(result.username, "newuser")

		// Hidden fields preserved — the regression bug.
		XCTAssertEqual(result.serverId, "0EB876B3-C20A-490A-93AF-14FA7B10E6F4")
		XCTAssertEqual(result.createdAt, createdAt)
		XCTAssertEqual(result.credentialMaterialDirty, true)
	}

	func testEditModePreservesServerIdAcrossCredentialKindChange() {
		let id = UUID()
		let original = SSHHost(
			id: id,
			serverId: "remote-abc",
			name: "h",
			hostname: "h.example.com",
			port: 22,
			username: "u",
			credential: .password,
			credentialMaterialDirty: false
		)

		let result = HostFormView.buildHost(
			mode: .edit(original),
			name: "h",
			hostname: "h.example.com",
			port: 22,
			username: "u",
			credential: .keyFile(keyPath: "/Users/u/.ssh/id_ed25519", hasPassphrase: true)
		)

		XCTAssertEqual(result.serverId, "remote-abc")
		if case let .keyFile(path, hasPass) = result.credential {
			XCTAssertEqual(path, "/Users/u/.ssh/id_ed25519")
			XCTAssertTrue(hasPass)
		} else {
			XCTFail("credential not updated to keyFile")
		}
	}

	func testAddModeAllocatesFreshHostWithDefaults() {
		let result = HostFormView.buildHost(
			mode: .add,
			name: "fresh",
			hostname: "f.example.com",
			port: 22,
			username: "u",
			credential: .agent
		)

		XCTAssertNil(result.serverId)
		XCTAssertFalse(result.credentialMaterialDirty)
		XCTAssertEqual(result.name, "fresh")
		XCTAssertEqual(result.credential, .agent)
	}

	func testCredentialRoutingTransactsForSourceOnlyChange() {
		let result = HostCredentialEditRouting.route(
			initial: .keyFile(keyPath: "/managed/key", hasPassphrase: false),
			current: .keyFile(keyPath: "/managed/key", hasPassphrase: false),
			updated: .password,
			hasSecret: false,
			hasKeyMaterial: false
		)

		XCTAssertEqual(result, .transact(forceSourceCommit: true))
	}

	func testCredentialRoutingPreservesConcurrentSourceForMetadataOnlyEdit() {
		let result = HostCredentialEditRouting.route(
			initial: .agent,
			current: .password,
			updated: .agent,
			hasSecret: false,
			hasKeyMaterial: false
		)

		XCTAssertEqual(result, .preserveCurrent)
	}

	func testCredentialRoutingTransactsForNewMaterial() {
		XCTAssertEqual(
			HostCredentialEditRouting.route(
				initial: .password,
				current: .password,
				updated: .password,
				hasSecret: true,
				hasKeyMaterial: false
			),
			.transact(forceSourceCommit: false)
		)
		XCTAssertEqual(
			HostCredentialEditRouting.route(
				initial: .keyFile(keyPath: "/managed/key", hasPassphrase: false),
				current: .agent,
				updated: .keyFile(keyPath: "/managed/key", hasPassphrase: false),
				hasSecret: false,
				hasKeyMaterial: true
			),
			.transact(forceSourceCommit: true)
		)
	}
}
