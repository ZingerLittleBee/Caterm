import ConfigStore
import Foundation
import SettingsStore
import TerminalEngine

/// Owns one `LiveReloadDispatcher` and the `NotificationCenter` observer
/// that bridges `SettingsStore.changeNotification` to it. Holds the
/// observer token for the app's lifetime so changes to Preferences flow
/// through to the managed-snapshot render and banner notifications.
///
/// Today's coverage:
/// - `globalLive` / `globalNewSurface`: re-renders managed snapshot,
///   updates active Ghostty surfaces for live fields, and posts the
///   new-surface banner notification when applicable.
/// - `hostOverride`: re-renders the per-host patch directory so the next
///   surface for that host picks up the new theme.
@MainActor
final class LiveReloadCoordinator {
	private let dispatcher: LiveReloadDispatcher
	private let settingsStore: SettingsStore
	private var observerToken: NSObjectProtocol?

	init(
		settingsStore: SettingsStore,
		activeSurfaceTabIds: @escaping @MainActor () -> [UUID] = { [] },
		reloadApp: @escaping @MainActor () -> Void = {},
		reloadSurface: @escaping @MainActor (UUID) -> Void = { _ in },
		renderManagedSnapshot: @escaping @MainActor (PartialSettings) throws -> Void = {
			try ConfigStore.renderManagedSnapshot(from: $0)
		},
		buildConfig: @escaping @MainActor () -> [ConfigDiagnostic] = {
			GhosttyConfig.diagnostics()
		}
	) {
		self.settingsStore = settingsStore
		// Closures capture only value types / the SettingsStore reference
		// so they remain main-actor-safe.
		self.dispatcher = LiveReloadDispatcher(
			surfaceIds: { activeSurfaceTabIds().map(\.uuidString) },
			applyToSurface: { id in
				guard let tabId = UUID(uuidString: id) else { return }
				reloadSurface(tabId)
			},
			applyToApp: reloadApp,
			renderManagedSnapshot: renderManagedSnapshot,
			buildConfig: buildConfig
		)
		self.observerToken = NotificationCenter.default.addObserver(
			forName: SettingsStore.changeNotification,
			object: settingsStore,
			queue: .main
		) { [weak self] note in
			MainActor.assumeIsolated {
				self?.handle(note: note)
			}
		}
	}

	deinit {
		if let token = observerToken {
			NotificationCenter.default.removeObserver(token)
		}
	}

	private func handle(note: Notification) {
		guard let scope = note.userInfo?[SettingsStore.scopeUserInfoKey]
			as? SettingsChangeScope
		else { return }
		let settings = settingsStore.settings
		switch scope {
		case .hostOverride:
			// Regenerate per-host patches so the next surface for the
			// touched host picks up its new theme. Existing surfaces
			// keep their current patch — that's the contract for
			// host-override scope (deferred per-surface live apply).
			try? ConfigStore.regeneratePerHostPatches(from: settings)
			dispatcher.handle(scope: scope, settings: settings)
		case .globalLive, .globalNewSurface:
			dispatcher.handle(scope: scope, settings: settings)
		}
	}
}
