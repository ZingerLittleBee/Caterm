import SessionStore
import SSHCommandBuilder

/// What `HostListSidebar.connect(_:)` should do for a given host. Extracted
/// from the view so it is unit-testable without a SwiftUI host. `@MainActor`
/// because `SessionStore` is `@MainActor`-isolated.
enum ConnectIntent: Equatable {
	case openTab
	case promptCredentials
}

@MainActor
func resolveConnectIntent(for host: SSHHost, in store: SessionStore) -> ConnectIntent {
	store.needsCredentialSetup(host) ? .promptCredentials : .openTab
}
