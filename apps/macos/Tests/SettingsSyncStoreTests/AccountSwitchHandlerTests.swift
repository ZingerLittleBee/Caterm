import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class AccountSwitchHandlerTests: XCTestCase {
    private func realEdits(revision: String = "local-x") -> CatermSettings {
        var s = CatermSettings()
        s.global = CatermSettings.defaultsSeed
        s.global.fontSize = 99
        s.seededByDefault = false
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        s.revision = revision
        s.version = 2
        return s
    }

    private func cloud(revision: String, version: Int = 2) -> CloudReadResult {
        var c = SyncableSettings(from: realEdits(revision: revision))
        c.version = version
        return .decoded(c)
    }

    private struct DummyError: Error {}

    func test_yHasData_schemaCompatible_returnsForceApply_acceptsIdentity() {
        // Local revision NEWER than Y's — proves no LWW comparison happens.
        let d = AccountSwitchHandler.handle(
            local: realEdits(revision: "z"),
            cloudY: cloud(revision: "a")
        )
        XCTAssertEqual(d.action.tag, "forceApply")
        XCTAssertEqual(d.finalState, .active)
        XCTAssertTrue(d.acceptIdentity)
    }

    func test_yHasData_schemaNewer_returnsRejectMerge_quarantined() {
        let d = AccountSwitchHandler.handle(
            local: realEdits(),
            cloudY: cloud(revision: "z", version: 3)
        )
        XCTAssertEqual(d.action, .rejectMerge(reason: .schemaNewerThanLocal))
        XCTAssertEqual(d.finalState, .quarantined,
            "schema-newer Y must quarantine; the next pull retries when cloud catches up")
        XCTAssertFalse(d.acceptIdentity, "do not persist Y identity — we have no readable Y data")
    }

    func test_yEmpty_returnsSuspendUntilFirstEdit_doesNotAcceptIdentity() {
        let d = AccountSwitchHandler.handle(local: realEdits(), cloudY: .absent)
        XCTAssertEqual(d.action, .suspendUntilFirstEdit)
        XCTAssertEqual(d.finalState, .suspendUntilFirstEdit)
        XCTAssertFalse(d.acceptIdentity, "token persists later, at unfreeze + push moment")
    }

    func test_yUnreadable_returnsRejectMerge_quarantined_doesNotAcceptIdentity() {
        let d = AccountSwitchHandler.handle(local: realEdits(), cloudY: .unreadable(DummyError()))
        XCTAssertEqual(d.action, .rejectMerge(reason: .unreadableCloud))
        XCTAssertEqual(d.finalState, .quarantined,
            "Y present-but-undecodable must NOT route to the empty-Y suspendUntilFirstEdit path; first user edit would push X data into Y")
        XCTAssertFalse(d.acceptIdentity)
    }
}
