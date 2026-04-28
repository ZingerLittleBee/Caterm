import SessionStore
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
	let tabId: UUID

	var body: some View {
		ZStack {
			if let tab = store.tabs.first(where: { $0.id == tabId }) {
				TerminalSurfaceRepresentable(tabId: tabId, generation: tab.surfaceGeneration)
					.id("\(tabId)-\(tab.surfaceGeneration)")
				if case let .reconnecting(attempt, nextRetryAt) = tab.state {
					ReconnectOverlay(attempt: attempt, nextRetryAt: nextRetryAt)
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
/// The `generation` parameter is forwarded as `.id(...)` from `TerminalContainerView`
/// so SwiftUI destroys and recreates this representable (and thus the underlying
/// `GhosttySurfaceNSView`) when `surfaceGeneration` increments on reconnect.
struct TerminalSurfaceRepresentable: NSViewRepresentable {
	@EnvironmentObject var store: SessionStore
	let tabId: UUID
	let generation: Int

	func makeNSView(context _: Context) -> GhosttySurfaceNSView {
		guard let cfg = store.surfaceConfig(for: tabId) else {
			return GhosttySurfaceNSView(command: nil)
		}
		let view = GhosttySurfaceNSView(command: cfg.command, env: cfg.env)
		store.markConnecting(tabId: tabId)

		let capturedTabId = tabId
		Task { @MainActor [weak store, weak view] in
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
