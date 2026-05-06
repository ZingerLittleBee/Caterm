import CloudKit
import Foundation

public enum CloudKitPushNames {
	public static let hostSubscriptionID = "caterm.host.changes.v1"
	public static let snippetSubscriptionID = "com.caterm.app.snippet-changes"
	public static let snippetZoneName = "Snippets"
}

/// Returns true iff `userInfo` is a CloudKit silent-push payload whose
/// subscriptionID matches the Host subscription. Used by AppDelegate.
public func parsePushUserInfo(_ userInfo: [String: Any]) -> Bool {
	guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
		return false
	}
	return note.subscriptionID == CloudKitPushNames.hostSubscriptionID
}
