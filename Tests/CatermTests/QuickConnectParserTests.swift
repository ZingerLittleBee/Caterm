import XCTest
@testable import Caterm

final class QuickConnectParserTests: XCTestCase {
	func testParseUserAndHostnameUsesDefaultSSHPort() {
		XCTAssertEqual(
			QuickConnectParser.parse("alice@example.com"),
			QuickConnectDestination(
				username: "alice",
				hostname: "example.com",
				port: 22
			)
		)
	}

	func testParseSSHCommandWithPortOption() {
		XCTAssertEqual(
			QuickConnectParser.parse("ssh alice@example.com -p 2202"),
			QuickConnectDestination(
				username: "alice",
				hostname: "example.com",
				port: 2202
			)
		)
	}

	func testParseSSHCommandWithLeadingPortOption() {
		XCTAssertEqual(
			QuickConnectParser.parse("ssh -p 2202 alice@example.com"),
			QuickConnectDestination(
				username: "alice",
				hostname: "example.com",
				port: 2202
			)
		)
	}

	func testParseCompactDestinationWithPort() {
		XCTAssertEqual(
			QuickConnectParser.parse("alice@example.com:2202"),
			QuickConnectDestination(
				username: "alice",
				hostname: "example.com",
				port: 2202
			)
		)
	}

	func testParseRejectsPortsOutsideTCPRange() {
		XCTAssertNil(QuickConnectParser.parse("alice@example.com:0"))
		XCTAssertNil(QuickConnectParser.parse("ssh alice@example.com -p 65536"))
	}

	func testParseBracketedIPv6WithPort() {
		XCTAssertEqual(
			QuickConnectParser.parse("alice@[2001:db8::1]:2202"),
			QuickConnectDestination(
				username: "alice",
				hostname: "2001:db8::1",
				port: 2202
			)
		)
	}

	func testParseRejectsMalformedOrUnsupportedInput() {
		XCTAssertNil(QuickConnectParser.parse("alice@example.com:not-a-port"))
		XCTAssertNil(QuickConnectParser.parse("alice@example.com@other.example"))
		XCTAssertNil(QuickConnectParser.parse("ssh -v alice@example.com"))
		XCTAssertNil(QuickConnectParser.parse("example.com"))
	}

	func testDestinationBuildsTransientHostAndDisplayAddress() {
		let destination = QuickConnectDestination(
			username: "alice",
			hostname: "2001:db8::1",
			port: 2202
		)

		let host = destination.makeHost()

		XCTAssertEqual(destination.displayAddress, "alice@[2001:db8::1]:2202")
		XCTAssertEqual(host.name, "2001:db8::1")
		XCTAssertEqual(host.hostname, "2001:db8::1")
		XCTAssertEqual(host.username, "alice")
		XCTAssertEqual(host.port, 2202)
		XCTAssertEqual(host.credential, .agent)
	}
}
