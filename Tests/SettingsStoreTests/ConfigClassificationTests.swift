import XCTest
@testable import SettingsStore

final class ConfigClassificationTests: XCTestCase {
    func testRepresentableSingleEntries() {
        let result = PartialSettings.classifyConfig("""
            font-family = SF Mono
            font-size = 14
            theme = Dracula
            cursor-style = bar
            macos-titlebar-style = native
            """)
        XCTAssertEqual(result.representable.count, 5)
        XCTAssertTrue(result.unrepresentable.isEmpty)
    }

    func testFallbackChainTreatedAsUnrepresentable() {
        let result = PartialSettings.classifyConfig("""
            font-family = SF Mono
            font-family = JetBrains Mono
            """)
        XCTAssertTrue(result.representable.isEmpty)
        XCTAssertEqual(result.unrepresentable.count, 1)
        if case .fallbackChain(let count) = result.unrepresentable[0].reason {
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("expected fallbackChain")
        }
        XCTAssertEqual(result.unrepresentable[0].sourceLines, [1, 2])
    }

    func testLightDarkTheme() {
        let result = PartialSettings.classifyConfig(
            "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        )
        XCTAssertTrue(result.representable.isEmpty)
        XCTAssertEqual(result.unrepresentable.count, 1)
        XCTAssertEqual(result.unrepresentable[0].reason, .lightDarkSplit)
    }

    func testCustomBellFeatures() {
        let result = PartialSettings.classifyConfig(
            "bell-features = audio,attention,no-title"
        )
        XCTAssertEqual(result.unrepresentable.count, 1)
        if case .customBellFeatures(let rendered) = result.unrepresentable[0].reason {
            XCTAssertEqual(rendered, "audio,attention,no-title")
        } else {
            XCTFail("expected customBellFeatures")
        }
    }

    func testStandardBellMatchesRoundtripsAsRepresentable() {
        let result = PartialSettings.classifyConfig(
            "bell-features = no-system,audio,attention,title,no-border"
        )
        XCTAssertEqual(result.representable.count, 1)
        XCTAssertEqual(result.unrepresentable.count, 0)
    }

    func testUnmodeledKeysFlagged() {
        let result = PartialSettings.classifyConfig("""
            palette = 0=#000000
            palette = 1=#ff0000
            keybind = ctrl+a=copy_to_clipboard
            background-image = ~/wp.jpg
            """)
        XCTAssertEqual(result.unrepresentable.count, 3)
        let keys = Set(result.unrepresentable.map(\.key))
        XCTAssertEqual(keys, Set(["palette", "keybind", "background-image"]))
    }
}
