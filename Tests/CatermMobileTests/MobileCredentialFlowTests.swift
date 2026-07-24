import CredentialIdentityStore
import KeychainStore
import ManagedKeyStore
import SessionStore
import SSHCommandBuilder
@testable import CatermMobile
import XCTest

final class MobileCredentialPlanTests: XCTestCase {
	private func host(_ cred: CredentialSource) -> SSHHost {
		SSHHost(id: UUID(), name: "Box", hostname: "box.example.com",
		        username: "deploy", credential: cred)
	}

	func testPasswordWithSecretWritesPasswordAndClearsPassphrase() {
		let h = host(.password)
		let ops = MobileCredentialPlan.operations(
			for: MobileHostDraftPayload(host: h, secret: "pw"))
		XCTAssertEqual(ops, [
			.clear(account: "\(h.id.uuidString).keyPassphrase"),
			.write(account: "\(h.id.uuidString).password", secret: "pw"),
		])
	}

	func testPasswordWithoutSecretPreservesExisting() {
		let h = host(.password)
		let ops = MobileCredentialPlan.operations(
			for: MobileHostDraftPayload(host: h, secret: nil))
		// No write and no clear of the password account: blank-on-edit must
		// keep the previously stored password.
		XCTAssertEqual(ops, [.clear(account: "\(h.id.uuidString).keyPassphrase")])
	}

	func testKeyFileWithPassphraseWritesPassphraseAndClearsPassword() {
		let h = host(.keyFile(keyPath: "/k", hasPassphrase: true))
		let ops = MobileCredentialPlan.operations(
			for: MobileHostDraftPayload(host: h, secret: "pp"))
		XCTAssertEqual(ops, [
			.clear(account: "\(h.id.uuidString).password"),
			.write(account: "\(h.id.uuidString).keyPassphrase", secret: "pp"),
		])
	}

	func testAgentClearsBothAccounts() {
		let h = host(.agent)
		let ops = MobileCredentialPlan.operations(
			for: MobileHostDraftPayload(host: h, secret: nil))
		XCTAssertEqual(ops, [
			.clear(account: "\(h.id.uuidString).password"),
			.clear(account: "\(h.id.uuidString).keyPassphrase"),
		])
	}

	func testConfirmedIdentityClearsHostOwnedCredential() {
		var h = host(.password)
		h.credentialIdentity = HostCredentialIdentityReference(
			identityID: UUID(),
			migrationState: .confirmed
		)

		let ops = MobileCredentialPlan.operations(
			for: MobileHostDraftPayload(host: h, secret: "ignored")
		)

		XCTAssertEqual(ops, [
			.clear(account: "\(h.id.uuidString).password"),
			.clear(account: "\(h.id.uuidString).keyPassphrase"),
		])
	}
}

final class MobileCredentialWriterTests: XCTestCase {
	private final class RecordingCredentialStore: MobileCredentialStoring {
		enum Failure: Error { case rejected }

		var values: [String: String] = [:]
		var failingSetAccounts: Set<String> = []
		var failingDeleteAccounts: Set<String> = []

		func set(account: String, secret: String) throws {
			guard !failingSetAccounts.contains(account) else { throw Failure.rejected }
			values[account] = secret
		}

		func get(account: String, interaction _: KeychainReadInteraction) throws -> String {
			guard let value = values[account] else { throw KeychainError.notFound }
			return value
		}

		func delete(account: String) throws {
			guard !failingDeleteAccounts.contains(account) else { throw Failure.rejected }
			guard values.removeValue(forKey: account) != nil else {
				throw KeychainError.notFound
			}
		}
	}

