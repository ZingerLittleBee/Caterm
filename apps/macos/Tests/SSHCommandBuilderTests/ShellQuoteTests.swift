import XCTest
@testable import SSHCommandBuilder

final class ShellQuoteTests: XCTestCase {
    func testEmptyString() {
        XCTAssertEqual(ShellQuote.posix(""), "''")
    }

    func testSimpleAlphanumeric() {
        XCTAssertEqual(ShellQuote.posix("hello"), "'hello'")
    }

    func testStringWithSpaces() {
        XCTAssertEqual(ShellQuote.posix("hello world"), "'hello world'")
    }

    func testSingleQuoteEscape() {
        // POSIX: ' → '\''
        XCTAssertEqual(ShellQuote.posix("it's"), "'it'\\''s'")
    }

    func testDollarSignNotInterpolated() {
        // Inside single quotes, $ is literal
        XCTAssertEqual(ShellQuote.posix("$HOME"), "'$HOME'")
    }

    func testBackticksLiteral() {
        XCTAssertEqual(ShellQuote.posix("`whoami`"), "'`whoami`'")
    }

    func testCommandSubstitutionLiteral() {
        XCTAssertEqual(ShellQuote.posix("$(rm -rf /)"), "'$(rm -rf /)'")
    }

    func testSemicolonLiteral() {
        XCTAssertEqual(ShellQuote.posix("a;b"), "'a;b'")
    }

    func testNewline() {
        XCTAssertEqual(ShellQuote.posix("a\nb"), "'a\nb'")
    }

    func testUnicode() {
        XCTAssertEqual(ShellQuote.posix("café"), "'café'")
    }

    func testMultipleSingleQuotes() {
        XCTAssertEqual(ShellQuote.posix("'a''b'"), "''\\''a'\\'''\\''b'\\'''")
    }
}
