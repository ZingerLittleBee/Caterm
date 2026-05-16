import Foundation

public extension Notification.Name {
	/// Posted by `FailureOverlay`'s "Edit Host" button. `HostListSidebar`
	/// observes this and pops the existing edit sheet for the host. Same
	/// pattern as `catermHostCredentialMaterialChanged` in SessionStore.
	static let catermEditHostRequested = Notification.Name("catermEditHostRequested")
}

public enum CatermEditHostRequestedKeys {
	/// `UUID` — local host id whose form should be opened.
	public static let hostId = "hostId"
}
