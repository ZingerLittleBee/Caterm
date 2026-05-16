import XCTest

@testable import TerminalEngine

final class URLSchemeTests: XCTestCase {
	func testWhitelistedSchemes() {
		for s in ["http", "https", "mailto", "ssh", "ftp", "ftps"] {
			XCTAssertTrue(isSafeURLScheme(s), "expected \(s) to be allowed")
		}
	}

	func testCaseInsensitive() {
		XCTAssertTrue(isSafeURLScheme("HTTPS"))
		XCTAssertTrue(isSafeURLScheme("Mailto"))
	}

	func testRejectedSchemes() {
		for s in ["file", "x-apple-data-detectors", "javascript", "data", "smb"] {
			XCTAssertFalse(isSafeURLScheme(s), "expected \(s) to be rejected")
		}
	}
}
