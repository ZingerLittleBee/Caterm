import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class StopSyncCancellationTests: XCTestCase {
	private func realLocal(font: Int, revision: String) -> CatermSettings {
		var s = CatermSettings()
		s.global.fontSize = font
		s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		s.revision = revision
		return s
	}

	// stopSync mid-boot must abort the pending decision: no apply, no token
	// persist, and (critically) no observer registration. Without cancellation
	// the boot task wakes from sleep, calls applyDecision, and re-installs the
	// observers stopSync just removed.
	func test_stopSync_duringBoot_abortsApplyAndDoesNotRegisterObservers() async throws {
		let kvs = FakeKVS()
		var cloud = CatermSettings()
		cloud.global.fontSize = 99
		cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloud.revision = "cloud-rev"
		kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)

		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("stop-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "a-rev"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "stop-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .milliseconds(200),
				initialSyncGrace: .zero
			)
		)
		sync.installLifecycleObservers()
		let startTask = Task { await sync.startSync() }

		// Boot is still in its initial-sync sleep. Stop now.
		try await Task.sleep(for: .milliseconds(30))
		sync.stopSync()
		await startTask.value

		// Wait well past the original boot timeout so any uncancelled task
		// would have woken up by now.
		try await Task.sleep(for: .milliseconds(300))

		// Apply must NOT have run.
		XCTAssertEqual(store.settings.global.fontSize, 17,
			"stopSync mid-boot must prevent applyDecision; cloud should not have been applied")
		XCTAssertEqual(tokenStore.loadPersisted(), .none,
			"stopSync mid-boot must prevent token persist")

		// Observers must NOT be installed. Drop a fresh blob and post a
		// serverChange — if the KVS observer is installed it would apply.
		var cloud2 = CatermSettings()
		cloud2.global.fontSize = 33
		cloud2.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloud2.revision = "cloud-2"
		kvs.set(try SettingsBlobCodec.encode(cloud2), forKey: SettingsSyncStore.kvsKey)
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange]
		)
		try await Task.sleep(for: .milliseconds(50))
		XCTAssertEqual(store.settings.global.fontSize, 17,
			"after stopSync, KVS observer must not be installed")
	}

	// stopSync mid-grace must cancel the pending classifyAndApply.
	func test_stopSync_duringInitialSyncGrace_cancelsClassifyAndApply() async throws {
		let kvs = FakeKVS()
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("stop-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "a-rev"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "stop-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let session = AlwaysSignedInSession()
		let sync = SettingsSyncStore(
			store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .milliseconds(10),
				initialSyncGrace: .milliseconds(120)
			)
		)
		sync.installLifecycleObservers()
		await sync.startSync()

		// Plant cloud data that classifyAndApply would otherwise apply.
		var cloud = CatermSettings()
		cloud.global.fontSize = 88
		cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
		cloud.revision = "cloud-rev"
		kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)

		// Trigger initial-sync grace.
		NotificationCenter.default.post(
			name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
			object: nil,
			userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]
		)
		try await Task.sleep(for: .milliseconds(20))
		XCTAssertTrue(sync.isPushSuspended, "grace barrier active")

		// Stop mid-grace.
		sync.stopSync()

		// Wait past the original grace duration. classifyAndApply must NOT run.
		try await Task.sleep(for: .milliseconds(200))
		XCTAssertEqual(store.settings.global.fontSize, 17,
			"stopSync mid-grace must abort classifyAndApply")
	}

	func test_stopThenRestart_oldGraceCannotMutateNewLifecycle() async throws {
		let kvs = FakeKVS()
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("restart-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "a-local"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "restart-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: AlwaysSignedInSession(),
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-A") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .milliseconds(10),
				initialSyncGrace: .milliseconds(150)
			)
		)
		sync.installLifecycleObservers()
		await sync.startSync()

		kvs.set(
			try SettingsBlobCodec.encode(realLocal(font: 22, revision: "m-old-grace")),
			forKey: SettingsSyncStore.kvsKey
		)
		postKVSExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
		try await Task.sleep(for: .milliseconds(20))
		sync.stopSync()

		kvs.set(
			try SettingsBlobCodec.encode(realLocal(font: 33, revision: "n-new-lifecycle")),
			forKey: SettingsSyncStore.kvsKey
		)
		await sync.startSync()
		XCTAssertEqual(store.settings.global.fontSize, 33)

		// If the cancelled grace task still owns the restarted lifecycle, it
		// will wake later, re-read this blob, and overwrite the accepted value.
		kvs.set(
			try SettingsBlobCodec.encode(realLocal(font: 88, revision: "z-stale-wakeup")),
			forKey: SettingsSyncStore.kvsKey
		)
		try await Task.sleep(for: .milliseconds(220))

		XCTAssertEqual(store.settings.global.fontSize, 33)
		withExtendedLifetime(sync) {}
	}

	func test_stopThenRestart_queuedLocalEditCannotUnfreezeNewLifecycle() async throws {
		let kvs = FakeKVS()
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("queued-edit-\(UUID().uuidString).plist")
		let store = SettingsStore(settings: realLocal(font: 17, revision: "a-local"), path: tmp)
		store.debounceInterval = .milliseconds(0)
		let defaults = UserDefaults(suiteName: "queued-edit-\(UUID().uuidString)")!
		let tokenStore = IdentityTokenStore(userDefaults: defaults)
		tokenStore.persist(TestToken("user-X"))
		let sync = SettingsSyncStore(
			store: store,
			kvs: kvs,
			accountSession: AlwaysSignedInSession(),
			tokenStore: tokenStore,
			currentTokenProvider: { TestToken("user-Y") },
			configuration: SettingsSyncConfiguration(
				bootTimeout: .milliseconds(10),
				initialSyncGrace: .zero
			)
		)
		sync.installLifecycleObservers()
		await sync.startSync()
		XCTAssertTrue(sync.isPushSuspended)

		// flushNow posts synchronously, but SettingsSyncStore deliberately
		// handles local edits in a queued MainActor task. Stop and restart
		// before that task gets an actor turn.
		store.update { $0.global.fontSize = 25 }
		store.flushNow()
		sync.stopSync()
		await sync.startSync()
		for _ in 0..<20 { await Task.yield() }

		XCTAssertTrue(sync.isPushSuspended)
		XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
		guard case .token(let persisted) = tokenStore.loadPersisted() else {
			XCTFail("persisted identity missing")
			return
		}
		XCTAssertTrue(persisted.isEqual(TestToken("user-X")))
		withExtendedLifetime(sync) {}
	}
}
