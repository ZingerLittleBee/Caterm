import AppKit
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
	let isFocused: Bool
	let onFocus: () -> Void

	init(
		tabId: UUID,
		isFocused: Bool = true,
		onFocus: @escaping () -> Void = {}
	) {
		self.tabId = tabId
		self.isFocused = isFocused
		self.onFocus = onFocus
	}

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
					backgroundTransparencyEnabled: backgroundTransparencyEnabled,
					isFocused: isFocused,
					onFocus: onFocus
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
			let canEditHost = store.hosts.contains { $0.id == host.id }
			FailureOverlay(
				failure: kind,
				host: host,
				chain: chain,
				onRetry: { store.retryTab(tabId: tabId) },
				onEditHost: canEditHost ? {
					NotificationCenter.default.post(
						name: .catermEditHostRequested,
						object: NSApp.keyWindow,
						userInfo: [CatermEditHostRequestedKeys.hostId: host.id]
					)
				} : nil
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
	@EnvironmentObject var surfaceRegistry: SurfaceRegistry
	let tabId: UUID
	let backgroundTransparencyEnabled: Bool
	let isFocused: Bool
	let onFocus: () -> Void

	/// Owns the unstructured connect-probe `Task` so it is tied to this
	/// representable's lifetime. Without this the probe outlived a torn-down
	/// surface: on a rapid reconnect (`surfaceGeneration` bump → new NSView,
	/// old one dismantled) the stale probe would still fire
	/// `markConnected` against the tab whose *new* connection was mid-
	/// handshake, racing the new state machine.
	@MainActor
	final class Coordinator {
		var probe: SessionLivenessProbe?
		var probeTask: Task<Void, Never>?

		func cancelProbe() {
			probeTask?.cancel()
			probeTask = nil
			probe = nil
		}

		deinit { probeTask?.cancel() }
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	static func dismantleNSView(_: GhosttySurfaceNSView, coordinator: Coordinator) {
		coordinator.cancelProbe()
	}

	func makeNSView(context: Context) -> GhosttySurfaceNSView {
		guard let cfg = store.surfaceConfig(for: tabId) else {
			let view = GhosttySurfaceNSView(command: nil)
			view.setBackgroundTransparencyEnabled(backgroundTransparencyEnabled)
			configureFocus(for: view)
			return view
		}
		let view = GhosttySurfaceNSView(command: cfg.command, env: cfg.env)
		view.setBackgroundTransparencyEnabled(backgroundTransparencyEnabled)
		configureFocus(for: view)

		let capturedTabId = tabId
		// The surface generation this representable was created for. If the
		// tab reconnects (generation bumps) while this probe is still
		// sleeping, the probe must NOT report this (now superseded)
		// connection as connected.
		let capturedGeneration = store.tabs
			.first(where: { $0.id == tabId })?.surfaceGeneration ?? 0
		weak var probeReference: SessionLivenessProbe?
		let probe = SessionLivenessProbe(
			expectedGeneration: .init(capturedGeneration),
			observation: { [weak store, weak view] in
				guard let generation = store?.tabs
					.first(where: { $0.id == capturedTabId })?
					.surfaceGeneration else {
					return .sessionMissing
				}
				let currentGeneration = SessionLivenessProbe.Generation(generation)
				guard let surface = view?.surface else {
					return .surfaceUnavailable(generation: currentGeneration)
				}
				return surface.processExited
					? .surfaceExited(generation: currentGeneration)
					: .surfaceRunning(generation: currentGeneration)
			},
			prepareSurface: { [weak store, weak surfaceRegistry, weak view] in
				guard let surface = view?.surface else {
					probeReference?.connectionDidEnd()
					return
				}
				surface.onChildExit = { [weak store, weak probeReference] code in
					Task { @MainActor in
						probeReference?.connectionDidEnd()
						store?.markChildExited(tabId: capturedTabId, exitCode: code)
					}
				}
				surface.onSessionLive = { [weak probeReference] in
					MainActor.assumeIsolated {
						probeReference?.sessionDidBecomeLive()
					}
				}
				surfaceRegistry?.register(surface, for: capturedTabId)
				let hostId = store?.hostId(for: capturedTabId).map { HostId($0.uuidString) }
				surface.applyConfig(hostId: hostId)
			},
			onEvent: { [weak store] event in
				switch event {
				case .provisional:
					store?.markConnectedProvisional(tabId: capturedTabId)
				case .confirmed:
					store?.markConnected(tabId: capturedTabId)
				case .lost:
					break
				}
			}
		)
		probeReference = probe
		context.coordinator.probe = probe
		context.coordinator.probeTask = Task { @MainActor [weak probe] in
			await probe?.run()
		}
		return view
	}

	func updateNSView(_ view: GhosttySurfaceNSView, context _: Context) {
		configureFocus(for: view)
	}

	private func configureFocus(for view: GhosttySurfaceNSView) {
		view.onFirstResponderChange = { focused in
			guard focused else { return }
			onFocus()
		}
		view.setPaneFocusRequested(isFocused)
	}
}
