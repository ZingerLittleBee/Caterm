import Foundation

public struct ThemeRecord: Codable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let palette: [String]
    public let background: String
    public let foreground: String
    public let cursorColor: String?
    public let selectionBackground: String?

    public init(
        name: String,
        palette: [String],
        background: String,
        foreground: String,
        cursorColor: String?,
        selectionBackground: String?
    ) {
        self.name = name
        self.palette = palette
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.selectionBackground = selectionBackground
    }
}

public struct ThemeCatalog {
    public let themes: [ThemeRecord]

    public init(themes: [ThemeRecord]) { self.themes = themes }

    static func packagedResourceBundle(in mainBundle: Bundle) -> Bundle? {
        guard let resourceURL = mainBundle.resourceURL else { return nil }
        return Bundle(
            url: resourceURL.appendingPathComponent(
                "Caterm_SettingsStore.bundle",
                isDirectory: true
            )
        )
    }

    private static let resourceBundle =
        packagedResourceBundle(in: .main) ?? Bundle.module

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
        guard let url = resourceBundle.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? decode(data),
              !themes.isEmpty
        else {
            return fallback
        }
        return ThemeCatalog(themes: themes)
    }

    public static let fallback: ThemeCatalog = {
        var themes: [ThemeRecord] = []
        for name in favoriteNames {
            let url = resourceBundle.url(
                forResource: name,
                withExtension: "config",
                subdirectory: "fallback-themes"
            ) ?? resourceBundle.url(
                forResource: name,
                withExtension: "config"
            )
            guard let url else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let record = parseThemeFile(name: name, content: text) {
                themes.append(record)
            }
        }
        if themes.isEmpty {
            themes = favoriteNames.map { name in
                ThemeRecord(
                    name: name,
                    palette: Array(repeating: "#000000", count: 16),
                    background: "#000000",
                    foreground: "#ffffff",
                    cursorColor: nil,
                    selectionBackground: nil
                )
            }
        }
        return ThemeCatalog(themes: themes)
    }()

    private static func parseThemeFile(name: String, content: String) -> ThemeRecord? {
        var palette: [String?] = Array(repeating: nil, count: 16)
        var bg: String?
        var fg: String?
        var cur: String?
        var sel: String?
        for entry in GhosttyConfigParser.parse(content) {
            switch entry.key {
            case "palette":
                let parts = entry.rawValue.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let idx = Int(parts[0]), idx >= 0, idx < 16 else { continue }
                var hex = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !hex.hasPrefix("#") { hex = "#" + hex }
                palette[idx] = hex
            case "background": bg = entry.rawValue
            case "foreground": fg = entry.rawValue
            case "cursor-color": cur = entry.rawValue
            case "selection-background": sel = entry.rawValue
            default: continue
            }
        }
        let final = palette.compactMap { $0 }
        guard final.count == 16, let bg, let fg else { return nil }
        return ThemeRecord(
            name: name,
            palette: final,
            background: bg,
            foreground: fg,
            cursorColor: cur,
            selectionBackground: sel
        )
    }
}
