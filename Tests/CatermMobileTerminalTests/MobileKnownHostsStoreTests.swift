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
		XCTAssertEqual(try s.evaluate(endpoint: "h:22", fingerprint: "AAA"), .unknown)
		try s.trust(endpoint: "h:22", fingerprint: "AAA")
		XCTAssertEqual(try s.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
		let s2 = MobileKnownHostsStore(fileURL: url)
		XCTAssertEqual(try s2.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
	}

	func testMismatchAfterTrust() throws {
		let url = tmp()
		let s = MobileKnownHostsStore(fileURL: url)
		try s.trust(endpoint: "h:22", fingerprint: "AAA")
		XCTAssertEqual(try s.evaluate(endpoint: "h:22", fingerprint: "BBB"), .mismatch)
	}

	func testConcurrentStoreCannotOverwriteDifferentTrustedKey() throws {
		let url = tmp()
		let first = MobileKnownHostsStore(fileURL: url)
		let second = MobileKnownHostsStore(fileURL: url)
		XCTAssertEqual(try first.evaluate(endpoint: "h:22", fingerprint: "AAA"), .unknown)
		XCTAssertEqual(try second.evaluate(endpoint: "h:22", fingerprint: "BBB"), .unknown)

		try first.trust(endpoint: "h:22", fingerprint: "AAA")

		XCTAssertThrowsError(
			try second.trust(endpoint: "h:22", fingerprint: "BBB")
		) { error in
			XCTAssertEqual(
				error as? MobileKnownHostsError,
				.concurrentKeyChange(endpoint: "h:22")
			)
		}
		XCTAssertEqual(try second.evaluate(endpoint: "h:22", fingerprint: "AAA"), .trusted)
	}

	func testFailedPersistenceDoesNotPublishCandidateAsTrusted() throws {
		struct WriteFailure: Error {}
		let url = tmp()
		let store = MobileKnownHostsStore(fileURL: url) { _, _ in
			throw WriteFailure()
		}

		XCTAssertThrowsError(
			try store.trust(endpoint: "h:22", fingerprint: "AAA")
		)
		XCTAssertEqual(
			try store.evaluate(endpoint: "h:22", fingerprint: "AAA"),
			.unknown
		)
	}

	func testCorruptKnownHostsFailsClosed() throws {
		let url = tmp()
		try Data("not-json".utf8).write(to: url)
		let store = MobileKnownHostsStore(fileURL: url)

		XCTAssertThrowsError(
			try store.evaluate(endpoint: "h:22", fingerprint: "AAA")
		) { error in
			XCTAssertEqual(
				error as? MobileKnownHostsError,
				.invalidData(path: url.path)
			)
		}
	}
}
