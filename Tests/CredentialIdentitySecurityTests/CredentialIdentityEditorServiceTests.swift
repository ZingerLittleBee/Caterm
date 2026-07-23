@testable import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import ManagedKeyStore
import Testing

@Suite(.serialized)
@MainActor
struct CredentialIdentityEditorServiceTests {
	@Test
	func sharedEditorServiceCommitsAndDeletesIdentityMaterial()
		async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"credential-editor-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: root) }
		let store = CredentialIdentityStore(
			fileURL: root.appendingPathComponent("identities.json")
		)
		let materials = CredentialIdentityMaterialStore(
			secrets: EditorMemorySecretStore(),
			managedKeys: ManagedKeyStore(
				rootURL: root.appendingPathComponent(
					"keys",
					isDirectory: true
				)
			),
			secureEnclave: EditorUnavailableSecureEnclave()
		)
		let editor = CredentialIdentityEditorService(
			materialStore: materials
		)

		let identity = try await editor.save(
			CredentialIdentityEditorInput(
				existingIdentity: nil,
				kind: .password,
				name: "Production",
				username: "deploy",
				password: Data("secret".utf8),
				originDeviceID: UUID(),
				localizedReason: "Test"
			),
			to: store
		)

		#expect(store.identity(id: identity.id)?.name == "Production")
		#expect(
			try await materials.snapshot(for: identity).password
				== Data("secret".utf8)
		)

		try await editor.delete(
			identity,
			assignedHostIDs: { [] },
			from: store
		)

		#expect(store.identity(id: identity.id) == nil)
		#expect(
			try await materials.snapshot(for: identity)
				== CredentialIdentityMaterial()
		)
	}

	@Test
	func secureEnclaveReplacementRestoresOldIdentityAfterDeleteFailure()
		async throws {
		let fixture = try EditorFixture()
		defer { fixture.cleanup() }
		let pair = try await fixture.seedSecureEnclavePair()
		fixture.secrets.failingDeleteAccounts = [
			fixture.secureEnclaveAccount(pair.old),
		]

		await #expect(throws: EditorSecretFailure.rejected) {
			_ = try await fixture.editor.commitSecureEnclaveReplacement(
				for: pair.old,
				generated: pair.generated,
				in: fixture.store
			)
		}

		let retained = try #require(
			fixture.store.identity(id: pair.old.id)
		)
		#expect(retained.source.materialID == pair.old.source.materialID)
		#expect(
			try await fixture.materials.snapshot(for: retained)
				.secureEnclaveKeyBlob == Data("old-blob".utf8)
		)
		#expect(
			try await fixture.materials.snapshot(for: pair.generated)
				== CredentialIdentityMaterial()
		)
	}

	@Test
	func failedOldMaterialRestoreFallsForwardToUsableNewIdentity()
		async throws {
		let fixture = try EditorFixture()
		defer { fixture.cleanup() }
		let pair = try await fixture.seedSecureEnclavePair()
		let oldAccount = fixture.secureEnclaveAccount(pair.old)
		fixture.secrets.failingDeleteAccounts = [oldAccount]
		fixture.secrets.failingWriteAccounts = [oldAccount]

		await #expect(throws: CredentialIdentityRollbackError.self) {
			_ = try await fixture.editor.commitSecureEnclaveReplacement(
				for: pair.old,
				generated: pair.generated,
				in: fixture.store
			)
		}

		let retained = try #require(
			fixture.store.identity(id: pair.old.id)
		)
		#expect(
			retained.source.materialID
				== pair.generated.source.materialID
		)
		#expect(
			try await fixture.materials.snapshot(for: retained)
				.secureEnclaveKeyBlob == Data("new-blob".utf8)
		)
	}

	@Test
	func failedStoreRollbackKeepsGeneratedMaterialForCurrentMetadata()
		async throws {
		let fixture = try EditorFixture()
		defer { fixture.cleanup() }
		let pair = try await fixture.seedSecureEnclavePair()
		fixture.secrets.failingDeleteAccounts = [
			fixture.secureEnclaveAccount(pair.old),
		]
		fixture.secrets.onRejectedDelete = {
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o500],
				ofItemAtPath: fixture.root.path
			)
		}
		defer {
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o700],
				ofItemAtPath: fixture.root.path
			)
		}

		await #expect(throws: CredentialIdentityRollbackError.self) {
			_ = try await fixture.editor.commitSecureEnclaveReplacement(
				for: pair.old,
				generated: pair.generated,
				in: fixture.store
			)
		}

		let retained = try #require(
			fixture.store.identity(id: pair.old.id)
		)
		#expect(
			retained.source.materialID
				== pair.generated.source.materialID
		)
		#expect(
			try await fixture.materials.snapshot(for: retained)
				.secureEnclaveKeyBlob == Data("new-blob".utf8)
		)
	}

	@Test
	func deletionRechecksAssignmentsAfterWaitingForTransaction()
		async throws {
		let fixture = try EditorFixture()
		defer { fixture.cleanup() }
		let identity = CredentialIdentity(
			name: "Shared",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await fixture.store.upsert(identity)
		try await fixture.materials.replaceMaterial(
			for: identity,
			with: .init(password: Data("secret".utf8))
		)
		let blocker = EditorTransactionBlocker()
		let assignments = EditorAssignmentState()
		let holder = Task { @MainActor in
			try await fixture.store.withTransaction {
				await blocker.block()
			}
		}
		await blocker.waitUntilBlocked()
		let deletion = Task { @MainActor in
			try await fixture.editor.delete(
				identity,
				assignedHostIDs: { assignments.hostIDs },
				from: fixture.store
			)
		}
		for _ in 0..<20 { await Task.yield() }
		let hostID = UUID()
		assignments.hostIDs = [hostID]
		await blocker.release()
		try await holder.value

		await #expect(
			throws: CredentialIdentityStoreError.identityInUse(
				identityID: identity.id,
				hostIDs: [hostID]
			)
		) {
			try await deletion.value
		}
		#expect(fixture.store.identity(id: identity.id) != nil)
		#expect(
			try await fixture.materials.snapshot(for: identity).password
				== Data("secret".utf8)
		)
	}
}

