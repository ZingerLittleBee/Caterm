import Foundation
import SessionStore

@MainActor
enum HostAutomationLiveSessionActivator {
	static func activate(
		store: SessionStore,
		tabID: UUID,
		generation: Int,
		execute: (String) -> Void
	) {
		store.markAutomationSessionLive(
			tabId: tabID,
			generation: generation
		)
		guard let command = store.consumeStartupCommand(
			tabId: tabID,
			generation: generation
		) else {
			return
		}
		execute(command)
	}
}
