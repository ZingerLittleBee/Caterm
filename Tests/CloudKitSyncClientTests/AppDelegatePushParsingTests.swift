import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class AppDelegatePushParsingTests: XCTestCase {
	func testRemoteNotificationWithMatchingSubscriptionIDIsRecognized() {
		// CKNotification requires "nt" (notification type) + "qry.sid" to populate subscriptionID.
		// The flat "ck.sid" shape does not populate the property; use the real CloudKit payload shape.
		let userInfo: [String: Any] = [
			"ck": [
				"nt": 1,
				"qry": ["sid": CloudKitPushNames.hostSubscriptionID]
			]
		]
		XCTAssertTrue(parsePushUserInfo(userInfo))
	}

	func testRemoteNotificationWithDifferentSubscriptionIDIsIgnored() {
		// Deliberately uses the flat "ck.sid" shape, which CKNotification cannot parse → false regardless of sid value.
		let userInfo: [String: Any] = [
			"ck": ["sid": "some.other.subscription"]
		]
		XCTAssertFalse(parsePushUserInfo(userInfo))
	}

	func testMalformedUserInfoReturnsFalse() {
		XCTAssertFalse(parsePushUserInfo(["random": "stuff"]))
	}

	func testSnippetNotificationRoutesToSnippetLane() {
		let userInfo: [String: Any] = [
			"ck": [
				"nt": 1,
				"qry": ["sid": CloudKitPushNames.snippetSubscriptionID],
			]
		]

		XCTAssertEqual(cloudKitPushKind(userInfo), .snippet)
		XCTAssertFalse(parsePushUserInfo(userInfo))
	}
}
