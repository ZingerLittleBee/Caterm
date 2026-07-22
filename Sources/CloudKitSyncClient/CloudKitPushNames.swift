import CloudKit
import Foundation

public enum CloudKitPushNames {
	public static let hostSubscriptionID = "caterm.host.changes.v1"
	public static let snippetSubscriptionID = "com.caterm.app.snippet-changes"
	public static let snippetZoneName = "Snippets"
}

public enum CatermCloudKitPushKind: Equatable, Sendable {
	case host
	case snippet
}

public func cloudKitPushKind(
	_ userInfo: [String: Any]
) -> CatermCloudKitPushKind? {
	guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
		return nil
	}
	switch note.subscriptionID {
	case CloudKitPushNames.hostSubscriptionID:
		return .host
	case CloudKitPushNames.snippetSubscriptionID:
		return .snippet
	default:
		return nil
	}
}

/// Returns true iff `userInfo` is a CloudKit silent-push payload whose
/// subscriptionID matches the Host subscription. Used by AppDelegate.
public func parsePushUserInfo(_ userInfo: [String: Any]) -> Bool {
	cloudKitPushKind(userInfo) == .host
}
