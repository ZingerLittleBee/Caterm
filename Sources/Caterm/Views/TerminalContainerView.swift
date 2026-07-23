import AppKit
import HostAutomationRuntime
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
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	let tabId: UUID
	let isFocused: Bool
	let onFocus: () -> Void
	let onClosePane: () -> Void

	init(
		tabId: UUID,
		isFocused: Bool = true,
		onFocus: @escaping () -> Void = {},
		onClosePane: @escaping () -> Void = {}
	) {
		self.tabId = tabId
		self.isFocused = isFocused
		self.onFocus = onFocus
		self.onClosePane = onClosePane
	}

	private var backgroundTransparencyEnabled: Bool {
		(settingsStore.settings.global.windowOpacity ?? 1.0) < 0.999
	}

	var body: some View {
		ZStack {
			if let tab = store.tabs.first(where: { $0.id == tabId }) {
				surfaceOrPlaceholder(for: tab)
				stateOverlay(for: tab.state, host: tab.host, chain: tab.resolvedChain)
				automationOverlay(for: tab)
				environmentStatus(for: tab)
			}
		}
		.animation(WorkspaceMotionPolicy.statusAnimation(reduceMotion: reduceMotion),
		           value: store.tabs.first(where: { $0.id == tabId })?.state)
	}

	@ViewBuilder
	private func automationOverlay(for tab: SessionStore.Tab) -> some View {
		if case .idle = tab.state {
			switch tab.automationController.gate {
			case .reviewRequired(let plan):
				HostAutomationConnectionOverlay(
					mode: .review(plan),
					onConnect: { store.approveAutomation(tabId: tabId) },
					onConnectWithoutAutomation: {
						store.suppressAutomation(tabId: tabId)
					},
					onEditHost: editHostAction(for: tab.host)
				)
			case .blocked(let reason):
				HostAutomationConnectionOverlay(
					mode: .blocked(reason),
					onConnect: {},
					onConnectWithoutAutomation: {
						store.suppressAutomation(tabId: tabId)
					},
					onEditHost: editHostAction(for: tab.host)
				)
			case .inactive, .approved, .suppressed:
				EmptyView()
			}
		} else {
			EmptyView()
		}
	}

	@ViewBuilder
	private func environmentStatus(for tab: SessionStore.Tab) -> some View {
		if case .connected = tab.state,
		   case .sentUnverified(let names) = tab.environmentRequestStatus {
			VStack {
				HStack(spacing: 8) {
					Image(systemName: "questionmark.circle")
					Text(
						"Environment sent for \(names.joined(separator: ", ")); OpenSSH cannot confirm server acceptance."
					)
					.font(.caption)
					.textSelection(.enabled)
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.background(.regularMaterial, in: Capsule())
				.accessibilityElement(children: .combine)
				.accessibilityLabel(
					"Host environment sent but server acceptance is unverified"
				)
				Spacer()
			}
			.padding(12)
			.allowsHitTesting(false)
		}
	}

	@ViewBuilder
	private func surfaceOrPlaceholder(for tab: SessionStore.Tab) -> some View {
		if TerminalPaneSurfacePolicy.retainsSurface(for: tab) {
				TerminalSurfaceRepresentable(
					tabId: tabId,
					backgroundTransparencyEnabled: backgroundTransparencyEnabled,
					isFocused: isFocused,
					onFocus: onFocus
				)
			.id("\(tabId)-\(tab.surfaceGeneration)")
		} else {
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
			ReconnectOverlay(
				attempt: attempt,
				nextRetryAt: nextRetryAt,
				host: host,
				chain: chain,
				onRetry: { store.retryTab(tabId: tabId) },
				onStop: { store.stopReconnect(tabId: tabId) },
				onClosePane: onClosePane
			)
		case .failed(let kind) where kind == .cleanExit || kind == .connectionDropped:
			DisconnectedPaneOverlay(
				failure: kind,
				host: host,
				onRetry: { store.retryTab(tabId: tabId) },
				onEditHost: editHostAction(for: host),
				onClosePane: onClosePane
			)
		case .failed(let kind):
			FailureOverlay(
				failure: kind,
				host: host,
				chain: chain,
				onRetry: { store.retryTab(tabId: tabId) },
				onEditHost: editHostAction(for: host),
				onClosePane: onClosePane
			)
		case .idle, .connected:
			EmptyView()
		}
	}

	private func editHostAction(for host: SSHHost) -> (() -> Void)? {
		guard store.hosts.contains(where: { $0.id == host.id }) else { return nil }
		return {
			NotificationCenter.default.post(
				name: .catermEditHostRequested,
				object: WindowCommandScope.activeTargetWindow,
				userInfo: [CatermEditHostRequestedKeys.hostId: host.id]
			)
		}
	}
}

