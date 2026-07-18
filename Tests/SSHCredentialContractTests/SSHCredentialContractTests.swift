import SSHCredentialContract
import XCTest

final class SSHCredentialContractTests: XCTestCase {
	private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

	func testAccountNamesAndPrefixShareOneFormat() {
		XCTAssertEqual(
			SSHCredentialContract.account(hostID: hostID, kind: .password),
			"11111111-2222-3333-4444-555555555555.password"
		)
		XCTAssertEqual(
			SSHCredentialContract.account(hostID: hostID, kind: .keyPassphrase),
			"11111111-2222-3333-4444-555555555555.keyPassphrase"
		)
		XCTAssertEqual(
			SSHCredentialContract.accountPrefix(hostID: hostID),
			"11111111-2222-3333-4444-555555555555."
		)
	}

	func testDirectAskpassEnvironmentIncludesCredentialIdentity() {
		let environment = Dictionary(uniqueKeysWithValues:
			SSHCredentialContract.askpassEnvironment(
				executable: "/tmp/caterm-askpass",
				hostID: hostID,
				kind: .keyPassphrase
			)
		)

		XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/caterm-askpass")
		XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
		XCTAssertEqual(
			environment["CATERM_HOST_ID"],
			"11111111-2222-3333-4444-555555555555"
		)
		XCTAssertEqual(environment["CATERM_ASKPASS_KIND"], "keyPassphrase")
	}

	func testChainAskpassEnvironmentOmitsDirectCredentialIdentity() {
		let environment = Dictionary(uniqueKeysWithValues:
			SSHCredentialContract.askpassEnvironment(executable: "/tmp/caterm-askpass")
		)

		XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/caterm-askpass")
		XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
		XCTAssertNil(environment["CATERM_HOST_ID"])
		XCTAssertNil(environment["CATERM_ASKPASS_KIND"])
	}
}
