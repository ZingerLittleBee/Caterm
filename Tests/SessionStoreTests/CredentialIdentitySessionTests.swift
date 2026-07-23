import CredentialIdentityRuntime
import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import KeychainStore
import ManagedKeyStore
import SSHCommandBuilder
import XCTest
@testable import SessionStore

@MainActor
final class CredentialIdentitySessionTests: XCTestCase {
	func testIdentityPasswordRoutesThroughDataProtectionKeychain()
		async throws {
		let fixture = try IdentitySessionFixture()
		let identity = try await fixture.addPasswordIdentity(
			username: "shared-ops"
		)
		let tabID = fixture.sessionStore.openTab(
			host: fixture.host(assignedTo: identity.id)
		)

		await fixture.sessionStore.awaitConnectionAttempt(
			tabId: tabID
		)
		let surface = try XCTUnwrap(
			fixture.sessionStore.surfaceConfig(for: tabID)
		)
		let environment = Dictionary(
			uniqueKeysWithValues: surface.env
		)

		XCTAssertTrue(
			surface.command.contains(
				"'shared-ops'@'server.example.com'"
			)
		)
		XCTAssertEqual(
			environment["CATERM_ASKPASS_SERVICE"],
			CredentialIdentityKeychainContract.service
		)
		XCTAssertEqual(
			environment["CATERM_ASKPASS_ACCOUNT"],
			CredentialIdentityKeychainContract.account(
				materialID: identity.source.materialID,
				kind: .password
			)
		)
		XCTAssertEqual(
			environment["CATERM_ASKPASS_DATA_PROTECTION"],
			"1"
		)
		XCTAssertNil(environment["CATERM_HOST_ID"])
	}

	func testIdentityEditOnlyAffectsTabsOpenedAfterEdit()
		async throws {
		let fixture = try IdentitySessionFixture()
		var identity = try await fixture.addPasswordIdentity(
			username: "before"
		)
		let host = fixture.host(assignedTo: identity.id)
		let firstTabID = fixture.sessionStore.openTab(host: host)
		await fixture.sessionStore.awaitConnectionAttempt(
			tabId: firstTabID
		)
		let firstBeforeEdit = try XCTUnwrap(
			fixture.sessionStore.surfaceConfig(for: firstTabID)
		)

		identity.username = "after"
		try fixture.identityStore.upsert(identity)
		let secondTabID = fixture.sessionStore.openTab(host: host)
		await fixture.sessionStore.awaitConnectionAttempt(
			tabId: secondTabID
		)
		let firstAfterEdit = try XCTUnwrap(
			fixture.sessionStore.surfaceConfig(for: firstTabID)
		)
		let second = try XCTUnwrap(
			fixture.sessionStore.surfaceConfig(for: secondTabID)
		)

		XCTAssertEqual(
			firstBeforeEdit.command,
			firstAfterEdit.command
		)
		XCTAssertTrue(
			firstAfterEdit.command.contains(
				"'before'@'server.example.com'"
			)
		)
		XCTAssertTrue(
			second.command.contains(
				"'after'@'server.example.com'"
			)
		)
	}

	func testMissingIdentityFailsWithoutLegacyCredentialFallback()
		async throws {
		let fixture = try IdentitySessionFixture()
		let missingID = UUID()
		let tabID = fixture.sessionStore.openTab(
			host: fixture.host(assignedTo: missingID)
		)

		await fixture.sessionStore.awaitConnectionAttempt(
			tabId: tabID
		)
		let tab = try XCTUnwrap(
			fixture.sessionStore.tabs.first {
				$0.id == tabID
			}
		)
		guard case .failed(
			.networkUnreachable(.other(_, let message))
		) = tab.state else {
			return XCTFail("Expected identity preparation failure")
		}

		XCTAssertTrue(
			message.contains(
				"Credential identity unavailable"
			)
		)
		XCTAssertNil(
			fixture.sessionStore.surfaceConfig(for: tabID)
		)
	}
}

@MainActor
private final class IdentitySessionFixture {
	let identityStore: CredentialIdentityStore
	let materialStore: CredentialIdentityMaterialStore
	let sessionStore: SessionStore

	private let secrets = SessionMemoryIdentitySecrets()

	init() throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		let managedKeys = ManagedKeyStore(
			rootURL: root.appendingPathComponent(
				"keys",
				isDirectory: true
			)
		)
		identityStore = CredentialIdentityStore(
			fileURL: root.appendingPathComponent(
				"identities.json"
			)
		)
		materialStore = CredentialIdentityMaterialStore(
			secrets: secrets,
			managedKeys: managedKeys,
			secureEnclave:
				SessionUnavailableSecureEnclave()
		)
		sessionStore = SessionStore(
			askpassPath: "/caterm-askpass",
			knownHostsCaterm: "/known/caterm",
			knownHostsUser: "/known/user",
			accessGroup: nil,
			hostsURL: root.appendingPathComponent(
				"hosts.json"
			),
			keychain: KeychainStore(
				service: "com.caterm.test.legacy",
				accessGroup: nil
			),
			preflight: ImmediateIdentityPreflight(),
			managedKeyStore: managedKeys,
			credentialIdentityStore: identityStore,
			credentialIdentityPreparer:
				CredentialIdentityConnectionPreparer(
					materialStore: materialStore,
					managedKeyStore: managedKeys
				)
		)
	}

	func addPasswordIdentity(
		username: String
	) async throws -> CredentialIdentity {
		let identity = CredentialIdentity(
			name: "Shared",
			username: username,
			source: .password(
				materialID: CredentialMaterialID()
			)
		)
		try await materialStore.replaceMaterial(
			for: identity,
			with: .init(
				password: Data("secret".utf8)
			)
		)
		try identityStore.upsert(identity)
		return try XCTUnwrap(
			identityStore.identity(id: identity.id)
		)
	}

	func host(assignedTo identityID: UUID) -> SSHHost {
		var host = SSHHost(
			name: "Server",
			hostname: "server.example.com",
			port: 22,
			username: "legacy",
			credential: .password
		)
		host.credentialIdentity = .init(
			identityID: identityID,
			migrationState: .confirmed
		)
		return host
	}
}

private final class SessionMemoryIdentitySecrets:
	IdentitySecretStoring, @unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: Data] = [:]

	func read(account: String) throws -> Data? {
		lock.withLock { values[account] }
	}

	func write(_ data: Data, account: String) throws {
		lock.withLock { values[account] = data }
	}

	func delete(account: String) throws {
		_ = lock.withLock { values.removeValue(forKey: account) }
	}
}

private struct SessionUnavailableSecureEnclave:
	SecureEnclaveIdentityKeyProviding {
	var isAvailable: Bool { false }

	func create(
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}

	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}
}

private final class ImmediateIdentityPreflight:
	PreflightProbing, @unchecked Sendable {
	func probe(
		host: String,
		port: UInt16,
		timeout: TimeInterval
	) async -> PreflightOutcome {
		.ok
	}

	func probeLocalBind(
		address: String,
		port: UInt16
	) async -> PortBindOutcome {
		.available
	}
}
