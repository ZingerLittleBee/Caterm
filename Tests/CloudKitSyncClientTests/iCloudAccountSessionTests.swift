import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class FakeAccountStatusProvider: CKAccountStatusProviding, @unchecked Sendable {
    var status: CKAccountStatus = .couldNotDetermine
    var error: Error?
    func accountStatus() async throws -> CKAccountStatus {
        if let e = error { throw e }
        return status
    }
}

@MainActor
final class iCloudAccountSessionTests: XCTestCase {
    func testInitialIsSignedInIsFalseUntilRefreshCompletes() {
        let provider = FakeAccountStatusProvider()
        provider.status = .available
        let sut = iCloudAccountSession(provider: provider)
        XCTAssertFalse(sut.isSignedIn,
            "Pre-refresh value defaults to false — accountStatus is async.")
    }

    func testRefreshAvailableFlipsIsSignedInTrue() async {
        let provider = FakeAccountStatusProvider()
        provider.status = .available
        let sut = iCloudAccountSession(provider: provider)
        await sut.refresh()
        XCTAssertTrue(sut.isSignedIn)
    }

    func testRefreshNoAccountKeepsIsSignedInFalse() async {
        let provider = FakeAccountStatusProvider()
        provider.status = .noAccount
        let sut = iCloudAccountSession(provider: provider)
        await sut.refresh()
        XCTAssertFalse(sut.isSignedIn)
    }

    func testRefreshErrorKeepsPreviousValue() async {
        let provider = FakeAccountStatusProvider()
        provider.status = .available
        let sut = iCloudAccountSession(provider: provider)
        await sut.refresh()
        XCTAssertTrue(sut.isSignedIn)
        provider.error = CKError(.networkUnavailable)
        await sut.refresh()
        XCTAssertTrue(sut.isSignedIn,
            "Errors during refresh must not flip the cached value — that would cause spurious sign-out flicker on transient CloudKit network blips.")
    }
}
