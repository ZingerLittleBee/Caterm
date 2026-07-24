import XCTest
@testable import FileTransferStore

final class CacheDirectoriesTests: XCTestCase {
	func testControlMasterDirIsCreatedInsideSuppliedTemporaryRoot() throws {
		let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
			.appendingPathComponent("cm-\(UUID().uuidString.prefix(8))")
		defer { try? FileManager.default.removeItem(at: root) }

		let dir = try CacheDirectories.controlMasterDir(root: root)

		XCTAssertEqual(
			dir,
			root.appendingPathComponent("caterm-cm", isDirectory: true)
		)
		XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
		let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
		XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o700)
	}

	func testRelativeSocketNameLeavesRoomForOpenSSHTemporarySocket() throws {
		let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
			.appendingPathComponent("cm-\(UUID().uuidString.prefix(8))")
		let dir = try CacheDirectories.controlMasterDir(root: root)
		defer { try? FileManager.default.removeItem(at: root) }

		let socketName =
			String(repeating: "a", count: CacheDirectories.socketTokenBytes)
			+ ".sock"

		XCTAssertEqual(
			dir,
			root.appendingPathComponent("caterm-cm", isDirectory: true)
		)
		XCTAssertLessThanOrEqual(
			socketName.utf8.count + CacheDirectories.openSSHTemporarySuffixBytes,
			CacheDirectories.unixSocketPathMaxBytes
		)
	}

	func testLongTemporaryRootIsSupportedByRelativeSocketNames() throws {
		let root = URL(
			fileURLWithPath: "/tmp/" + String(repeating: "x", count: 80),
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: root) }

		let directory = try CacheDirectories.controlMasterDir(root: root)

		XCTAssertEqual(
			directory,
			root.appendingPathComponent("caterm-cm", isDirectory: true)
		)
	}
}
