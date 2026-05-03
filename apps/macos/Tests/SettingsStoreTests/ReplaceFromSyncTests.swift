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
