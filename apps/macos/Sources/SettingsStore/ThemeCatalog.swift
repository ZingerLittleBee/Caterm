import Foundation

public struct ThemeRecord: Codable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let palette: [String]
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let selectionBackground: String?
}

public struct ThemeCatalog {
    public let themes: [ThemeRecord]

    public static let favoriteNames: [String] = [
        "Catppuccin Mocha",
        "Catppuccin Latte",
        "Dracula",
        "Gruvbox Dark",
        "Gruvbox Light",
        "Nord",
        "One Dark Two",
        "Solarized Dark Higher Contrast",
        "Monokai Classic",
    ]

    public var favorites: [ThemeRecord] {
        Self.favoriteNames.compactMap { name in themes.first { $0.name == name } }
    }

    public static func decode(_ data: Data) throws -> [ThemeRecord] {
        try JSONDecoder().decode([ThemeRecord].self, from: data)
    }

    public static func loadBundled() -> ThemeCatalog {
        guard let url = Bundle.module.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? decode(data),
              !themes.isEmpty
        else {
            return fallback
        }
        return ThemeCatalog(themes: themes)
    }

    public static let fallback: ThemeCatalog = {
        ThemeCatalog(themes: favoriteNames.map { name in
            ThemeRecord(
                name: name,
                palette: Array(repeating: "#000000", count: 16),
                background: "#000000",
                foreground: "#ffffff",
                cursorColor: nil,
                selectionBackground: nil
            )
        })
    }()
}
