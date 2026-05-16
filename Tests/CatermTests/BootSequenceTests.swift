import XCTest
import ConfigStore
import SettingsStore
@testable import Caterm

@MainActor
final class BootSequenceTests: XCTestCase {
    func testBootSeedsFromLegacyDefaultAndRegeneratesPatches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        try SettingsMigrationStep.legacyDefaultV1.write(
            to: userConfig, atomically: true, encoding: .utf8
        )

        let plistURL = dir.appendingPathComponent("settings.plist")
        let perHostDir = dir.appendingPathComponent("per-host")

        let store = try BootSequence.run(
            settingsPlistURL: plistURL,
            userConfigURL: userConfig,
            managedSnapshotURL: dir.appendingPathComponent("managed.config"),
            perHostDirectory: perHostDir
        )

        XCTAssertTrue(store.settings.migrationsCompleted.contains(SettingsMigrationStep.token))
        XCTAssertEqual(store.settings.global.theme, "Catppuccin Mocha")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("managed.config").path))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootSequenceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
