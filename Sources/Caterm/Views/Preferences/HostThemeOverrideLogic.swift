import Foundation
import SettingsStore

/// Pure logic helper for setting / clearing a host's theme override.
/// SwiftUI views (e.g. `HostThemeOverridePicker`) call into this so the
/// behavior can be unit-tested without instantiating any view hierarchy.
@MainActor
public struct HostThemeOverrideLogic {
	let store: SettingsStore

	public init(store: SettingsStore) { self.store = store }

	public func setTheme(_ theme: String?, forHost id: HostId) {
		store.update { settings in
			if let theme {
				settings.hostOverrides[id] = PartialSettings(theme: theme)
			} else {
				settings.hostOverrides.removeValue(forKey: id)
			}
		}
	}
}
