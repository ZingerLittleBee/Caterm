import XCTest
import SettingsStore
@testable import ConfigStore

@MainActor
final class PerHostPatchTests: XCTestCase {
    func testWritePerHostPatchCreatesFileWithThemeLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConfigStore.writePerHostPatch(
            theme: "Dracula",
            to: dir.appendingPathComponent("h1.config")
        )
        let content = try String(contentsOf: dir.appendingPathComponent("h1.config"), encoding: .utf8)
        XCTAssertEqual(content, "theme = Dracula\n")
    }

    func testRegenerateWritesAndPrunesStaleFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "theme = X\n".write(
            to: dir.appendingPathComponent("stale.config"),
            atomically: true, encoding: .utf8
        )
        var settings = CatermSettings.empty
        settings.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        settings.hostOverrides[HostId("h2")] = PartialSettings()

        try ConfigStore.regeneratePerHostPatches(from: settings, in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("h1.config").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("h2.config").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stale.config").path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerHostPatchTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
