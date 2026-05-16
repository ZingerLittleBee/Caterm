import XCTest
@testable import Caterm

final class CredKindTests: XCTestCase {
	func testAllCasesOrderAndCount() {
		XCTAssertEqual(CredKind.allCases, [.password, .keyFile, .agent])
	}

	func testDisplayNamesUseTitleCase() {
		XCTAssertEqual(
			CredKind.allCases.map(\.displayName),
			["Password", "Key File", "Agent"]
		)
	}

	func testRawValuesAreStable() {
		XCTAssertEqual(CredKind.password.rawValue, "password")
		XCTAssertEqual(CredKind.keyFile.rawValue, "key file")
		XCTAssertEqual(CredKind.agent.rawValue, "agent")
	}
}
