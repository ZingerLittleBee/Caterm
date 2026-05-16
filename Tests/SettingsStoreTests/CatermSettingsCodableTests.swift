import XCTest
@testable import SettingsStore

final class CatermSettingsCodableTests: XCTestCase {
    func testRoundTrip() throws {
        var s = CatermSettings.empty
        s.global.fontFamily = "SF Mono"
        s.global.fontSize = 13
        s.global.cursorStyle = .block
        s.global.bell = .visual
        s.global.scrollbackBytes = 10_000_000
        s.global.titlebarStyle = .tabs
        s.global.theme = "Catppuccin Mocha"
        s.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        s.migrationsCompleted.insert("settings-gui-v1")
        let data = try PropertyListEncoder().encode(s)
        let decoded = try PropertyListDecoder().decode(CatermSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func testEmptyDefaults() {
        XCTAssertEqual(CatermSettings.empty.version, 2)
        XCTAssertTrue(CatermSettings.empty.global == PartialSettings())
        XCTAssertTrue(CatermSettings.empty.hostOverrides.isEmpty)
        XCTAssertTrue(CatermSettings.empty.migrationsCompleted.isEmpty)
    }
}
