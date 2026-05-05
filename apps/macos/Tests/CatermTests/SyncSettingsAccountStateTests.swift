import XCTest
@testable import Caterm
@testable import HostSyncStore
@testable import ServerSyncClient

final class SyncSettingsAccountStateTests: XCTestCase {
    func testAccountStateSignedOut() {
        XCTAssertEqual(accountState(isSignedIn: false), .signedOut)
    }

    func testAccountStateSignedIn() {
        XCTAssertEqual(accountState(isSignedIn: true), .signedIn)
    }

    func testFailureDetailsOnlyShowWhenSignedIn() {
        XCTAssertTrue(shouldShowSyncFailureDetails(for: .signedIn))
        XCTAssertFalse(shouldShowSyncFailureDetails(for: .signedOut))
    }

    // MARK: - formatLastSyncedAt (spec §3.3 / §7.5)

    func testFormattedLastSyncedAtNeverWhenNil() {
        XCTAssertEqual(formatLastSyncedAt(nil), "Never synced")
    }

    func testFormattedLastSyncedAtRelative() {
        // 2 minutes ago — RelativeDateTimeFormatter should produce a
        // non-empty, locale-dependent phrase. We don't pin specific
        // wording (en-US "2 minutes ago" vs zh-CN "2分钟前"), only that
        // it's not the "Never synced" sentinel.
        let twoMinutesAgo = Date().addingTimeInterval(-120)
        let result = formatLastSyncedAt(twoMinutesAgo)
        XCTAssertFalse(result.isEmpty,
            "Relative format must produce non-empty output")
        XCTAssertNotEqual(result, "Never synced",
            "Non-nil date must produce relative phrase, not the nil sentinel")
    }
}
