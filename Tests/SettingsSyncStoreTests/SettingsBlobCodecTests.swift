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

	func test_roundTrip_preservesPlatformAndUnknownFutureFields() throws {
		var settings = CatermSettings()
		settings.version = 2
		settings.revision = "future-compatible"
		settings.global = PartialSettings(
			fontSize: 15,
			windowOpacity: 0.82,
			titlebarStyle: .transparent,
			theme: "Nord",
			prefersNativeMobileKeyboard: true
		)
		settings.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		let baseline = try SettingsBlobCodec.encode(settings)
		var raw = try XCTUnwrap(
			PropertyListSerialization.propertyList(
				from: baseline,
				options: [],
				format: nil
			) as? [String: Any]
		)
		raw["futureTopLevel"] = ["enabled": true, "generation": 4]
		var global = try XCTUnwrap(raw["global"] as? [String: Any])
		global["futureTerminalFeature"] = ["mode": "adaptive", "levels": [1, 2, 3]]
		raw["global"] = global
		let futureBlob = try PropertyListSerialization.data(
			fromPropertyList: raw,
			format: .binary,
			options: 0
		)

		let decoded = try SettingsBlobCodec.decode(futureBlob)
		var local = decoded.toLocal(localMigrationsCompleted: ["device-only"])
		local.global.fontSize = 17
		let roundTripped = try SettingsBlobCodec.encode(local)
		let result = try XCTUnwrap(
			PropertyListSerialization.propertyList(
				from: roundTripped,
				options: [],
				format: nil
			) as? [String: Any]
		)
		let resultGlobal = try XCTUnwrap(result["global"] as? [String: Any])

		XCTAssertEqual(resultGlobal["fontSize"] as? Int, 17)
		XCTAssertEqual(resultGlobal["windowOpacity"] as? Double, 0.82)
		XCTAssertEqual(resultGlobal["titlebarStyle"] as? String, "transparent")
		XCTAssertEqual(resultGlobal["prefersNativeMobileKeyboard"] as? Bool, true)
		XCTAssertNotNil(result["futureTopLevel"])
		XCTAssertNotNil(resultGlobal["futureTerminalFeature"])
		XCTAssertNil(result["migrationsCompleted"])
	}
}
