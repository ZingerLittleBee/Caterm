import XCTest

@testable import ConfigStore

final class ConfigStoreTests: XCTestCase {
	var tmpURL: URL!
	override func setUp() {
		tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-cfg-\(UUID()).conf")
	}
	override func tearDown() { try? FileManager.default.removeItem(at: tmpURL) }

	func testWritesDefaultOnFirstLaunch() throws {
		XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
		try ConfigStore.ensureExists(at: tmpURL)
		XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
		let contents = try String(contentsOf: tmpURL)
		XCTAssertTrue(contents.contains("font-family"))
	}

	func testDoesNotOverwriteExisting() throws {
		try "custom-content".write(to: tmpURL, atomically: true, encoding: .utf8)
		try ConfigStore.ensureExists(at: tmpURL)
		XCTAssertEqual(try String(contentsOf: tmpURL), "custom-content")
	}

	func testFilePermissionsAre0644() throws {
		try ConfigStore.ensureExists(at: tmpURL)
		let attrs = try FileManager.default.attributesOfItem(atPath: tmpURL.path)
		XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o644)
	}
}
