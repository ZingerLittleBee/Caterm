import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class SettingsBlobCodecTests: XCTestCase {
    func test_roundTrip_preservesAllSyncableFields() throws {
        var s = CatermSettings()
        s.version = 2
        s.revision = "rev-x"
        s.global = CatermSettings.defaultsSeed
        s.hostOverrides = [HostId("h"): PartialSettings(fontSize: 16)]
        s.migrationsCompleted = ["settings-gui-v1"]   // local-only — must NOT be in blob
        s.seedVersion = 1
        s.seededByDefault = true
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1_700_000_000)
        s.canonicalSeedHash = "hash"

        let blob = try SettingsBlobCodec.encode(s)
        let decoded = try SettingsBlobCodec.decode(blob)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.revision, "rev-x")
        XCTAssertEqual(decoded.global, s.global)
        XCTAssertEqual(decoded.hostOverrides, s.hostOverrides)
        XCTAssertEqual(decoded.seedVersion, 1)
        XCTAssertTrue(decoded.seededByDefault)
        XCTAssertEqual(decoded.firstUserEditedAt, s.firstUserEditedAt)
        XCTAssertEqual(decoded.canonicalSeedHash, "hash")
    }

    func test_blob_doesNotContainMigrationsCompleted() throws {
        var s = CatermSettings()
        s.migrationsCompleted = ["secret-marker"]
        let blob = try SettingsBlobCodec.encode(s)
        let raw = String(data: blob, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("secret-marker"),
            "blob must not leak local-only migrationsCompleted")
        XCTAssertFalse(raw.contains("migrationsCompleted"))
    }

    func test_decode_corruptedBlob_throws() {
        XCTAssertThrowsError(try SettingsBlobCodec.decode(Data([0xFF, 0x00])))
    }

    func test_decode_emptyData_throws() {
        XCTAssertThrowsError(try SettingsBlobCodec.decode(Data()))
    }
}
