import XCTest
import SettingsStore
@testable import Caterm

final class ThemePickerLogicTests: XCTestCase {
    func testFiltersGridByQueryCaseInsensitive() {
        let catalog = ThemeCatalog(themes: [
            sample("Dracula"),
            sample("One Dark Two"),
            sample("Catppuccin Mocha"),
        ])
        let logic = ThemePickerLogic(catalog: catalog)
        XCTAssertEqual(logic.filtered(query: "dark").map(\.name), ["One Dark Two"])
        XCTAssertEqual(logic.filtered(query: "").count, 3)
    }

    func testFavoritesAlwaysVisibleEvenWhenSearchedAway() {
        let catalog = ThemeCatalog(themes: ThemeCatalog.fallback.themes)
        let logic = ThemePickerLogic(catalog: catalog)
        XCTAssertEqual(logic.favorites.map(\.name).sorted(), ThemeCatalog.favoriteNames.sorted())
    }

    private func sample(_ n: String) -> ThemeRecord {
        ThemeRecord(
            name: n, palette: Array(repeating: "#000", count: 16),
            background: "#000", foreground: "#fff",
            cursorColor: nil, selectionBackground: nil
        )
    }
}
