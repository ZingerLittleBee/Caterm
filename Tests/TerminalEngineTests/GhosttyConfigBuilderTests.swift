import XCTest
@testable import TerminalEngine

@MainActor
final class GhosttyConfigBuilderTests: XCTestCase {
    func testBuilderRecordsLoadOrder() {
        var loaded: [String] = []
        let builder = GhosttyConfigBuilder(loadDefaults: { loaded.append("defaults") },
                                           loadFile: { loaded.append("file:\($0)") },
                                           finalize: { loaded.append("finalize") },
                                           diagnosticsCount: { 0 },
                                           getDiagnostic: { _ in "" })
        _ = builder.build(
            managedPath: "/tmp/managed.config",
            userPath: "/tmp/user.config",
            perHostPath: "/tmp/h1.config"
        )
        XCTAssertEqual(loaded, [
            "defaults",
            "file:/tmp/managed.config",
            "file:/tmp/user.config",
            "file:/tmp/h1.config",
            "finalize",
        ])
    }

    func testBuildSurfacesDiagnostics() {
        let builder = GhosttyConfigBuilder(
            loadDefaults: {},
            loadFile: { _ in },
            finalize: {},
            diagnosticsCount: { 2 },
            getDiagnostic: { i in i == 0 ? "warning: a" : "warning: b" }
        )
        let result = builder.build(managedPath: "/tmp/m", userPath: nil, perHostPath: nil)
        XCTAssertEqual(result.diagnostics.map(\.message), ["warning: a", "warning: b"])
    }
}

extension GhosttyConfigBuilderTests {
    func testHostScopedConfigIncludesPerHostPath() {
        var loaded: [String] = []
        let builder = GhosttyConfigBuilder(
            loadDefaults: { loaded.append("defaults") },
            loadFile: { loaded.append($0) },
            finalize: { loaded.append("finalize") },
            diagnosticsCount: { 0 },
            getDiagnostic: { _ in "" }
        )
        _ = builder.build(
            managedPath: "/tmp/m",
            userPath: "/tmp/u",
            perHostPath: "/tmp/per-host/h.config"
        )
        XCTAssertTrue(loaded.contains("/tmp/per-host/h.config"))
        let userIdx = loaded.firstIndex(of: "/tmp/u")!
        let hostIdx = loaded.firstIndex(of: "/tmp/per-host/h.config")!
        XCTAssertLessThan(userIdx, hostIdx)
    }
}
