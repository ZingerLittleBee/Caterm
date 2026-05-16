import Combine
import CredentialSyncStore
import XCTest
import UserNotifications
@testable import HostSyncStore
@testable import SessionStore
@testable import SSHCommandBuilder
@testable import ServerSyncClient
@testable import KeychainStore

@MainActor
final class HostSyncStoreFailureTests: XCTestCase {
    private enum SyncTestError: Error {
        case boom
    }

    private struct WaitForTimeout: Error {}

    var sut: HostSyncStore!
    var fakeClient: FakeServerSyncClient!
    var fakeAuth: FakeAuthSession!
    var sessionStore: SessionStore!
    var prefs: SyncPreferences!
    var isolatedDefaults: UserDefaults!
    var fakeNotifications: FakeNotificationCenter!
    var tmpHostsURL: URL!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        tmpHostsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caterm-failure-\(UUID()).json")
        let kc = KeychainStore(service: "com.caterm.test.\(UUID().uuidString)",
                               accessGroup: nil)
        sessionStore = SessionStore(askpassPath: "/x", knownHostsCaterm: "/A",
                                     knownHostsUser: "/B", accessGroup: nil,
                                     hostsURL: tmpHostsURL, keychain: kc)
        fakeClient = FakeServerSyncClient()
        fakeAuth = FakeAuthSession(isSignedIn: true)
        defaultsSuiteName = "caterm-test-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        isolatedDefaults.set(true, forKey: "catermPeriodicSyncEnabled")
        isolatedDefaults.set(true, forKey: "catermNotifyOnFailureEnabled")
        prefs = SyncPreferences(defaults: isolatedDefaults)
        fakeNotifications = FakeNotificationCenter()
        sut = HostSyncStore(client: fakeClient,
                            sessionStore: sessionStore,
                            authSession: fakeAuth,
                            preferences: prefs,
                            credentialSync: CredentialSyncPreferencesStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
                            debounceInterval: 0.05,
                            userDefaults: isolatedDefaults,
                            notificationCenter: fakeNotifications)
    }

    override func tearDown() async throws {
        sut = nil
        try? FileManager.default.removeItem(at: tmpHostsURL)
        if let defaultsSuiteName {
            isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        fakeNotifications = nil
        isolatedDefaults = nil
        prefs = nil
        fakeAuth = nil
        fakeClient = nil
        sessionStore = nil
        tmpHostsURL = nil
        defaultsSuiteName = nil
    }

    // MARK: - Persistence

    func testLastSyncAttemptedAt_persistedAcrossInit() async throws {
        fakeClient.listHostsError = SyncTestError.boom
        _ = try? await sut.sync()

        let attempted = try XCTUnwrap(sut.lastSyncAttemptedAt)
        await rebuildSUT()

        let hydrated = try XCTUnwrap(sut.lastSyncAttemptedAt)
        XCTAssertEqual(hydrated.timeIntervalSince1970,
                       attempted.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testLastSyncAttemptedAt_writtenAtStartOfPerformSync() async throws {
        XCTAssertNil(sut.lastSyncAttemptedAt)
        fakeClient.listHostsDelay = 0.2

        let task = Task<Void, Error> { try await self.sut.sync() }
        try await waitFor(timeout: 1.0) { self.sut.lastSyncAttemptedAt != nil }

        XCTAssertGreaterThanOrEqual(fakeClient.listCallCount, 1)
        XCTAssertNotNil(sut.lastSyncAttemptedAt)
        XCTAssertNotNil(isolatedDefaults.object(forKey: "catermLastSyncAttemptedAt") as? Date)

        try await task.value
    }

    func testLastSyncErrorKind_notPersistedAcrossInit() async throws {
        fakeClient.listHostsError = SyncTestError.boom
        _ = try? await sut.sync()
        XCTAssertEqual(sut.lastSyncErrorKind, .other)

        await rebuildSUT()

        XCTAssertNil(sut.lastSyncErrorKind)
    }

    func testLastSyncErrorKind_clearedOnSuccess() async throws {
        fakeClient.listHostsError = SyncTestError.boom
        _ = try? await sut.sync()
        XCTAssertEqual(sut.lastSyncErrorKind, .other)

        fakeClient.listHostsError = nil
        try await sut.sync()

        XCTAssertNil(sut.lastSyncErrorKind)
    }

    // MARK: - Edge detection

    func testNotification_firedOnNormalToFailingEdge_autoSync_notifyEnabled() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom

        sut.syncIfSignedIn()

        try await waitFor(timeout: 1.0) { await self.notificationCount() == 1 }
        XCTAssertEqual(sut.lastSyncErrorKind, .other)
        XCTAssertNotNil(sut.failingSince)
    }

    func testNotification_notFired_onConsecutiveFailures() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom

        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { await self.notificationCount() == 1 }
        let firstAttempt = try XCTUnwrap(sut.lastSyncAttemptedAt)

        fakeClient.listHostsError = ServerSyncError.http(status: 401, body: "")
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) {
            guard let attempted = self.sut.lastSyncAttemptedAt else { return false }
            return attempted > firstAttempt && self.sut.lastSyncErrorKind == .auth
        }

        let count = await notificationCount()
        XCTAssertEqual(count, 1)
    }

    func testNotification_notFired_whenManualSync() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom

        _ = try? await sut.sync()

        let count = await notificationCount()
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(sut.failingSince)
    }

    func testNotification_notFired_whenToggleOff() async throws {
        isolatedDefaults.set(false, forKey: "catermNotifyOnFailureEnabled")
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = ServerSyncError.http(status: 500, body: "")

        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) {
            self.sut.lastSyncErrorKind == .other && self.sut.failingSince != nil
        }

        let count = await notificationCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(sut.lastSyncErrorKind, .other)
        XCTAssertNotNil(sut.failingSince)
    }

    func testNotification_notFired_whenSignedOutBeforeAutoFailureCompletes() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsDelay = 0.05
        fakeClient.listHostsErrorAfterDelay = SyncTestError.boom

        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.fakeClient.listCallCount == 1 }
        fakeAuth.isSignedIn = false

        try await waitFor(timeout: 1.0) { self.sut.lastSyncErrorKind == .other }

        let count = await notificationCount()
        XCTAssertEqual(count, 0)
    }

    func testNotification_notFired_onCancellationError() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = CancellationError()

        _ = try? await sut.sync()

        let count = await notificationCount()
        XCTAssertEqual(count, 0)
        XCTAssertNil(sut.lastSyncErrorKind)
        XCTAssertNil(sut.failingSince)
    }

    // MARK: - Failing since

    func testFailingSince_pinnedAcrossConsecutiveFailures() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom

        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.sut.failingSince != nil }
        let firstFailingSince = try XCTUnwrap(sut.failingSince)
        let firstAttempt = try XCTUnwrap(sut.lastSyncAttemptedAt)

        fakeClient.listHostsError = ServerSyncError.http(status: 401, body: "")
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) {
            guard let attempted = self.sut.lastSyncAttemptedAt else { return false }
            return attempted > firstAttempt && self.sut.lastSyncErrorKind == .auth
        }

        let secondFailingSince = try XCTUnwrap(sut.failingSince)
        XCTAssertEqual(secondFailingSince.timeIntervalSince1970,
                       firstFailingSince.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Recovery

    func testRecovery_silent_clearsFailingSince() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.sut.failingSince != nil }

        fakeClient.listHostsError = nil
        try await sut.sync()

        XCTAssertNil(sut.failingSince)
        XCTAssertNil(sut.lastSyncErrorKind)
        let count = await notificationCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Toggle side effect

    func testTogglePeriodicOff_resetsFailingState() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { self.sut.failingSince != nil }

        prefs.periodicSyncEnabled = false

        XCTAssertNil(sut.failingSince)
        XCTAssertNil(sut.lastSyncErrorKind)
        XCTAssertNil(sut.lastSyncAttemptedAt)
        XCTAssertNil(isolatedDefaults.object(forKey: "catermLastSyncAttemptedAt") as? Date)

        prefs.periodicSyncEnabled = true
        try await Task.sleep(nanoseconds: 10_000_000)

        let state = syncFailureState(
            now: Date(),
            lastSyncedAt: sut.lastSyncedAt,
            lastSyncAttemptedAt: sut.lastSyncAttemptedAt,
            lastSyncErrorKind: sut.lastSyncErrorKind,
            periodicSyncEnabled: prefs.periodicSyncEnabled,
            failingThreshold: 0
        )
        XCTAssertEqual(state, .normal)
    }

    // MARK: - Auth priority

    func testAuthFailure_setsErrorKindAuth() async throws {
        fakeClient.listHostsError = ServerSyncError.http(status: 401, body: "")

        _ = try? await sut.sync()

        XCTAssertEqual(sut.lastSyncErrorKind, .auth)
    }

    // MARK: - clearAuthError

    func testClearAuthError_clearsAuthState() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = ServerSyncError.authFailed(code: "UNAUTHORIZED",
                                                               message: "Session expired")
        _ = try? await sut.sync()
        XCTAssertEqual(sut.lastSyncErrorKind, .auth)
        XCTAssertNotNil(sut.failingSince)
        XCTAssertNotNil(sut.lastSyncAttemptedAt)

        sut.clearAuthError()

        XCTAssertNil(sut.lastSyncErrorKind)
        XCTAssertNil(sut.failingSince)
        XCTAssertNil(sut.lastSyncAttemptedAt)
        XCTAssertNil(isolatedDefaults.object(forKey: "catermLastSyncAttemptedAt") as? Date)
    }

    func testClearAuthError_resetsEdgeForNextFailure() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = ServerSyncError.authFailed(code: "UNAUTHORIZED",
                                                               message: "Session expired")
        sut.syncIfSignedIn()
        try await waitFor(timeout: 1.0) { await self.notificationCount() == 1 }

        sut.clearAuthError()
        fakeClient.listHostsError = SyncTestError.boom
        sut.syncIfSignedIn()

        try await waitFor(timeout: 1.0) { await self.notificationCount() == 2 }
        XCTAssertEqual(sut.lastSyncErrorKind, .other)
    }

    func testClearAuthError_preservesNonAuthState() async throws {
        await seedOldSuccessfulSync()
        fakeClient.listHostsError = SyncTestError.boom
        _ = try? await sut.sync()
        XCTAssertEqual(sut.lastSyncErrorKind, .other)
        let attempted = try XCTUnwrap(sut.lastSyncAttemptedAt)
        let failingSince = try XCTUnwrap(sut.failingSince)

        sut.clearAuthError()

        XCTAssertEqual(sut.lastSyncErrorKind, .other)
        XCTAssertEqual(try XCTUnwrap(sut.lastSyncAttemptedAt).timeIntervalSince1970,
                       attempted.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sut.failingSince).timeIntervalSince1970,
                       failingSince.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNotNil(isolatedDefaults.object(forKey: "catermLastSyncAttemptedAt") as? Date)
    }

    private func rebuildSUT(periodicInterval: TimeInterval = 60) async {
        sut = nil
        prefs = SyncPreferences(defaults: isolatedDefaults)
        sut = HostSyncStore(client: fakeClient,
                            sessionStore: sessionStore,
                            authSession: fakeAuth,
                            preferences: prefs,
                            credentialSync: CredentialSyncPreferencesStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!),
                            debounceInterval: 0.05,
                            periodicInterval: periodicInterval,
                            userDefaults: isolatedDefaults,
                            notificationCenter: fakeNotifications)
        await Task.yield()
    }

    private func seedOldSuccessfulSync() async {
        isolatedDefaults.set(Date(timeIntervalSinceNow: -120), forKey: "catermLastSyncedAt")
        isolatedDefaults.removeObject(forKey: "catermLastSyncAttemptedAt")
        await rebuildSUT(periodicInterval: 60)
    }

    private func notificationCount() async -> Int {
        await fakeNotifications.requestsAdded.count
    }

    private func waitFor(timeout: TimeInterval,
                         _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitFor timeout after \(timeout)s")
        throw WaitForTimeout()
    }
}

actor FakeNotificationCenter: NotificationDelivering {
    var requestsAdded: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest) async throws {
        requestsAdded.append(request)
    }
}
