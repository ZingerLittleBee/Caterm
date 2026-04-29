import XCTest
import HostSyncStore
@testable import Caterm

@MainActor
final class SyncStatusRowTests: XCTestCase {
    // MARK: - Formatters

    func testFormatLastSyncedHandlesNil() {
        XCTAssertEqual(formatLastSynced(nil, now: Date()), "Never synced")
    }

    func testFormatLastSyncedShowsJustNowUnderOneMinute() {
        let now = Date()
        let recent = now.addingTimeInterval(-30)
        XCTAssertEqual(formatLastSynced(recent, now: now), "Synced just now",
            "Under 60 s elapsed renders 'Synced just now', not '0m ago'")
    }

    func testFormatRelativeShortBucketing() {
        let now = Date()
        XCTAssertEqual(formatRelativeShort(since: now.addingTimeInterval(-30), now: now), "now",
            "Under 60 s renders 'now'")
        XCTAssertEqual(formatRelativeShort(since: now.addingTimeInterval(-180), now: now), "3m",
            "180 s renders as '3m'")
        XCTAssertEqual(formatRelativeShort(since: now.addingTimeInterval(-7200), now: now), "2h",
            "7200 s renders as '2h'")
    }

    // MARK: - Tap routing

    func testTapActionOpensSettingsForSignedOutAndAuthFailing() {
        XCTAssertEqual(tapAction(for: .signedOut), .openSettings)
        XCTAssertEqual(
            tapAction(for: .failing(reason: .auth, since: Date())),
            .openSettings,
            ".auth failure has only one useful action (sign in) — direct sheet")
    }

    func testTapActionTogglesPopoverForHealthyAndOtherFailing() {
        XCTAssertEqual(
            tapAction(for: .healthy(lastSyncedAt: Date())),
            .togglePopover)
        XCTAssertEqual(
            tapAction(for: .healthy(lastSyncedAt: nil)),
            .togglePopover,
            "Even 'Never synced' healthy state opens popover (Sync Now button is the affordance)")
        XCTAssertEqual(
            tapAction(for: .failing(reason: .other, since: Date())),
            .togglePopover,
            ".other failure shows popover with Try Again + Open Settings")
    }

    func testTapActionTogglesPopoverForSyncing() {
        XCTAssertEqual(tapAction(for: .syncing), .togglePopover,
            "Syncing state opens popover with static 'Syncing…' text")
    }
}
