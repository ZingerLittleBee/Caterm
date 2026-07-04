import SwiftUI
import SettingsStore

public struct ThemePickerLogic {
    public let catalog: ThemeCatalog

    public init(catalog: ThemeCatalog) { self.catalog = catalog }

    public var favorites: [ThemeRecord] { catalog.favorites }

    public func filtered(query: String) -> [ThemeRecord] {
        if query.isEmpty { return catalog.themes }
        return catalog.themes.filter {
            $0.name.range(of: query, options: .caseInsensitive) != nil
        }
    }
}

public struct ThemePickerView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var query: String = ""
    private let logic: ThemePickerLogic

    public init() {
        self.logic = ThemePickerLogic(catalog: ThemeCatalog.loadBundled())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search themes…", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Section {
                        Text("Favorites").font(.headline)
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(logic.favorites) { theme in
                                card(for: theme)
                            }
                        }
                    }
                    if !query.isEmpty || logic.catalog.themes.count > logic.favorites.count {
                        Section {
                            Text(query.isEmpty ? "All Themes" : "Results")
                                .font(.headline)
                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(logic.filtered(query: query)) { theme in
                                    card(for: theme)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom)
            }
        }
        .padding(20)
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    private func card(for theme: ThemeRecord) -> some View {
        ThemeCardView(
            theme: theme,
            isSelected: store.settings.global.theme == theme.name,
            action: {
                store.update { $0.global.theme = theme.name }
            }
        )
    }
}
