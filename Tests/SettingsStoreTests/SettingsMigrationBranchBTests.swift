import XCTest
@testable import SettingsStore

@MainActor
final class SettingsMigrationBranchBTests: XCTestCase {
    func testBranchB_representableSeededIntoPlistUserConfigUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        let original = """
            # my user config
            font-family = JetBrains Mono
            theme = Dracula
            """
        try original.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig, settings: &settings
        )
        XCTAssertEqual(result, .branchB(representable: 2, unrepresentable: 0))
        XCTAssertEqual(settings.global.fontFamily, "JetBrains Mono")
        XCTAssertEqual(settings.global.theme, "Dracula")
        // User config not modified yet
        XCTAssertEqual(try String(contentsOf: userConfig, encoding: .utf8), original)
    }

    func testFallbackChainKeptIntact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        let original = """
            font-family = SF Mono
            font-family = JetBrains Mono
            """
        try original.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        let result = try SettingsMigrationStep.runIfNeeded(
            userConfigPath: userConfig, settings: &settings
        )
        XCTAssertEqual(result, .branchB(representable: 0, unrepresentable: 1))
        XCTAssertEqual(try String(contentsOf: userConfig, encoding: .utf8), original)
        XCTAssertNil(settings.global.fontFamily)
    }

    func testImportRepresentableKeysClearsOnlyRepresentableLines() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let userConfig = dir.appendingPathComponent("config")
        let original = """
            font-family = SF Mono
            font-family = JetBrains Mono
            theme = Dracula
            palette = 0=#000000
            """
        try original.write(to: userConfig, atomically: true, encoding: .utf8)

        var settings = CatermSettings.empty
        _ = try SettingsMigrationStep.runIfNeeded(userConfigPath: userConfig, settings: &settings)

        try SettingsMigrationStep.importRepresentableKeys(userConfigPath: userConfig)
        let after = try String(contentsOf: userConfig, encoding: .utf8)
        // Fallback chain preserved
        XCTAssertTrue(after.contains("font-family = SF Mono"))
        XCTAssertTrue(after.contains("font-family = JetBrains Mono"))
        // palette preserved
        XCTAssertTrue(after.contains("palette = 0=#000000"))
        // representable theme line removed
        XCTAssertFalse(after.contains("theme = Dracula"))
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsMigrationBranchBTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
