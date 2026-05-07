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

	func testFormFeedThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\u{0C}b")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testVerticalTabThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\u{0B}b")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testEscapeByteThrowsControlCharacter() {
		// 0x1B (ESC) is a C0 control. Common in terminal escape sequences;
		// must not be smuggled into ssh_config values.
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\u{1B}[31mb")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testTabAloneIsQuotedNotRejected() throws {
		// Tab is a legal whitespace inside quoted ssh_config values.
		// It must not throw and must trigger quoting.
		XCTAssertEqual(try SSHConfigQuote.encode("\t"), "\"\t\"")
	}

	func testValueWithLeadingAndTrailingSpaceIsQuoted() throws {
		XCTAssertEqual(try SSHConfigQuote.encode(" abc "), "\" abc \"")
	}

	func testWhitespaceOnlyValueIsQuoted() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("   "), "\"   \"")
	}

	func testQuoteOnlyValueIsEscaped() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("\""), "\"\\\"\"")
	}

	func testBackslashOnlyValueIsEscaped() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("\\"), "\"\\\\\"")
	}

	func testLargeAsciiHostnamePassesThrough() throws {
		// Defensive: ssh_config historically had static buffer limits.
		// Modern OpenSSH is dynamic but a smoke test is cheap insurance.
		let big = String(repeating: "a", count: 4096)
		XCTAssertEqual(try SSHConfigQuote.encode(big), big)
	}
}
