import XCTest
import SettingsStore
@testable import ConfigStore

@MainActor
final class ConfigStoreSnapshotTests: XCTestCase {
    func testRenderManagedSnapshotWritesAtomicallyAndIdempotent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var s = PartialSettings()
        s.fontFamily = "SF Mono"
        s.theme = "Dracula"
        let target = tmp.appendingPathComponent("managed.config")

        try ConfigStore.renderManagedSnapshot(from: s, to: target)
        let first = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(first.contains("font-family = SF Mono"))
        XCTAssertTrue(first.contains("theme = Dracula"))

        let mtime1 = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        try ConfigStore.renderManagedSnapshot(from: s, to: target)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime1, mtime2)
    }

    func testPerHostPatchPathInApplicationSupport() {
        let url = ConfigStore.perHostPatchPath(for: HostId("abc-123"))
        XCTAssertTrue(url.path.contains("/Application Support/Caterm/per-host/abc-123.config"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigStoreSnapshotTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
