import XCTest
@testable import SettingsStore

final class ThemeCatalogTests: XCTestCase {
    func testParseThemeJSONRoundTrips() throws {
        let json = """
        [
          {"name":"Dracula","palette":["#000000","#ff0000","#00ff00","#ffff00",
                                       "#0000ff","#ff00ff","#00ffff","#ffffff",
                                       "#000000","#ff0000","#00ff00","#ffff00",
                                       "#0000ff","#ff00ff","#00ffff","#ffffff"],
           "background":"#282a36","foreground":"#f8f8f2",
           "cursorColor":"#f8f8f2","selectionBackground":"#44475a"}
        ]
        """.data(using: .utf8)!
        let themes = try ThemeCatalog.decode(json)
        XCTAssertEqual(themes.count, 1)
        XCTAssertEqual(themes[0].name, "Dracula")
        XCTAssertEqual(themes[0].palette.count, 16)
        XCTAssertEqual(themes[0].background, "#282a36")
    }

    func testFallbackThemesAlwaysAvailable() {
        let catalog = ThemeCatalog.fallback
        XCTAssertGreaterThanOrEqual(catalog.themes.count, 9)
        for name in ThemeCatalog.favoriteNames {
            XCTAssertNotNil(
                catalog.themes.first(where: { $0.name == name }),
                "favorite \(name) missing from fallback bundle"
            )
        }
    }
}
