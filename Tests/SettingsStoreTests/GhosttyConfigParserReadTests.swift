import XCTest
@testable import SettingsStore

final class GhosttyConfigParserReadTests: XCTestCase {
    func testParsesKeyValueEntriesWithLineNumbers() {
        let text = """
        # comment
        font-family = SF Mono
        font-size = 13

        theme = Catppuccin Mocha
        """
        let entries = GhosttyConfigParser.parse(text)
        XCTAssertEqual(entries.map(\.key), ["font-family", "font-size", "theme"])
        XCTAssertEqual(entries.map(\.rawValue), ["SF Mono", "13", "Catppuccin Mocha"])
        XCTAssertEqual(entries.map(\.sourceLine), [2, 3, 5])
    }

    func testStripsOuterDoubleQuotes() {
        let entries = GhosttyConfigParser.parse(#"font-family = "JetBrains Mono""#)
        XCTAssertEqual(entries.first?.rawValue, "JetBrains Mono")
    }

    func testPreservesRepeatedKeysInOrder() {
        let entries = GhosttyConfigParser.parse("""
        font-family = A
        font-family = B
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].rawValue, "A")
        XCTAssertEqual(entries[1].rawValue, "B")
    }

    func testEmptyValueAllowed() {
        let entries = GhosttyConfigParser.parse("font-family = ")
        XCTAssertEqual(entries.first?.rawValue, "")
    }

    func testInnerQuotesAndPunctuationPassThrough() {
        let entries = GhosttyConfigParser.parse(#"command-palette-entry = title:"Change Tab Title…",action:"prompt_surface_title""#)
        XCTAssertEqual(entries.first?.key, "command-palette-entry")
        XCTAssertTrue(entries.first?.rawValue.contains("title:\"Change Tab Title…\"") == true)
    }
}