enum TerminalPaneSurfacePolicy {
	static func retainsSurface(for tab: SessionStore.Tab) -> Bool {
		tab.surfaceGeneration > 0
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
				surface.onSessionLive = {
					[weak probeReference] in
					MainActor.assumeIsolated {
						probeReference?.sessionDidBecomeLive()
					}
				}
				surfaceRegistry?.register(surface, for: capturedTabId)
				let hostId = store?.hostId(for: capturedTabId).map { HostId($0.uuidString) }
				surface.applyConfig(hostId: hostId)
			},
			onEvent: { [weak store, weak view] event in
				switch event {
				case .provisional:
					store?.markConnectedProvisional(tabId: capturedTabId)
				case .confirmed:
					guard let store, let surface = view?.surface else {
						return
					}
					HostAutomationLiveSessionActivator.activate(
						store: store,
						tabID: capturedTabId,
						generation: capturedGeneration,
						execute: surface.executeSnippet
					)
					store.markConnected(tabId: capturedTabId)
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

private struct HostAutomationConnectionOverlay: View {
	enum Mode {
		case review(HostAutomationSessionPlan)
		case blocked(HostAutomationUnresolvedReason)
	}

	let mode: Mode
	let onConnect: () -> Void
	let onConnectWithoutAutomation: () -> Void
	let onEditHost: (() -> Void)?

	var body: some View {
		ZStack {
			Color.black.opacity(0.52)
				.ignoresSafeArea()

			VStack(alignment: .leading, spacing: 16) {
				Label(title, systemImage: icon)
					.font(.title3.weight(.semibold))

				content

				HStack {
					if case .blocked = mode, let onEditHost {
						Button("Edit Host", action: onEditHost)
					}
					Spacer()
					Button(
						"Connect Without Automation",
						action: onConnectWithoutAutomation
					)
					if case .review = mode {
						Button("Run Automation & Connect", action: onConnect)
							.buttonStyle(.borderedProminent)
							.keyboardShortcut(.defaultAction)
					}
				}
			}
			.padding(20)
			.frame(maxWidth: 560)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
			.overlay {
				RoundedRectangle(cornerRadius: 16)
					.stroke(.separator.opacity(0.7))
			}
			.shadow(radius: 24, y: 8)
			.padding(24)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(title)
	}

	private var title: String {
		switch mode {
		case .review:
			"Review Host Automation"
		case .blocked:
			"Automation Needs Attention"
		}
	}

	private var icon: String {
		switch mode {
		case .review:
			"checklist"
		case .blocked:
			"exclamationmark.triangle"
		}
	}

	@ViewBuilder
	private var content: some View {
		switch mode {
		case .review(let plan):
			if let command = plan.startupCommand {
				VStack(alignment: .leading, spacing: 6) {
					Text(plan.startupSnippetName ?? "Startup Command")
						.font(.subheadline.weight(.medium))
					ScrollView {
						Text(command)
							.font(.system(.body, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(maxHeight: 180)
					.padding(10)
					.background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
				}
			}
			if !plan.environment.isEmpty {
				VStack(alignment: .leading, spacing: 6) {
					Text("Remote Environment")
						.font(.subheadline.weight(.medium))
					ForEach(plan.environment) { variable in
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Text(variable.name)
								.font(.system(.body, design: .monospaced).weight(.medium))
							Text(variable.value)
								.font(.system(.body, design: .monospaced))
								.foregroundStyle(.secondary)
								.textSelection(.enabled)
							Spacer()
						}
					}
				}
			}
		case .blocked(let reason):
			Text(reason.message)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}
