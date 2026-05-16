import XCTest
import ServerSyncClient
@testable import HostSyncStore

final class CloudKitAuthShapeTests: XCTestCase {
	/// Regression guard: if anyone changes ServerSyncError or
	/// isAuthShape such that .notSignedIn is no longer auth-shaped,
	/// the CloudKit pipeline silently degrades from "show recovery
	/// affordance" to "generic failure" — catch that here.
	func testNotSignedInIsAuthShape() {
		XCTAssertTrue(isAuthShape(.notSignedIn))
	}
}
