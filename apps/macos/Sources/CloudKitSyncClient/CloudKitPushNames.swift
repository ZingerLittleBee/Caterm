import Foundation

extension Notification.Name {
	/// Posted by AppDelegate.application(_:didReceiveRemoteNotification:)
	/// when a CKDatabaseSubscription notification matching the Host
	/// subscription ID arrives. Observed by HostSyncStore.
	public static let catermCloudKitHostChanged =
		Notification.Name("catermCloudKitHostChanged")
}

public enum CloudKitPushNames {
	public static let hostSubscriptionID = "caterm.host.changes.v1"
}
