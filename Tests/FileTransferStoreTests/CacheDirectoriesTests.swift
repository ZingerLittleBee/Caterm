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
}
