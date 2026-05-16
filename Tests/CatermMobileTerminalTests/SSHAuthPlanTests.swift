import SSHCommandBuilder
@testable import CatermMobileTerminal
import XCTest

final class SSHAuthPlanTests: XCTestCase {
	private func host(_ c: CredentialSource) -> SSHHost {
		SSHHost(id: UUID(), name: "B", hostname: "h", username: "u", credential: c)
	}

	func testPasswordHostWithSecretUsesPassword() {
		let p = SSHAuthPlan.make(
			host: host(.password),
			password: "pw", keyBlob: nil, passphrase: nil)
		XCTAssertEqual(p.attempts, [.password("pw")])
		XCTAssertNil(p.missing)
	}

	func testPasswordHostWithoutSecretIsMissing() {
		let p = SSHAuthPlan.make(
			host: host(.password), password: nil, keyBlob: nil, passphrase: nil)
		XCTAssertTrue(p.attempts.isEmpty)
		XCTAssertEqual(p.missing, .password)
	}

	func testKeyFileWithPassphraseUsesKeyThenPassword() {
		let p = SSHAuthPlan.make(
			host: host(.keyFile(keyPath: "/k", hasPassphrase: true)),
			password: nil, keyBlob: Data([1, 2, 3]), passphrase: "pp")
		XCTAssertEqual(p.attempts, [.privateKey(blob: Data([1, 2, 3]), passphrase: "pp")])
		XCTAssertNil(p.missing)
	}

	func testKeyFileMissingPassphraseIsMissing() {
		let p = SSHAuthPlan.make(
			host: host(.keyFile(keyPath: "/k", hasPassphrase: true)),
			password: nil, keyBlob: Data([1]), passphrase: nil)
		XCTAssertEqual(p.missing, .passphrase)
	}

	func testAgentHostFallsBackToKeyboardInteractive() {
		let p = SSHAuthPlan.make(
			host: host(.agent), password: nil, keyBlob: nil, passphrase: nil)
		XCTAssertEqual(p.attempts, [.keyboardInteractive])
		XCTAssertNil(p.missing)
	}
}
