import XCTest
@testable import Caterm
@testable import SessionStore
@testable import SSHCommandBuilder

final class FailurePresentationTests: XCTestCase {
	private func host(port: Int = 22) -> SSHHost {
		SSHHost(name: "h", hostname: "example.com", port: port,
		        username: "u", credential: .password)
	}

	func testDnsFailedTitleAndDetailUseHostname() {
		let p = FailurePresentation.from(failure: .networkUnreachable(.dnsFailed),
		                                 host: host())
		XCTAssertEqual(p.icon, .orange)
		XCTAssertEqual(p.title, "Host not found")
		XCTAssertTrue(p.detail?.contains("example.com") ?? false)
	}

	func testConnectionRefusedMentionsPort() {
		let p = FailurePresentation.from(failure: .networkUnreachable(.connectionRefused),
		                                 host: host(port: 2222))
		XCTAssertEqual(p.title, "Connection refused")
		XCTAssertTrue(p.detail?.contains("2222") ?? false)
	}

	func testTimedOutMentionsHostAndPort() {
		let p = FailurePresentation.from(failure: .networkUnreachable(.timedOut),
		                                 host: host(port: 22))
		XCTAssertEqual(p.title, "Connection timed out")
		XCTAssertTrue(p.detail?.contains("example.com") ?? false)
		XCTAssertTrue(p.detail?.contains("22") ?? false)
	}

	func testInvalidPortIsRedAndShowsValue() {
		let p = FailurePresentation.from(failure: .networkUnreachable(.invalidPort(99999)),
		                                 host: host(port: 99999))
		XCTAssertEqual(p.icon, .red)
		XCTAssertEqual(p.title, "Invalid port")
		XCTAssertTrue(p.detail?.contains("99999") ?? false)
	}

	func testAuthFail() {
		let p = FailurePresentation.from(failure: .authOrSetupFail, host: host())
		XCTAssertEqual(p.icon, .red)
		XCTAssertEqual(p.title, "Authentication failed")
	}
}
