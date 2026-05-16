import XCTest
@testable import SettingsStore

final class V1ToV2MigrationTests: XCTestCase {
    private func writeV1Plist(_ s: CatermSettings, to path: URL) throws {
        // Force-encode with version=1 to simulate an on-disk v1 plist
        var v1 = s
        v1.version = 1
        v1.seedVersion = 0
        v1.seededByDefault = false
        v1.firstUserEditedAt = nil
        v1.canonicalSeedHash = ""
        let data = try PropertyListEncoder().encode(v1)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: path)
    }

    @MainActor
    func test_v1_exactDefaultSeed_becomesSeededByDefaultTrue() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var v1 = CatermSettings()
        v1.global = CatermSettings.defaultsSeed
        v1.hostOverrides = [:]
        try writeV1Plist(v1, to: tmp)

        let store = try SettingsStore.load(from: tmp)
        XCTAssertEqual(store.settings.version, 2)
        XCTAssertTrue(store.settings.seededByDefault, "exact-defaults v1 plist must migrate as seeded")
        XCTAssertNil(store.settings.firstUserEditedAt)
        XCTAssertEqual(store.settings.seedVersion, 1)
        XCTAssertFalse(store.settings.canonicalSeedHash.isEmpty)
    }

    @MainActor
    func test_v1_edited_becomesSeededByDefaultFalse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var v1 = CatermSettings()
        v1.global = CatermSettings.defaultsSeed
        v1.global.fontSize = 18  // user edit
        v1.hostOverrides = [:]
        try writeV1Plist(v1, to: tmp)

        let store = try SettingsStore.load(from: tmp)
        XCTAssertEqual(store.settings.version, 2)
        XCTAssertFalse(store.settings.seededByDefault)
        XCTAssertNotNil(store.settings.firstUserEditedAt, "edited v1 user must be marked as having edited")
        XCTAssertEqual(store.settings.canonicalSeedHash, "",
            "edited v1 user gets empty hash so isDefaultSeedUnedited can never accidentally fire")
    }

    @MainActor
    func test_v1_withHostOverride_becomesSeededByDefaultFalse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var v1 = CatermSettings()
        v1.global = CatermSettings.defaultsSeed
        v1.hostOverrides = [HostId("host-1"): PartialSettings(fontSize: 16)]
        try writeV1Plist(v1, to: tmp)

        let store = try SettingsStore.load(from: tmp)
        XCTAssertFalse(store.settings.seededByDefault)
    }
}
