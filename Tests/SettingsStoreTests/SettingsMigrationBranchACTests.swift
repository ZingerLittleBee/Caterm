import XCTest
@testable import SettingsStore

@MainActor
final class SettingsMigrationBranchACTests: XCTestCase {
    func testBranchA_legacyDefaultIsRecognized() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        try SettingsMigrationStep.legacyDefaultV1.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig,
            settings: &settings
        )
        XCTAssertEqual(result, .branchA)
        XCTAssertEqual(settings.global.fontFamily, "SF Mono")
        XCTAssertEqual(settings.global.fontSize, 13)
        XCTAssertEqual(settings.global.theme, "Catppuccin Mocha")
        XCTAssertEqual(settings.global.cursorStyle, .block)
        XCTAssertEqual(settings.global.titlebarStyle, .tabs)
        XCTAssertTrue(settings.migrationsCompleted.contains("settings-gui-v1"))

        // User config replaced with placeholder
        let after = try String(contentsOf: userConfig, encoding: .utf8)
        XCTAssertTrue(after.contains("# User overrides for Caterm"))
        XCTAssertFalse(after.contains("font-family"))

        // Backup created
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("config.bak-pre-settings-gui-") })
    }

    func testBranchC_missingUserConfigSeedsAndWritesPlaceholder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig,
            settings: &settings
        )
        XCTAssertEqual(result, .branchC)
        XCTAssertEqual(settings.global.titlebarStyle, .tabs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userConfig.path))
    }

    func testIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        try SettingsMigrationStep.legacyDefaultV1.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        _ = try SettingsMigrationStep.runIfNeeded(userConfigPath: userConfig, settings: &settings)
        let firstResult = settings
        let result2 = try SettingsMigrationStep.runIfNeeded(userConfigPath: userConfig, settings: &settings)
        XCTAssertEqual(result2, .alreadyCompleted)
        XCTAssertEqual(settings, firstResult)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsMigrationBranchACTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
