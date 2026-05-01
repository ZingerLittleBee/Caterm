import XCTest
@testable import SettingsStore

final class GhosttyConfigParserEditTests: XCTestCase {
    func testRemoveLinesPreservesCommentsAndBlankLines() {
        let original = """
        # header

        font-family = SF Mono
        # cursor section
        cursor-style = block
        font-size = 13
        """
        let edited = GhosttyConfigParser.removeLines(original, lineNumbers: [3, 6])
        XCTAssertEqual(edited, """
        # header

        # cursor section
        cursor-style = block
        """)
    }

    func testRemoveNothingPreservesByteForByte() {
        let original = "# a\n\nkey = value\n"
        XCTAssertEqual(GhosttyConfigParser.removeLines(original, lineNumbers: []), original)
    }

    func testRemoveAllProducesEmpty() {
        let original = "a = 1\nb = 2"
        XCTAssertEqual(GhosttyConfigParser.removeLines(original, lineNumbers: [1, 2]), "")
    }
}
