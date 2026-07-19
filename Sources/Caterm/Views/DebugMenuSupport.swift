#if DEBUG
import Foundation
import SessionStore
import SSHCommandBuilder

/// Debug-only entry points used to give UI automation (Computer Use, cliclick,
/// osascript) a stable AX hook into the host-list connect path. Gated behind
/// `#if DEBUG` so it never ships in release builds.
///
/// The Debug menu's "Open Tab for First Host" item posts
/// `.catermDebugOpenFirstHost`; `HostListSidebar` listens and feeds the picked
/// host back through the real `connect(_:)` → `resolveConnectIntent` → either
/// `.openTab` or `.promptCredentials` — same path as a sidebar double-click.

extension Notification.Name {
	static let catermDebugOpenFirstHost =
		Notification.Name("CatermDebugOpenFirstHostNotification")
}

/// Pick the host the debug menu should hand to `connect(_:)`. Prefers a host
/// that does NOT need credential setup so the result is a real opened tab
/// (which is what 4.x terminal-injection tests need). Falls back to the first
/// host overall so testers still see the credential sheet — a diagnostic, not
/// a silent no-op — when every host is locked.
@MainActor
func debugPickConnectTarget(in store: SessionStore) async -> SSHHost? {
	for host in store.hosts {
		let requiresSetup = await store.needsCredentialSetup(host)
		if !requiresSetup { return host }
	}
	return store.hosts.first
}
#endif
