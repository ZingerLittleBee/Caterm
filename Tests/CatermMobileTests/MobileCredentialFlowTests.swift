import KeychainStore
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
