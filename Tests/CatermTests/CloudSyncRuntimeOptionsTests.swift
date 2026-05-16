import XCTest
@testable import Caterm

final class CloudSyncRuntimeOptionsTests: XCTestCase {
	func testCloudSyncIsDisabledWhenEnvironmentFlagIsTruthy() {
		XCTAssertTrue(CloudSyncRuntimeOptions.cloudSyncDisabled(
			environment: ["CATERM_DISABLE_CLOUD_SYNC": "1"]
		))
		XCTAssertTrue(CloudSyncRuntimeOptions.cloudSyncDisabled(
			environment: ["CATERM_DISABLE_CLOUD_SYNC": "true"]
		))
		XCTAssertTrue(CloudSyncRuntimeOptions.cloudSyncDisabled(
			environment: ["CATERM_DISABLE_CLOUD_SYNC": "YES"]
		))
	}

	func testCloudSyncStaysEnabledWhenEnvironmentFlagIsAbsentOrFalsey() {
		XCTAssertFalse(CloudSyncRuntimeOptions.cloudSyncDisabled(environment: [:]))
		XCTAssertFalse(CloudSyncRuntimeOptions.cloudSyncDisabled(
			environment: ["CATERM_DISABLE_CLOUD_SYNC": "0"]
		))
		XCTAssertFalse(CloudSyncRuntimeOptions.cloudSyncDisabled(
			environment: ["CATERM_DISABLE_CLOUD_SYNC": "false"]
		))
	}
}
