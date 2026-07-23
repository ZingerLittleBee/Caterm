import XCTest
@testable import FileTransferStore

final class CacheDirectoriesTests: XCTestCase {
    func testControlMasterDirIsCreated() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-cm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = try CacheDirectories.controlMasterDir(root: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o700)
    }

	func testProductionLayoutLeavesRoomForOpenSSHTemporarySocket() throws {
		let userID: UInt32 = 4_294_967_294
		let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
		let dir = try CacheDirectories.controlMasterDir(
			root: root,
			userID: userID
		)
		defer { try? FileManager.default.removeItem(at: dir) }
		let hostID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
		let socketPath = dir
			.appendingPathComponent("\(hostID.uuidString).sock")
			.path

		XCTAssertEqual(dir.path, "/tmp/caterm-cm-\(userID)")
		XCTAssertLessThanOrEqual(
			socketPath.utf8.count + CacheDirectories.openSSHTemporarySuffixBytes,
			CacheDirectories.unixSocketPathMaxBytes
		)
	}
}
