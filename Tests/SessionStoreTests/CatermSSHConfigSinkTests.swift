import XCTest
import SSHCommandBuilder
@testable import SessionStore

final class CatermSSHConfigSinkTests: XCTestCase {
	func testWriteAndCleanupRoundTrip() throws {
		let sink = CatermSSHConfigSink()
		let url = try sink.write("Host *\n\tPort 22\n")
		// File must exist.
		XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
		// Mode must be 0600.
		let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
		let perms = attrs[.posixPermissions] as? NSNumber
		XCTAssertEqual(perms?.intValue, 0o600,
		               "config file must be mode 0600")
		// Contents round-trip.
		let read = try String(contentsOf: url)
		XCTAssertEqual(read, "Host *\n\tPort 22\n")
		// Cleanup removes it.
		sink.cleanup(url)
		XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
	}

	func testCleanupOnMissingFileDoesNotCrash() {
		let sink = CatermSSHConfigSink()
		let url = URL(fileURLWithPath: "/tmp/caterm-nonexistent-\(UUID().uuidString)")
		// Must not throw / crash.
		sink.cleanup(url)
	}
}
