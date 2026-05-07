import XCTest
@testable import SSHCommandBuilder

final class SSHConfigQuoteTests: XCTestCase {
	func testPlainAsciiPassesThroughUnchanged() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("example.com"), "example.com")
		XCTAssertEqual(try SSHConfigQuote.encode("user"), "user")
		XCTAssertEqual(try SSHConfigQuote.encode("/Users/u/.ssh/key"),
		               "/Users/u/.ssh/key")
	}

	func testValueWithSpaceIsDoubleQuoted() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("hello world"),
		               "\"hello world\"")
	}

	func testValueWithDoubleQuoteIsEscaped() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("a\"b"),
		               "\"a\\\"b\"")
	}

	func testValueWithBackslashIsEscaped() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("a\\b"),
		               "\"a\\\\b\"")
	}

	func testValueWithBackslashAndQuoteEscapesBoth() throws {
		// Input: a\"b (a, backslash, quote, b)
		// Output: "a\\\"b"  (wrapped, \\\\, \\", literal a/b)
		XCTAssertEqual(try SSHConfigQuote.encode("a\\\"b"),
		               "\"a\\\\\\\"b\"")
	}

	func testEmptyStringYieldsEmptyQuotedPair() throws {
		// An empty value still needs to render as a token — `""`.
		XCTAssertEqual(try SSHConfigQuote.encode(""), "\"\"")
	}

	func testUnicodePassesThroughUnchanged() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("hôst-1"), "hôst-1")
	}

	func testNewlineThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\nb")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testCarriageReturnThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\rb")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testNullThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\0b")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}
}
