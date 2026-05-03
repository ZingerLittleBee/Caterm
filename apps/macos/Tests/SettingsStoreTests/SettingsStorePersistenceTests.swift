import XCTest
@testable import SettingsStore

@MainActor
final class SettingsStorePersistenceTests: XCTestCase {
    func testLoadAbsentFileReturnsSeededDefaults() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        XCTAssertEqual(store.settings.global.fontFamily, "SF Mono")
        XCTAssertEqual(store.settings.global.theme, "Catppuccin Mocha")
    }

    func testRoundTripPersists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.plist")
        let store = try SettingsStore.load(from: path)
        var s = store.settings
        s.global.fontSize = 17
        try store.save(s)

        let store2 = try SettingsStore.load(from: path)
        XCTAssertEqual(store2.settings.global.fontSize, 17)
    }

    func testCorruptedPlistQuarantinedAndDefaultsSeeded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.plist")
        try "not a plist".write(to: path, atomically: true, encoding: .utf8)

        let store = try SettingsStore.load(from: path)
        XCTAssertEqual(store.settings.global.theme, "Catppuccin Mocha")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("settings.plist.broken-") })
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStorePersistenceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class CatermSettingsV2SchemaTests: XCTestCase {
    func test_defaultInit_hasV2FieldsWithSafeDefaults() {
        let s = CatermSettings()
        XCTAssertEqual(s.version, 2, "schema bumped to v2")
        XCTAssertEqual(s.seedVersion, 0, "0 = not yet seeded")
        XCTAssertFalse(s.seededByDefault)
        XCTAssertNil(s.firstUserEditedAt)
        XCTAssertEqual(s.canonicalSeedHash, "")
    }

    func test_codable_roundTrip_preservesAllFields() throws {
        var s = CatermSettings()
        s.seedVersion = 1
        s.seededByDefault = true
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1_700_000_000)
        s.canonicalSeedHash = "deadbeef"
        let data = try PropertyListEncoder().encode(s)
        let decoded = try PropertyListDecoder().decode(CatermSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
