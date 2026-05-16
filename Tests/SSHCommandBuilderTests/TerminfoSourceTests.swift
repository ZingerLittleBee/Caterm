import XCTest
@testable import SSHCommandBuilder

final class TerminfoSourceTests: XCTestCase {

    /// CI gate: a missing or empty bundled terminfo dump must fail the build,
    /// not ship a release that silently no-ops the toggle.
    func testTerminfoDumpIsBundledAndNonEmpty() {
        let dump = TerminfoSource.terminfoDump()
        XCTAssertNotNil(dump, "bundled xterm-ghostty.terminfo missing — see Sources/SSHCommandBuilder/Resources/README.md")
        XCTAssertFalse(dump?.isEmpty ?? true, "bundled xterm-ghostty.terminfo is empty")
    }

    func testTerminfoDumpStartsWithGhosttyHeader() {
        guard let dump = TerminfoSource.terminfoDump() else {
            XCTFail("dump is nil — earlier test should have caught this")
            return
        }
        // First non-comment line of the dump should declare the entry name.
        // Format from `infocmp -x`: `name|alias|description,` with leading
        // tab-indented capability rows below. Comments start with `#`.
        let firstNonCommentLine = dump.split(separator: "\n")
            .first(where: { !$0.hasPrefix("#") && !$0.isEmpty })
        XCTAssertNotNil(firstNonCommentLine)
        XCTAssertTrue(
            firstNonCommentLine?.hasPrefix("xterm-ghostty|") ?? false,
            "expected entry name 'xterm-ghostty|...' but got: \(firstNonCommentLine ?? "<nil>")"
        )
    }
}
