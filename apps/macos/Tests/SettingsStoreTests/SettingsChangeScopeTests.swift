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

    func testGlobalLiveWhenBothLiveAndNewSurfaceChange() {
        var old = CatermSettings.empty
        var new = old
        old.global.fontSize = 13
        new.global.fontSize = 14
        new.global.titlebarStyle = .native
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }

    func testHostOverrideChangeProducesHostScope() {
        var old = CatermSettings.empty
        var new = old
        new.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        XCTAssertEqual(
            SettingsChangeScope.diff(old: old, new: new),
            .hostOverride(HostId("h1"))
        )
    }

    func testMixedGlobalAndHostChangePrioritizesGlobal() {
        var old = CatermSettings.empty
        var new = old
        new.global.fontSize = 14
        new.hostOverrides[HostId("h1")] = PartialSettings(theme: "Dracula")
        XCTAssertEqual(SettingsChangeScope.diff(old: old, new: new), .globalLive)
    }
}
