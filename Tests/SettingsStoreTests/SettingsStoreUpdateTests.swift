import XCTest
import Combine
@testable import SettingsStore

@MainActor
final class SettingsStoreUpdateTests: XCTestCase {
    func testDebouncePostsScopedNotificationOnce() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreUpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        store.debounceInterval = .milliseconds(50)

        var seenScopes: [SettingsChangeScope] = []
        let token = NotificationCenter.default.addObserver(
            forName: SettingsStore.changeNotification,
            object: store,
            queue: .main
        ) { note in
            if let s = note.userInfo?[SettingsStore.scopeUserInfoKey] as? SettingsChangeScope {
                seenScopes.append(s)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.update { $0.global.fontSize = 14 }
        store.update { $0.global.fontSize = 15 }
        store.update { $0.global.fontSize = 16 }

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(seenScopes, [.globalLive])
        XCTAssertEqual(store.settings.global.fontSize, 16)
    }

    func testFlushNowAppliesPendingChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreUpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        store.debounceInterval = .milliseconds(10_000) // long debounce

        store.update { $0.global.fontSize = 22 }
        store.flushNow()
        XCTAssertEqual(store.settings.global.fontSize, 22)
    }

    func testEffectiveSettingsIncludesPendingChangeBeforeFlush() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreUpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        store.debounceInterval = .milliseconds(10_000)

        store.update { $0.global.windowOpacity = 0.82 }

        XCTAssertEqual(store.effectiveSettings.global.windowOpacity, 0.82)
        XCTAssertNil(store.settings.global.windowOpacity)
    }

    func testUpdatePublishesPendingChangeBeforeFlush() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreUpdateTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        store.debounceInterval = .milliseconds(10_000)

        var updateCount = 0
        let token = store.objectWillChange.sink {
            updateCount += 1
        }
        defer { token.cancel() }

        store.update { $0.global.windowOpacity = 0.82 }

        XCTAssertEqual(updateCount, 1)
    }
}

final class FirstUserEditedAtTests: XCTestCase {
    @MainActor
    func test_firstUpdate_setsFirstUserEditedAt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        XCTAssertNil(store.settings.firstUserEditedAt)

        store.debounceInterval = .milliseconds(0)
        store.update { $0.global.fontSize = 14 }
        store.flushNow()

        XCTAssertNotNil(store.settings.firstUserEditedAt, "first edit should populate timestamp")
    }

    @MainActor
    func test_secondUpdate_doesNotChangeFirstUserEditedAt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        let store = SettingsStore(
            settings: CatermSettings(firstUserEditedAt: initial),
            path: tmp
        )

        store.debounceInterval = .milliseconds(0)
        store.update { $0.global.fontSize = 14 }
        store.flushNow()

        XCTAssertEqual(store.settings.firstUserEditedAt, initial,
            "subsequent edits must NOT overwrite the first-edit timestamp")
    }
}
