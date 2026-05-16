import XCTest
import SettingsStore
@testable import ConfigStore

final class SettingsRendererTests: XCTestCase {
    func testEmptyPartialSettingsEmitsLegacyBlockOnly() {
        let out = SettingsRenderer.render(PartialSettings())
        XCTAssertTrue(out.contains("# managed by Caterm"))
        XCTAssertTrue(out.contains("term = xterm-256color"))
        XCTAssertTrue(out.contains("keybind = super+up=scroll_page_lines:-1"))
        XCTAssertTrue(out.contains("keybind = super+k=clear_screen"))
        XCTAssertFalse(out.contains("font-family"))
    }

    func testFullSettingsRenderEachField() {
        var s = PartialSettings()
        s.fontFamily = "SF Mono"
        s.fontSize = 13
        s.lineHeight = 1.1
        s.cursorStyle = .block
        s.cursorBlink = true
        s.bell = .both
        s.scrollbackBytes = 10_000_000
        s.windowOpacity = 0.95
        s.windowPaddingX = 4
        s.windowPaddingY = 4
        s.titlebarStyle = .tabs
        s.theme = "Catppuccin Mocha"
        let out = SettingsRenderer.render(s)
        XCTAssertTrue(out.contains("font-family = SF Mono"))
        XCTAssertTrue(out.contains("font-size = 13"))
        XCTAssertTrue(out.contains("adjust-cell-height = 10%"))
        XCTAssertTrue(out.contains("cursor-style = block"))
        XCTAssertTrue(out.contains("cursor-style-blink = true"))
        XCTAssertTrue(out.contains("bell-features = no-system,audio,attention,title,no-border"))
        XCTAssertTrue(out.contains("scrollback-limit = 10000000"))
        XCTAssertTrue(out.contains("background-opacity = 0.95"))
        XCTAssertTrue(out.contains("window-padding-x = 4"))
        XCTAssertTrue(out.contains("window-padding-y = 4"))
        XCTAssertTrue(out.contains("macos-titlebar-style = tabs"))
        XCTAssertTrue(out.contains("theme = Catppuccin Mocha"))
    }

    func testLineHeightNegative() {
        var s = PartialSettings()
        s.lineHeight = 0.9
        XCTAssertTrue(SettingsRenderer.render(s).contains("adjust-cell-height = -10%"))
    }

    func testBellModeMapping() {
        for (mode, expected) in [
            (BellMode.none, "no-system,no-audio,no-attention,no-title,no-border"),
            (.audio, "no-system,audio,no-attention,no-title,no-border"),
            (.visual, "no-system,no-audio,attention,title,no-border"),
            (.both, "no-system,audio,attention,title,no-border"),
        ] {
            var s = PartialSettings()
            s.bell = mode
            XCTAssertTrue(
                SettingsRenderer.render(s).contains("bell-features = \(expected)"),
                "bell mode \(mode) → \(expected)"
            )
        }
    }

    func testThemeWithSpacesUnquoted() {
        var s = PartialSettings()
        s.theme = "Solarized Dark Higher Contrast"
        XCTAssertTrue(
            SettingsRenderer.render(s).contains("theme = Solarized Dark Higher Contrast")
        )
    }

    func testLegacyBlockAlwaysPresent() {
        var s = PartialSettings()
        s.fontFamily = "JetBrains Mono"
        let out = SettingsRenderer.render(s)
        for line in [
            "term = xterm-256color",
            "keybind = super+up=scroll_page_lines:-1",
            "keybind = super+down=scroll_page_lines:1",
            "keybind = super+page_up=scroll_page_fractional:-1",
            "keybind = super+page_down=scroll_page_fractional:1",
            "keybind = super+home=scroll_to_top",
            "keybind = super+end=scroll_to_bottom",
            "keybind = super+k=clear_screen",
        ] {
            XCTAssertTrue(out.contains(line), "missing legacy line: \(line)")
        }
    }
}
