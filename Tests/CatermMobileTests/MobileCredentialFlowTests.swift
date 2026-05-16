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

@MainActor
final class MobileCredentialWriterTests: XCTestCase {
	func testApplyWritesAndIsIdempotentOnClear() throws {
		let kc = KeychainStore(
			service: "com.caterm.test.\(UUID().uuidString)", accessGroup: nil)
		let writer = MobileCredentialWriter(keychain: kc)
		let h = SSHHost(id: UUID(), name: "Box", hostname: "box",
		                username: "deploy", credential: .password)

		// Clearing a never-written account must not throw.
		try writer.apply(MobileHostDraftPayload(host: h, secret: "s3cret"))
		XCTAssertEqual(try kc.get(account: "\(h.id.uuidString).password"), "s3cret")

		// Switching to agent clears the stored password.
		var agentHost = h
		agentHost.credential = .agent
		try writer.apply(MobileHostDraftPayload(host: agentHost, secret: nil))
		XCTAssertThrowsError(try kc.get(account: "\(h.id.uuidString).password"))

		try? kc.deleteAll(prefix: "\(h.id.uuidString).")
	}
}
