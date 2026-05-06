import HostSyncStore
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SwiftUI
import TerminalEngine

/// Wraps one `SessionStore.Tab`'s libghostty surface and shows a
/// `ReconnectOverlay` on top when the tab is in `.reconnecting` state.
/// Incrementing `tab.surfaceGeneration` (done by `scheduleReconnect` in
/// `SessionStore`) forces SwiftUI to tear down and recreate
/// `TerminalSurfaceRepresentable` — which calls `makeNSView` again, kicking
/// off a fresh ssh subprocess.
struct TerminalContainerView: View {
	@EnvironmentObject var store: SessionStore
	@EnvironmentObject var settingsStore: SettingsStore
	@EnvironmentObject var surfaceRegistry: SurfaceRegistry
	@EnvironmentObject var snippetStore: SnippetStore
	@EnvironmentObject var snippetSync: SnippetSyncStore
	@State private var showingPalette = false
	let tabId: UUID

	private var backgroundTransparencyEnabled: Bool {
		(settingsStore.settings.global.windowOpacity ?? 1.0) < 0.999
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Spacer()
				Button(action: { showingPalette.toggle() }) {
					Image(systemName: "text.cursor")
						.help("Snippets (⌘⇧P)")
				}
				.buttonStyle(.borderless)
				.padding(.horizontal, 6)
				.popover(isPresented: $showingPalette) {
					SnippetPalette(
						store: snippetStore,
						sync: snippetSync,
						capturedSurface: surfaceRegistry.surface(for: tabId) as (any SnippetDispatchTarget)?,
						onClose: { showingPalette = false },
						onCreate: {
							showingPalette = false
							NotificationCenter.default.post(name: .catermNewSnippet, object: nil)
						}
					)
				}
			}
			.frame(height: 22)

			ZStack {
				if let tab = store.tabs.first(where: { $0.id == tabId }) {
					TerminalSurfaceRepresentable(
						tabId: tabId,
						backgroundTransparencyEnabled: backgroundTransparencyEnabled
					)
						.id("\(tabId)-\(tab.surfaceGeneration)")
					if case let .reconnecting(attempt, nextRetryAt) = tab.state {
						ReconnectOverlay(attempt: attempt, nextRetryAt: nextRetryAt)
					}
				}
			}
		}
	}
}

/// Renders one `SessionStore.Tab`'s libghostty surface. Independent of the
/// connect-flow UI; just consumes a `tabId` and binds to its surface, wiring
/// `markConnecting / markConnected / markChildExited` for state tracking.
///
/// `GhosttySurfaceNSView.surface` is built lazily inside `viewDidMoveToWindow`,
/// so we poll briefly until it's available before attaching the `onChildExit`
/// callback.
///
/// Recreation is driven by the `.id("\(tabId)-\(tab.surfaceGeneration)")` modifier in
/// `TerminalContainerView` — when `surfaceGeneration` increments, SwiftUI tears down
/// and recreates this representable (and thus the underlying `GhosttySurfaceNSView`),
/// kicking off a fresh ssh subprocess.
struct TerminalSurfaceRepresentable: NSViewRepresentable {
	@EnvironmentObject var store: SessionStore
	@EnvironmentObject var preferences: SyncPreferences
	@EnvironmentObject var surfaceRegistry: SurfaceRegistry
	let tabId: UUID
	let backgroundTransparencyEnabled: Bool

	func makeNSView(context _: Context) -> GhosttySurfaceNSView {
		guard let cfg = store.surfaceConfig(
			for: tabId,
			installTerminfo: preferences.installTerminfoEnabled
		) else {
			let view = GhosttySurfaceNSView(command: nil)
			view.setBackgroundTransparencyEnabled(backgroundTransparencyEnabled)
			return view
		}
		let view = GhosttySurfaceNSView(command: cfg.command, env: cfg.env)
		view.setBackgroundTransparencyEnabled(backgroundTransparencyEnabled)
		store.markConnecting(tabId: tabId)

		let capturedTabId = tabId
		Task { @MainActor [weak store, weak surfaceRegistry, weak view] in
			// `view.surface` is built lazily in `viewDidMoveToWindow`. Yield
			// until it exists or give up after ~3s.
			let deadline = Date().addingTimeInterval(3)
			while Date() < deadline {
				if let surface = view?.surface {
					surface.onChildExit = { [weak store] code in
						Task { @MainActor in
							store?.markChildExited(tabId: capturedTabId, exitCode: code)
						}
					}
					surfaceRegistry?.register(surface, for: capturedTabId)
					let hostId = store?.hostId(for: capturedTabId).map { HostId($0.uuidString) }
					surface.applyConfig(hostId: hostId)
					break
				}
				try? await Task.sleep(nanoseconds: 50_000_000)
			}
			// 3s grace period: if process still alive, mark Connected.
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			guard let store, let surface = view?.surface,
			      !surface.processExited else { return }
			store.markConnected(tabId: capturedTabId)
		}
		return view
	}

	func updateNSView(_: GhosttySurfaceNSView, context _: Context) {}
}