	func testApplyWritesAndIsIdempotentOnClear() async throws {
		let kc = KeychainStore(
			service: "com.caterm.test.\(UUID().uuidString)", accessGroup: nil)
		let writer = MobileCredentialWriter(keychain: kc)
		let h = SSHHost(id: UUID(), name: "Box", hostname: "box",
		                username: "deploy", credential: .password)

		// Clearing a never-written account must not throw.
		try await writer.apply(MobileHostDraftPayload(host: h, secret: "s3cret"))
		XCTAssertEqual(try kc.get(account: "\(h.id.uuidString).password"), "s3cret")

		// Switching to agent clears the stored password.
		var agentHost = h
		agentHost.credential = .agent
		try await writer.apply(MobileHostDraftPayload(host: agentHost, secret: nil))
		XCTAssertThrowsError(try kc.get(account: "\(h.id.uuidString).password"))

		try await writer.clearAll(hostId: h.id)
	}

	func testSaveActionReportsAsyncSaveAndDeleteOutcomes() async {
		actor Recorder {
			var savedHostIDs: [UUID] = []
			var deletedHostIDs: [UUID] = []

			func recordSave(_ id: UUID) { savedHostIDs.append(id) }
			func recordDelete(_ id: UUID) { deletedHostIDs.append(id) }
		}
		let recorder = Recorder()
		let host = SSHHost(
			name: "Box",
			hostname: "box.example.com",
			username: "deploy",
			credential: .agent
		)
		let action = MobileHostSaveAction(
			save: { payload in
				await recorder.recordSave(payload.host.id)
				return true
			},
			deleteHost: { hostID in
				await recorder.recordDelete(hostID)
				return true
			}
		)

		let saved = await action.save(MobileHostDraftPayload(host: host, secret: nil))
		let deleted = await action.deleteHost(host.id)
		let savedHostIDs = await recorder.savedHostIDs
		let deletedHostIDs = await recorder.deletedHostIDs

		XCTAssertTrue(saved)
		XCTAssertTrue(deleted)
		XCTAssertEqual(savedHostIDs, [host.id])
		XCTAssertEqual(deletedHostIDs, [host.id])
	}

	func testSaveRollbackRestoresCredentialsWhenHostPersistenceFails() async throws {
		let storage = RecordingCredentialStore()
		let host = SSHHost(
			name: "Box",
			hostname: "box.example.com",
			username: "deploy",
			credential: .password
		)
		let passwordAccount = MobileCredentialPlan.passwordAccount(host.id)
		let passphraseAccount = MobileCredentialPlan.keyPassphraseAccount(host.id)
		storage.values[passwordAccount] = "old-password"
		storage.values[passphraseAccount] = "old-passphrase"
		let writer = MobileCredentialWriter(storage: storage)

		do {
			try await writer.commitSave(
				MobileHostDraftPayload(host: host, secret: "new-password")
			) {
				throw RecordingCredentialStore.Failure.rejected
			}
			XCTFail("Expected persistence failure")
		} catch RecordingCredentialStore.Failure.rejected {
			// Expected.
		}

		XCTAssertEqual(storage.values[passwordAccount], "old-password")
		XCTAssertEqual(storage.values[passphraseAccount], "old-passphrase")
	}

	func testDeleteRollbackRestoresAlreadyDeletedCredentials() async throws {
		let storage = RecordingCredentialStore()
		let hostID = UUID()
		let passwordAccount = MobileCredentialPlan.passwordAccount(hostID)
		let passphraseAccount = MobileCredentialPlan.keyPassphraseAccount(hostID)
		storage.values[passwordAccount] = "password"
		storage.values[passphraseAccount] = "passphrase"
		storage.failingDeleteAccounts = [passphraseAccount]
		let writer = MobileCredentialWriter(storage: storage)

		await XCTAssertThrowsErrorAsync {
			try await writer.commitDeletion(hostID: hostID) {}
		}

		XCTAssertEqual(storage.values[passwordAccount], "password")
		XCTAssertEqual(storage.values[passphraseAccount], "passphrase")
	}

