import SessionStore
import SwiftUI
import TerminalEngine

/// Renders one `SessionStore.Tab`'s libghostty surface. Independent of the
/// connect-flow UI; just consumes a `tabId` and binds to its surface, wiring
/// `markConnecting / markConnected / markChildExited` for state tracking.
///
/// `GhosttySurfaceNSView.surface` is built lazily inside `viewDidMoveToWindow`,
/// so we poll briefly until it's available before attaching the `onChildExit`
/// callback.
struct TerminalContainerView: NSViewRepresentable {
	@EnvironmentObject var store: SessionStore
	let tabId: UUID

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
