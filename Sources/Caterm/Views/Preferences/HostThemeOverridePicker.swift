import SettingsStore
import SwiftUI

/// Picker presented inside `HostFormView` for `.edit` mode that lets the user
/// pin a theme override on a single host. "Use global" clears the override.
public struct HostThemeOverridePicker: View {
	@EnvironmentObject var store: SettingsStore
	let hostId: HostId

	public init(hostId: HostId) { self.hostId = hostId }

	public var body: some View {
		let logic = HostThemeOverrideLogic(store: store)
		let catalog = ThemeCatalog.loadBundled()
		let current = store.settings.hostOverrides[hostId]?.theme
		Picker("Theme", selection: Binding(
			get: { current ?? "" },
			set: { value in logic.setTheme(value.isEmpty ? nil : value, forHost: hostId) }
		)) {
			Text("Use global").tag("")
			ForEach(catalog.themes) { theme in
				Text(theme.name).tag(theme.name)
			}
		}
	}
}
