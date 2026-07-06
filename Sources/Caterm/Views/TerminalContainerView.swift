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
			// Shared guard: only report progress if this representable still
			// owns the tab's connection — the process is alive and the surface
			// generation hasn't moved on under us. Callers may fire more than
			// once; the fast-path `onSessionLive` signal usually wins the race
			// with the grace timers below.
			@MainActor func stillOwnsLiveConnection() -> SessionStore? {
				guard let store, let surface = view?.surface,
				      !surface.processExited else { return nil }
				guard store.tabs.first(where: { $0.id == capturedTabId })?
					.surfaceGeneration == capturedGeneration else { return nil }
				return store
			}

			@MainActor func reportConnectedIfCurrent() {
				stillOwnsLiveConnection()?.markConnected(tabId: capturedTabId)
			}

			// Provisional: dismiss the overlay early without committing
			// `hadConnected` (see `markConnectedProvisional`).
			@MainActor func reportProvisionalIfCurrent() {
				stillOwnsLiveConnection()?.markConnectedProvisional(tabId: capturedTabId)
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
					// Fast-path "session is live" signal: fires on the first OSC
					// title/pwd the remote shell emits (zsh, a bash with a
					// title-setting PROMPT_COMMAND, etc.). Dismisses the overlay
					// the instant the shell is interactive instead of waiting out
					// the grace timer. Shells that never set a title (minimal
					// `sh`, appliances) fall through to the grace timer below.
					// Auth/DNS failures exit before any shell starts and never
					// fire this, so the failure path is unaffected.
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
			// Two-phase fallback for sessions that never emit an OSC title/pwd
			// (minimal `sh`, appliances, remote hosts whose PROMPT_COMMAND
			// doesn't set a title), where the fast-path `onSessionLive` never
			// fires:
			//
			//   Phase 1 (short grace): if the ssh process is still alive a
			//   fraction of a second past a successful TCP preflight, that's a
			//   strong signal it's really connected — dismiss the overlay
			//   *provisionally* (no `hadConnected` commit) so the user isn't
			//   staring at a spinner over a working terminal. This is the fix
			//   for "terminal is up but loading keeps spinning".
			//
			//   Phase 2 (full grace): if it survives to the full grace window,
			//   commit the real `.connected` (sets `hadConnected`). Keeping the
			//   commit late is what lets a *slow* auth/setup failure — one that
			//   exits after phase 1 but before phase 2 — still classify as
			//   `.authOrSetupFail` rather than a reconnectable drop.
			try? await Task.sleep(nanoseconds: 600_000_000)
			if Task.isCancelled { return }
			reportProvisionalIfCurrent()

			try? await Task.sleep(nanoseconds: 2_400_000_000)
			if Task.isCancelled { return }
			reportConnectedIfCurrent()
		}
		return view
	}

	func updateNSView(_: GhosttySurfaceNSView, context _: Context) {}
}
