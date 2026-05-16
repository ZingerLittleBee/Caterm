import Foundation

public extension Notification.Name {
	/// Posted by SessionStore.setHostCredentialMaterial after hosts.json
	/// is persisted with credentialMaterialDirty=true. Listeners receive
	/// userInfo["hostId"] as UUID.
	static let catermHostCredentialMaterialChanged =
		Notification.Name("catermHostCredentialMaterialChanged")
}

public enum CatermHostCredentialMaterialChangedKeys {
	public static let hostId = "hostId"
}
