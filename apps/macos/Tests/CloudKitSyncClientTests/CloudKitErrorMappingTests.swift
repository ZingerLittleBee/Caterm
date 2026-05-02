import CloudKit
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CloudKitErrorMappingTests: XCTestCase {
    func testNotAuthenticatedMapsToNotSignedIn() {
        let mapped = CloudKitErrorMapping.map(CKError(.notAuthenticated))
        XCTAssertEqual(mapped, .notSignedIn)
    }

    func testServerRecordChangedMapsTo409() {
        let mapped = CloudKitErrorMapping.map(CKError(.serverRecordChanged))
        if case let .http(status, _) = mapped {
            XCTAssertEqual(status, 409)
        } else {
            XCTFail("expected .http(409, _), got \(mapped)")
        }
    }

    func testNetworkUnavailableMapsToHttpStatusZero() {
        let mapped = CloudKitErrorMapping.map(CKError(.networkUnavailable))
        if case let .http(status, _) = mapped {
            XCTAssertEqual(status, 0)
        } else {
            XCTFail("expected .http(0, _), got \(mapped)")
        }
    }

    func testNonCKErrorMapsToHttpStatusZero() {
        struct OtherError: Error {}
        let mapped = CloudKitErrorMapping.map(OtherError())
        if case .http(status: 0, _) = mapped { return }
        XCTFail("expected .http(0, _), got \(mapped)")
    }
}