	func testConfirmedIdentityDeletesManagedHostKey() async throws {
		let storage = RecordingCredentialStore()
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"mobile-confirmed-key-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: root) }
		let managedKeys = ManagedKeyStore(rootURL: root)
		var host = SSHHost(
			name: "Box",
			hostname: "box.example.com",
			username: "deploy",
			credential: .keyFile(
				keyPath: managedKeys.path(hostId: UUID()).path,
				hasPassphrase: false
			)
		)
		host.credentialIdentity = HostCredentialIdentityReference(
			identityID: UUID(),
			migrationState: .confirmed
		)
		_ = try await managedKeys.write(
			hostId: host.id,
			bytes: Data("private-key".utf8)
		)
		let writer = MobileCredentialWriter(
			storage: storage,
			managedKeyStore: managedKeys
		)

		try await writer.commitSave(
			MobileHostDraftPayload(host: host, secret: nil)
		) {}

		XCTAssertNil(try managedKeys.read(hostId: host.id))
	}

	func testHostDeletionDeletesManagedHostKey() async throws {
		let storage = RecordingCredentialStore()
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"mobile-deleted-key-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: root) }
		let managedKeys = ManagedKeyStore(rootURL: root)
		let hostID = UUID()
		_ = try await managedKeys.write(
			hostId: hostID,
			bytes: Data("private-key".utf8)
		)
		let writer = MobileCredentialWriter(
			storage: storage,
			managedKeyStore: managedKeys
		)

		try await writer.commitDeletion(hostID: hostID) {}

		XCTAssertNil(try managedKeys.read(hostId: hostID))
	}

	func testTransactionsForSameHostDoNotInterleaveAcrossCommitAwait() async throws {
		actor CommitOrder {
			var firstEntered = false
			var secondEntered = false
			var firstContinuation: CheckedContinuation<Void, Never>?

			func enterFirst() async {
				firstEntered = true
				await withCheckedContinuation { firstContinuation = $0 }
			}

			func enterSecond() {
				secondEntered = true
			}

			func releaseFirst() {
				firstContinuation?.resume()
				firstContinuation = nil
			}
		}

		let storage = RecordingCredentialStore()
		let host = SSHHost(
			name: "Box",
			hostname: "box.example.com",
			username: "deploy",
			credential: .password
		)
		let writer = MobileCredentialWriter(storage: storage)
		let order = CommitOrder()
		let first = Task {
			do {
				try await writer.commitSave(
					MobileHostDraftPayload(host: host, secret: "first")
				) {
					await order.enterFirst()
					throw RecordingCredentialStore.Failure.rejected
				}
			} catch RecordingCredentialStore.Failure.rejected {
				// Expected.
			}
		}

		while await !order.firstEntered { await Task.yield() }
		let second = Task {
			try await writer.commitSave(
				MobileHostDraftPayload(host: host, secret: "second")
			) {
				await order.enterSecond()
			}
		}
		for _ in 0..<20 { await Task.yield() }
		let secondEnteredWhileFirstWasOpen = await order.secondEntered
		XCTAssertFalse(secondEnteredWhileFirstWasOpen)

		await order.releaseFirst()
		try await first.value
		try await second.value

		let secondEnteredAfterRelease = await order.secondEntered
		XCTAssertTrue(secondEnteredAfterRelease)
		XCTAssertEqual(
			storage.values[MobileCredentialPlan.passwordAccount(host.id)],
			"second"
		)
	}

