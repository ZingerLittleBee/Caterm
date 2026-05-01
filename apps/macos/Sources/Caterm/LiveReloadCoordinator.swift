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
///   posts the new-surface banner notification when applicable.
/// - `hostOverride`: re-renders the per-host patch directory so the next
///   surface for that host picks up the new theme.
///
/// Deferred (follow-up): per-surface application of font/theme/cursor
/// onto already-mounted Ghostty surfaces. There is no surface registry
/// at the App level today, so `surfaceIds` returns `[]` and
/// `applyToSurface` is a no-op. The rendered snapshot + banner is
/// enough to (a) drive the integration tests and (b) make new surfaces
/// reflect the change without requiring a Caterm restart.
@MainActor
final class LiveReloadCoordinator {
	private let dispatcher: LiveReloadDispatcher
	private let settingsStore: SettingsStore
	private var observerToken: NSObjectProtocol?

	init(settingsStore: SettingsStore) {
		self.settingsStore = settingsStore
		// Closures capture only value types / the SettingsStore reference
		// so they remain main-actor-safe.
		self.dispatcher = LiveReloadDispatcher(
			surfaceIds: { [] },
			applyToSurface: { _ in },
			applyToApp: {},
			renderManagedSnapshot: { partial in
				try ConfigStore.renderManagedSnapshot(from: partial)
			},
			buildConfig: { [] }
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
