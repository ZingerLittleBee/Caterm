@testable import CatermMobileTerminal
import XCTest

final class MobileKnownHostsStoreTests: XCTestCase {
	private func tmp() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("kh-\(UUID().uuidString).json")
	}

	func testUnknownThenTrustThenTrusted() throws {
		let url = tmp()
		let s = MobileKnownHostsStore(fileURL: url)
		XCTAssertEqual(s.evaluate(endpoint: "h:22", fingerprint: "AAA"), .unknown)
		try s.trust(endpoint: "h:22", fingerprint: "AAA")
		XCTAssertEqual(s.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
		let s2 = MobileKnownHostsStore(fileURL: url)
		XCTAssertEqual(s2.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
	}

	func testMismatchAfterTrust() throws {
		let url = tmp()
		let s = MobileKnownHostsStore(fileURL: url)
		try s.trust(endpoint: "h:22", fingerprint: "AAA")
		XCTAssertEqual(s.evaluate(endpoint: "h:22", fingerprint: "BBB"), .mismatch)
	}
}
