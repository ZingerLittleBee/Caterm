import XCTest
@testable import TerminalEngine

final class ShellEscapeTests: XCTestCase {
	func testNoSpecialChars() {
		XCTAssertEqual(shellEscape("/Users/alice/file.txt"), "'/Users/alice/file.txt'")
	}

	func testEmbeddedSpace() {
		XCTAssertEqual(shellEscape("/Users/alice/My Doc.pdf"), "'/Users/alice/My Doc.pdf'")
	}

	func testEmbeddedSingleQuote() {
		XCTAssertEqual(shellEscape("/tmp/it's a file"), "'/tmp/it'\\''s a file'")
	}

	func testJoinPaths() {
		let joined = ["/a/b", "/c/d e"].map(shellEscape).joined(separator: " ")
		XCTAssertEqual(joined, "'/a/b' '/c/d e'")
	}
}