	@MainActor
	func testCompleteSaveTransactionCannotCrossAnAccountReset() async throws {
		actor PreparationGate {
			var entered = false
			var continuation: CheckedContinuation<Void, Never>?

			func block() async {
				entered = true
				await withCheckedContinuation { continuation = $0 }
			}

			func waitUntilEntered() async {
				while !entered { await Task.yield() }
			}

			func release() {
				continuation?.resume()
				continuation = nil
			}
		}

		let hostsURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("mobile-save-account-boundary-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: hostsURL) }
		let storage = RecordingCredentialStore()
		let writer = MobileCredentialWriter(storage: storage)
		let store = MobileHostStore(fileURL: hostsURL)
		let gate = PreparationGate()
		let coordinator = MobileHostSaveCoordinator(
			hostStore: store,
			credentialWriter: writer,
			prepareCredentialSyncForSave: { transactionIsCurrent in
				await gate.block()
				guard transactionIsCurrent() else {
					throw MobileCredentialWriter.AccountTransactionError.staleAccount
				}
			}
		)
		let host = SSHHost(
			name: "Account A",
			hostname: "a.example.com",
			username: "deploy",
			credential: .password,
			credentialMaterialDirty: true
		)
		let passwordAccount = MobileCredentialPlan.passwordAccount(host.id)
		storage.values[passwordAccount] = "old-account-a-secret"
		let staleSave = Task { @MainActor in
			do {
				try await coordinator.save(
					MobileHostDraftPayload(host: host, secret: "account-a-secret")
				)
				return false
			} catch {
				return true
			}
		}

		await gate.waitUntilEntered()
		XCTAssertEqual(
			storage.values[passwordAccount],
			"account-a-secret"
		)
		let reset = Task { @MainActor in
			try await store.resetForAccountChange()
		}
		while !store.isAccountTransitionInProgress { await Task.yield() }
		await gate.release()

		let staleSaveWasRejected = await staleSave.value
		try await reset.value
		try store.finishAccountTransition()
		XCTAssertTrue(staleSaveWasRejected)
		XCTAssertTrue(storage.values.isEmpty)
		XCTAssertTrue(store.hosts.isEmpty)
		XCTAssertTrue(try HostPersistence.load(from: hostsURL).isEmpty)
	}

	@MainActor
	func testNormalSaveCannotCommitDeletedIdentityAssignment() async throws {
		actor DeletionGate {
			var entered = false
			var continuation: CheckedContinuation<Void, Never>?

			func block() async {
				entered = true
				await withCheckedContinuation { continuation = $0 }
			}

			func waitUntilEntered() async {
				while !entered { await Task.yield() }
			}

			func release() {
				continuation?.resume()
				continuation = nil
			}
		}

		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(
				"mobile-save-identity-boundary-\(UUID().uuidString)",
				isDirectory: true
			)
		defer { try? FileManager.default.removeItem(at: root) }
		let identities = CredentialIdentityStore(
			fileURL: root.appendingPathComponent("identities.json")
		)
		let identity = CredentialIdentity(
			name: "Shared",
			username: "deploy",
			source: .password(materialID: CredentialMaterialID())
		)
		try await identities.upsert(identity)
		let storage = RecordingCredentialStore()
		let writer = MobileCredentialWriter(storage: storage)
		let store = MobileHostStore(
			fileURL: root.appendingPathComponent("hosts.json"),
			credentialIdentityStore: identities
		)
		let coordinator = MobileHostSaveCoordinator(
			hostStore: store,
			credentialWriter: writer,
			prepareCredentialSyncForSave: { _ in }
		)
		var host = SSHHost(
			name: "Assigned",
			hostname: "assigned.example.com",
			username: "deploy",
			credential: .password
		)
		host.credentialIdentity = .init(
			identityID: identity.id,
			migrationState: .confirmed
		)
		let gate = DeletionGate()
		let deletion = Task { @MainActor in
			try await identities.withTransaction {
				try await identities.withDeletionReservation(id: identity.id) {
					await gate.block()
					try await identities.applyRemoteTombstone(id: identity.id)
				}
			}
		}
		await gate.waitUntilEntered()
		let save = Task { @MainActor in
			try await coordinator.save(
				MobileHostDraftPayload(
					host: host,
					secret: "must-not-be-written"
				)
			)
		}
		for _ in 0..<20 { await Task.yield() }
		XCTAssertTrue(store.hosts.isEmpty)
		XCTAssertTrue(storage.values.isEmpty)

		await gate.release()
		try await deletion.value
		do {
			try await save.value
			XCTFail("Expected the deleted identity assignment to fail")
		} catch {
			XCTAssertEqual(
				error as? CredentialIdentityStoreError,
				.identityNotFound(identity.id)
			)
		}
		XCTAssertTrue(store.hosts.isEmpty)
		XCTAssertTrue(storage.values.isEmpty)
	}
}

private func XCTAssertThrowsErrorAsync(
	_ expression: () async throws -> Void,
	file: StaticString = #filePath,
	line: UInt = #line
) async {
	do {
		try await expression()
		XCTFail("Expected error", file: file, line: line)
	} catch {
		// Expected.
	}
}