@MainActor
private final class EditorAssignmentState: @unchecked Sendable {
	var hostIDs: Set<UUID> = []
}

private actor EditorTransactionBlocker {
	private var blocked = false
	private var waiters: [CheckedContinuation<Void, Never>] = []
	private var releaseContinuation: CheckedContinuation<Void, Never>?

	func block() async {
		blocked = true
		waiters.forEach { $0.resume() }
		waiters.removeAll()
		await withCheckedContinuation {
			releaseContinuation = $0
		}
	}

	func waitUntilBlocked() async {
		guard !blocked else { return }
		await withCheckedContinuation { waiters.append($0) }
	}

	func release() {
		releaseContinuation?.resume()
		releaseContinuation = nil
	}
}

private enum EditorSecretFailure: Error {
	case rejected
}

private final class EditorMemorySecretStore: IdentitySecretStoring,
	@unchecked Sendable {
	private let lock = NSLock()
	private var values: [String: Data] = [:]
	var failingDeleteAccounts: Set<String> = []
	var failingWriteAccounts: Set<String> = []
	var onRejectedDelete: (() -> Void)?

	func read(account: String) throws -> Data? {
		lock.withLock { values[account] }
	}

	func write(_ data: Data, account: String) throws {
		guard !failingWriteAccounts.contains(account) else {
			throw EditorSecretFailure.rejected
		}
		lock.withLock { values[account] = data }
	}

	func delete(account: String) throws {
		guard !failingDeleteAccounts.contains(account) else {
			onRejectedDelete?()
			throw EditorSecretFailure.rejected
		}
		lock.withLock { values[account] = nil }
	}
}

@MainActor
private final class EditorFixture {
	let root: URL
	let store: CredentialIdentityStore
	let secrets: EditorMemorySecretStore
	let materials: CredentialIdentityMaterialStore
	let editor: CredentialIdentityEditorService

	init() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"credential-editor-failure-\(UUID().uuidString)",
			isDirectory: true
		)
		store = CredentialIdentityStore(
			fileURL: root.appendingPathComponent("identities.json")
		)
		secrets = EditorMemorySecretStore()
		materials = CredentialIdentityMaterialStore(
			secrets: secrets,
			managedKeys: ManagedKeyStore(
				rootURL: root.appendingPathComponent(
					"keys",
					isDirectory: true
				)
			),
			secureEnclave: EditorUnavailableSecureEnclave()
		)
		editor = CredentialIdentityEditorService(materialStore: materials)
	}

	func seedSecureEnclavePair() async throws -> (
		old: CredentialIdentity,
		generated: CredentialIdentity
	) {
		let old = CredentialIdentity(
			name: "Device Key",
			username: "deploy",
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data("old-public".utf8),
				originDeviceID: UUID()
			)
		)
		let generated = CredentialIdentity(
			name: old.name,
			username: old.username,
			source: .secureEnclaveP256(
				materialID: CredentialMaterialID(),
				publicKey: Data("new-public".utf8),
				originDeviceID: UUID()
			)
		)
		try await store.upsert(old)
		try await materials.replaceMaterial(
			for: old,
			with: CredentialIdentityMaterial(
				secureEnclaveKeyBlob: Data("old-blob".utf8)
			)
		)
		try await materials.replaceMaterial(
			for: generated,
			with: CredentialIdentityMaterial(
				secureEnclaveKeyBlob: Data("new-blob".utf8)
			)
		)
		return (old, generated)
	}

	func secureEnclaveAccount(_ identity: CredentialIdentity) -> String {
		CredentialIdentityKeychainContract.account(
			materialID: identity.source.materialID,
			kind: .secureEnclaveKey
		)
	}

	func cleanup() {
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o700],
			ofItemAtPath: root.path
		)
		try? FileManager.default.removeItem(at: root)
	}
}

private struct EditorUnavailableSecureEnclave:
	SecureEnclaveIdentityKeyProviding {
	let isAvailable = false

	func create(localizedReason: String) throws
		-> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}

	func restore(
		dataRepresentation: Data,
		localizedReason: String
	) throws -> SecureEnclaveIdentityKey {
		throw SecureEnclaveIdentityError.unavailable
	}
}
