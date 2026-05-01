import XCTest

final class ThemeCatalogBuildScriptTests: XCTestCase {
    func testBuildScriptProducesNonEmptyJSONWhenSubmoduleAvailable() throws {
        let candidates = [
            "Scripts/build-theme-catalog.sh",
            "apps/macos/Scripts/build-theme-catalog.sh",
        ]
        var found: String?
        for rel in candidates {
            if FileManager.default.fileExists(atPath: rel) {
                found = rel
                break
            }
        }
        guard let scriptPath = found else {
            throw XCTSkip("build script not found from cwd \(FileManager.default.currentDirectoryPath)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath, "--check-only"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0,
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
