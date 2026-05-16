import XCTest
@testable import SettingsStore

final class ReplaceFromSyncTests: XCTestCase {
	@MainActor
	func test_replaceFromSync_preservesCloudRevisionVerbatim() throws {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("settings-\(UUID().uuidString).plist")
		defer { try? FileManager.default.removeItem(at: tmp) }
		let store = SettingsStore(settings: CatermSettings(revision: "local-rev"), path: tmp)

		var cloud = CatermSettings(revision: "cloud-rev")
		cloud.global.fontSize = 18
		try store.replaceFromSync(cloud)

		XCTAssertEqual(store.settings.revision, "cloud-rev",
			"replaceFromSync must preserve cloud revision exactly — no makeRevision bump")
		XCTAssertEqual(store.settings.global.fontSize, 18)
	}

	@MainActor
	func test_replaceFromSync_preservesLocalMigrationsCompleted() throws {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("settings-\(UUID().uuidString).plist")
		defer { try? FileManager.default.removeItem(at: tmp) }
		var local = CatermSettings()
		local.migrationsCompleted = ["settings-gui-v1", "device-only-marker"]
		let store = SettingsStore(settings: local, path: tmp)

		var cloud = CatermSettings(revision: "r")
		cloud.migrationsCompleted = ["different-marker"]
		try store.replaceFromSync(cloud)

		XCTAssertEqual(store.settings.migrationsCompleted,
			["settings-gui-v1", "device-only-marker"],
			"migrationsCompleted is local-only and must NOT be overwritten by sync")
	}

	@MainActor
	func test_replaceFromSync_cancelsPendingDebouncedEdit() async throws {
		// Regression for the apply→pending-flush race: a user edit puts a draft
		// in `_pending` with a debounce delay. If a cloud apply lands during that
		// window, the stale pending must NOT flush — `flushNow` calls `save`
		// which re-stamps `revision` via `makeRevision`, and the resulting
		// newer-revision local blob would then revision-LWW back over the
		// cloud apply we just performed.
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("settings-\(UUID().uuidString).plist")
		defer { try? FileManager.default.removeItem(at: tmp) }
		let store = SettingsStore(settings: CatermSettings(), path: tmp)
		store.debounceInterval = .milliseconds(100)

		var localFlushed = false
		let token = NotificationCenter.default.addObserver(
			forName: SettingsStore.changeNotification, object: store, queue: nil
		) { note in
			if (note.userInfo?[SettingsStore.sourceUserInfoKey] as? String) == "local" {
				localFlushed = true
			}
		}
		defer { NotificationCenter.default.removeObserver(token) }

		store.update { $0.global.fontSize = 7 }

		var cloud = CatermSettings(revision: "cloud-rev")
		cloud.global.fontSize = 99
		try store.replaceFromSync(cloud)

		try await Task.sleep(for: .milliseconds(200))

		XCTAssertEqual(store.settings.global.fontSize, 99,
			"cloud value must remain; stale pending must NOT come back to flush 7")
		XCTAssertEqual(store.settings.revision, "cloud-rev",
			"cloud revision must remain; pending flush would re-stamp via makeRevision")
		XCTAssertFalse(localFlushed,
			"pending debounce task must be cancelled by replaceFromSync")
	}

	@MainActor
	func test_replaceFromSync_postsChangeNotificationWithSyncSource() throws {
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("settings-\(UUID().uuidString).plist")
		defer { try? FileManager.default.removeItem(at: tmp) }
		let store = SettingsStore(settings: CatermSettings(), path: tmp)

		let exp = expectation(description: "changeNotification posted")
		var capturedSource: String?
		let token = NotificationCenter.default.addObserver(
			forName: SettingsStore.changeNotification, object: store, queue: nil
		) { note in
			capturedSource = note.userInfo?[SettingsStore.sourceUserInfoKey] as? String
			exp.fulfill()
		}
		defer { NotificationCenter.default.removeObserver(token) }

		var cloud = CatermSettings(revision: "r")
		cloud.global.fontSize = 99
		try store.replaceFromSync(cloud)
		wait(for: [exp], timeout: 1.0)

		XCTAssertEqual(capturedSource, "sync")
	}
}
