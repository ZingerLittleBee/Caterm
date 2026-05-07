import HostSyncStore
import SessionStore
import SettingsStore
import SSHCommandBuilder
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
	let tabId: UUID

	private var backgroundTransparencyEnabled: Bool {
		(settingsStore.settings.global.windowOpacity ?? 1.0) < 0.999
	}

	var body: some View {
		ZStack {
			if let tab = store.tabs.first(where: { $0.id == tabId }) {
				surfaceOrPlaceholder(for: tab)
				stateOverlay(for: tab.state, host: tab.host, chain: tab.resolvedChain)
			}
		}
		.animation(.easeOut(duration: 0.15),
		           value: store.tabs.first(where: { $0.id == tabId })?.state)
	}

	@ViewBuilder
	private func surfaceOrPlaceholder(for tab: SessionStore.Tab) -> some View {
		switch tab.state {
		case .authenticating, .connected, .reconnecting:
			TerminalSurfaceRepresentable(
				tabId: tabId,
				backgroundTransparencyEnabled: backgroundTransparencyEnabled
			)
			.id("\(tabId)-\(tab.surfaceGeneration)")

		case .idle, .preflight, .failed:
			// Inert SwiftUI background — no NSView, no $SHELL fork.
			Color.black.opacity(0.95).ignoresSafeArea()
		}
	}

	@ViewBuilder
	private func stateOverlay(for state: ConnectionState, host: SSHHost, chain: [SSHHost]) -> some View {
		switch state {
		case .preflight(let startedAt):
			ConnectingOverlay(stage: .preflight, host: host, startedAt: startedAt, chain: chain)
		case .authenticating(let startedAt):
			ConnectingOverlay(stage: .authenticating, host: host, startedAt: startedAt, chain: chain)
		case .reconnecting(let attempt, let nextRetryAt):
			ReconnectOverlay(attempt: attempt, nextRetryAt: nextRetryAt, host: host, chain: chain)
		case .failed(let kind) where shouldShowFailureOverlay(kind):
			FailureOverlay(
				failure: kind,
				host: host,
				chain: chain,
				onRetry: { store.retryTab(tabId: tabId) },
				onEditHost: {
					NotificationCenter.default.post(
						name: .catermEditHostRequested,
						object: nil,
						userInfo: [CatermEditHostRequestedKeys.hostId: host.id]
					)
				}
			)
		case .idle, .connected, .failed:
			EmptyView()
		}
	}

	private func shouldShowFailureOverlay(_ kind: FailureKind) -> Bool {
		switch kind {
		case .cleanExit, .connectionDropped: return false
		case .authOrSetupFail, .networkUnreachable: return true
		}
	}
}

/// Renders one `SessionStore.Tab`'s libghostty surface. Independent of the
/// connect-flow UI; just consumes a `tabId` and binds to its surface, wiring
/// `markConnected / markChildExited` for state tracking. The
/// `.authenticating` transition is owned by `SessionStore.startConnection`
/// and happens before this representable is even mounted.
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
