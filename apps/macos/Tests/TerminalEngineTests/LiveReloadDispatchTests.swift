import XCTest
import SettingsStore
@testable import TerminalEngine

@MainActor
final class LiveReloadDispatchTests: XCTestCase {
    func testGlobalLiveScopeDispatchesToAllSurfaces() throws {
        var refreshedSurfaces: [String] = []
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a", "b", "c"] },
            applyToSurface: { id in refreshedSurfaces.append(id) },
            applyToApp: { /* ignore */ },
            renderManagedSnapshot: { _ in },
            buildConfig: { ConfigDiagnostic.collect(rawCount: 0, fetch: { _ in nil }) }
        )
        dispatcher.handle(scope: .globalLive, settings: CatermSettings.empty)
        XCTAssertEqual(refreshedSurfaces.sorted(), ["a", "b", "c"])
    }

    func testGlobalNewSurfaceDoesNotRefreshExisting() {
        var refreshedSurfaces: [String] = []
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a", "b"] },
            applyToSurface: { refreshedSurfaces.append($0) },
            applyToApp: { },
            renderManagedSnapshot: { _ in },
            buildConfig: { [] }
        )
        dispatcher.handle(scope: .globalNewSurface, settings: CatermSettings.empty)
        XCTAssertEqual(refreshedSurfaces, [])
    }

    func testHostOverrideDoesNotRefreshExisting() {
        var refreshedSurfaces: [String] = []
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a"] },
            applyToSurface: { refreshedSurfaces.append($0) },
            applyToApp: { },
            renderManagedSnapshot: { _ in },
            buildConfig: { [] }
        )
        dispatcher.handle(
            scope: .hostOverride(HostId("h")),
            settings: CatermSettings.empty
        )
        XCTAssertEqual(refreshedSurfaces, [])
    }
}
