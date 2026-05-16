import XCTest
@testable import TerminalEngine

final class ConfigDiagnosticTests: XCTestCase {
    func testParseMessageOnly() {
        let d = ConfigDiagnostic(message: "unknown key: foo-bar")
        XCTAssertEqual(d.message, "unknown key: foo-bar")
    }

    func testEmptyArrayWhenNoDiagnostics() {
        let result = ConfigDiagnostic.collect(rawCount: 0, fetch: { _ in nil })
        XCTAssertTrue(result.isEmpty)
    }

    func testCollectsAllDiagnostics() {
        let messages = ["one", "two", "three"]
        let result = ConfigDiagnostic.collect(rawCount: 3) { i in messages[Int(i)] }
        XCTAssertEqual(result.map(\.message), messages)
    }
}
