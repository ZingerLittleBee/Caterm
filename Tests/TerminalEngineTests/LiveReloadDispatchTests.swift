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
        var appReloads = 0
        var configBuilds = 0
        let dispatcher = LiveReloadDispatcher(
            surfaceIds: { ["a", "b"] },
            applyToSurface: { refreshedSurfaces.append($0) },
            applyToApp: { appReloads += 1 },
            renderManagedSnapshot: { _ in },
            buildConfig: {
                configBuilds += 1
                return []
            }
        )
        dispatcher.handle(scope: .globalNewSurface, settings: CatermSettings.empty)
        XCTAssertEqual(refreshedSurfaces, [])
        XCTAssertEqual(appReloads, 0)
        XCTAssertEqual(configBuilds, 0)
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
