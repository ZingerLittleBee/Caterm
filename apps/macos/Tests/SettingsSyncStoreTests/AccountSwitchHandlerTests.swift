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

    private func cloud(revision: String, version: Int = 2) -> SyncableSettings {
        var c = SyncableSettings(from: realEdits(revision: revision))
        c.version = version
        return c
    }

    func test_yHasData_schemaCompatible_returnsForceApply_acceptsIdentity() {
        // Local revision NEWER than Y's — proves no LWW comparison happens.
        let d = AccountSwitchHandler.handle(
            local: realEdits(revision: "z"),
            cloudY: cloud(revision: "a")
        )
        XCTAssertEqual(d.action.tag, "forceApply")
        XCTAssertFalse(d.finalSuspensionState)
        XCTAssertTrue(d.acceptIdentity)
    }

    func test_yHasData_schemaNewer_returnsRejectMerge_doesNotAcceptIdentity() {
        let d = AccountSwitchHandler.handle(
            local: realEdits(),
            cloudY: cloud(revision: "z", version: 3)
        )
        XCTAssertEqual(d.action, .rejectMerge(reason: RejectReason.schemaNewerThanLocal))
        XCTAssertTrue(d.finalSuspensionState, "stay suspended; don't pollute Y")
        XCTAssertFalse(d.acceptIdentity, "do not persist Y identity — we have no readable Y data")
    }

    func test_yEmpty_returnsSuspendUntilFirstEdit_doesNotAcceptIdentity() {
        let d = AccountSwitchHandler.handle(local: realEdits(), cloudY: Optional<SyncableSettings>.none)
        XCTAssertEqual(d.action, .suspendUntilFirstEdit)
        XCTAssertTrue(d.finalSuspensionState)
        XCTAssertFalse(d.acceptIdentity, "token persists later, at unfreeze + push moment")
    }
}
