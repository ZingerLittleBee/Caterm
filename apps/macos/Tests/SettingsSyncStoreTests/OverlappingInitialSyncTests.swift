import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class OverlappingInitialSyncTests: XCTestCase {
	private func realLocal(font: Int, revision: String) -> CatermSettings {
		var s = CatermSettings()
		s.global.fontSize = font
		s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		s.revision = revision
		return s
	}

	// Two .initialSyncChange notifications in quick succession spawn two grace
	// tasks. Without supersede semantics, the older task wakes first and clears
	// inInitialSyncGrace while the newer task's grace window is still open —
	// re-opening the C1 leak: a user edit in that gap takes the unfreeze branch
	// and pushes pre-grace local state.
	func test_overlappingInitialSyncChange_olderTaskDoesNotClearGraceBarrier() async throws {
		let kvs = FakeKVS()
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("ovr-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "a-rev"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "ovr-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(150)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()

		// Post #1: starts grace task A (will naturally wake at T0+150ms).
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]
		)
		try await Task.sleep(for: .milliseconds(60))
		XCTAssertTrue(sync.testPushSuspended, "post #1 grace must be active")

		// Post #2 ~60ms later: starts grace task B (wakes at T0+210ms).
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]
		)

		// Sleep past task A's natural wake (T0+150ms) but before task B's
		// (T0+210ms). At this instant — without supersede — task A has cleared
		// the flag.
		try await Task.sleep(for: .milliseconds(110))

		XCTAssertTrue(sync.testPushSuspended,
			"task B's grace must still be active; the older overlapping grace task must not clear inInitialSyncGrace")
	}

	// A non-grace pull (e.g. .serverChange) arriving mid-grace must clear the
	// grace flag so it doesn't leak forever. Without the supersede fix, leaving
	// the flag set during a serverChange would freeze user-edit pushes
	// indefinitely.
	func test_serverChangeDuringGrace_clearsBarrierImmediately() async throws {
		let kvs = FakeKVS()
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("ovr-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "a-rev"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "ovr-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") }
		)
		sync.testInitialSyncTimeout = .milliseconds(10)
		sync.testInitialSyncGrace = .milliseconds(500)
		sync.installLifecycleObservers()
		await sync.startSync()
		await sync.testWaitForBootDecision()

		// Open the grace barrier.
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]
		)
		try await Task.sleep(for: .milliseconds(20))
		XCTAssertTrue(sync.testPushSuspended, "grace open")

		// Now a serverChange supersedes — flag must clear (otherwise no user
		// edit can ever push again until the grace task naturally completes).
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange]
		)
		try await Task.sleep(for: .milliseconds(50))

		// classifyAndApply has run; sync should be back to its post-decision
		// state (.active in this scenario — local-only data, cloud absent).
		XCTAssertEqual(sync.syncState, .active,
			"serverChange supersedes grace; classifyAndApply runs and lands the new state")
		XCTAssertFalse(sync.testPushSuspended,
			"non-grace pull must clear inInitialSyncGrace so user edits aren't frozen indefinitely")
	}
}
