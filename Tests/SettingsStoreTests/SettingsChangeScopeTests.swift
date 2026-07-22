import XCTest
@testable import SettingsStore

final class SettingsChangeScopeTests: XCTestCase {
    func testNoChangeReturnsNil() {
        let s = CatermSettings.empty
        XCTAssertNil(SettingsChangeScope.diff(old: s, new: s))
    }

    func testGlobalLiveWhenLiveFieldChanges() {
        var old = CatermSettings.empty
        var new = old
        old.global.fontSize = 13
        new.global.fontSize = 14
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }

    func testGlobalNewSurfaceWhenOnlyNewSurfaceFieldChanges() {
        var old = CatermSettings.empty
        var new = old
        old.global.scrollbackBytes = 10_000_000
        new.global.scrollbackBytes = 50_000_000
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalNewSurface)
    }

    func testWindowOpacityIsNewSurfaceOnlyOnMacOS() {
        var old = CatermSettings.empty
        var new = old
        old.global.windowOpacity = 1.0
        new.global.windowOpacity = 0.85
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalNewSurface)
    }

    func testGlobalLiveWhenBothLiveAndNewSurfaceChange() {
        var old = CatermSettings.empty
        var new = old
        old.global.fontSize = 13
        new.global.fontSize = 14
        new.global.titlebarStyle = .native
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }

    func testHostOverrideChangeProducesHostScope() {
        let old = CatermSettings.empty
        var new = old
        new.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        XCTAssertEqual(
            SettingsChangeScope.diff(old: old, new: new),
            .hostOverride(HostId("h1"))
        )
    }

    func testMixedGlobalAndHostChangePrioritizesGlobal() {
        let old = CatermSettings.empty
        var new = old
        new.global.fontSize = 14
        new.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }

    func testMobileKeyboardPreferenceChangeProducesNewSurfaceScope() {
        let old = CatermSettings.empty
        var new = old
        new.global.prefersNativeMobileKeyboard = true

        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalNewSurface)
    }

    func testUnknownTopLevelFieldChangeProducesNewSurfaceScope() {
        let old = CatermSettings.empty
        var new = old
        new.unknownFields["futurePlatformPolicy"] = .string("retain")

        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalNewSurface)
    }

    func testUnknownNestedFieldChangeProducesNewSurfaceScope() {
        let old = CatermSettings.empty
        var new = old
        new.global.unknownFields["futureTerminalOption"] = .bool(true)

        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalNewSurface)
    }
}
