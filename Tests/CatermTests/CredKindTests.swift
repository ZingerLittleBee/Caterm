import XCTest
@testable import Caterm

final class CredKindTests: XCTestCase {
	func testAllCasesOrderAndCount() {
		// `.agent` was removed in v1.7 — agent auth could never succeed in a
		// Finder-launched .app (no inherited SSH_AUTH_SOCK).
		XCTAssertEqual(CredKind.allCases, [.password, .keyFile])
	}

	func testDisplayNamesUseTitleCase() {
		XCTAssertEqual(
			CredKind.allCases.map(\.displayName),
			["Password", "Key File"]
		)
	}

	func testRawValuesAreStable() {
		XCTAssertEqual(CredKind.password.rawValue, "password")
		XCTAssertEqual(CredKind.keyFile.rawValue, "key file")
	}
}
