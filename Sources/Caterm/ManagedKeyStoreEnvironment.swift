import ManagedKeyStore
import SwiftUI

/// Environment plumbing for the app-wide `ManagedKeyStore` instance
/// (created once in `CatermApp.init`). ManagedKeyStore is an actor, not
/// an ObservableObject, so it rides `@Environment` rather than
/// `@EnvironmentObject`.
private struct ManagedKeyStoreKey: EnvironmentKey {
	/// Fallback for previews / detached view trees — same directory the
	/// app instance uses, so behavior stays consistent even if a view
	/// misses the injection point.
	static let defaultValue = ManagedKeyStore()
}

extension EnvironmentValues {
	var managedKeyStore: ManagedKeyStore {
		get { self[ManagedKeyStoreKey.self] }
		set { self[ManagedKeyStoreKey.self] = newValue }
	}
}
