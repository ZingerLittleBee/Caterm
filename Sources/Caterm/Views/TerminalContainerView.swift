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
		case .authOrSetupFail, .networkUnreachable, .portForwardBindFailed: return true
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

	/// Owns the unstructured connect-probe `Task` so it is tied to this
	/// representable's lifetime. Without this the probe outlived a torn-down
	/// surface: on a rapid reconnect (`surfaceGeneration` bump → new NSView,
	/// old one dismantled) the stale probe would still fire
	/// `markConnected` against the tab whose *new* connection was mid-
	/// handshake, racing the new state machine.
	@MainActor
	final class Coordinator {
		var probe: Task<Void, Never>?
		deinit { probe?.cancel() }
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	static func dismantleNSView(_: GhosttySurfaceNSView, coordinator: Coordinator) {
		coordinator.probe?.cancel()
		coordinator.probe = nil
	}

	func makeNSView(context: Context) -> GhosttySurfaceNSView {
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
		// The surface generation this representable was created for. If the
		// tab reconnects (generation bumps) while this probe is still
		// sleeping, the probe must NOT report this (now superseded)
		// connection as connected.
		let capturedGeneration = store.tabs
			.first(where: { $0.id == tabId })?.surfaceGeneration ?? 0
		context.coordinator.probe = Task { @MainActor [weak store, weak surfaceRegistry, weak view] in
			// Promote the tab to `.connected` (dismissing the overlay) only
			// if this representable still owns the tab's connection — i.e.
			// the process is alive and the surface generation hasn't moved
			// on under us. Safe to call more than once: `markConnected` is
			// idempotent and the early signal usually wins the race with the
			// grace timer below.
			@MainActor func reportConnectedIfCurrent() {
				guard let store, let surface = view?.surface,
				      !surface.processExited else { return }
				guard store.tabs.first(where: { $0.id == capturedTabId })?
					.surfaceGeneration == capturedGeneration else { return }
				store.markConnected(tabId: capturedTabId)
			}

			// `view.surface` is built lazily in `viewDidMoveToWindow`. Yield
			// until it exists or give up after ~3s.
			let deadline = Date().addingTimeInterval(3)
			while Date() < deadline {
				if Task.isCancelled { return }
				if let surface = view?.surface {
					surface.onChildExit = { [weak store] code in
						Task { @MainActor in
							store?.markChildExited(tabId: capturedTabId, exitCode: code)
						}
					}
					// Real "session is live" signal: fires on the first OSC
					// title/pwd in the stream. SSHCommandBuilder plants a
					// LocalCommand beacon that prints one the instant the
					// connection is established, so this no longer depends on
					// the remote shell setting a title (that still works as a
					// second trigger). Auth/DNS failures exit before
					// LocalCommand runs and never fire this, so the failure
					// path is unaffected.
					surface.onSessionLive = {
						MainActor.assumeIsolated { reportConnectedIfCurrent() }
					}
					surfaceRegistry?.register(surface, for: capturedTabId)
					let hostId = store?.hostId(for: capturedTabId).map { HostId($0.uuidString) }
					surface.applyConfig(hostId: hostId)
					break
				}
				try? await Task.sleep(nanoseconds: 50_000_000)
			}
			// Fallback grace period for sessions that never emit an OSC
			// title/pwd (minimal `sh`, appliances): if the process is still
			// alive after 3s, treat it as connected. This is also the sole
			// path that lets a fast auth failure (process exits before the
			// grace elapses) stay classified as `.authOrSetupFail`.
			try? await Task.sleep(nanoseconds: 3_000_000_000)
			if Task.isCancelled { return }
			reportConnectedIfCurrent()
		}
		return view
	}

	func updateNSView(_: GhosttySurfaceNSView, context _: Context) {}
}
