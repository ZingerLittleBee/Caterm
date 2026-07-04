import XCTest
import SettingsStore
@testable import Caterm

@MainActor
final class PreferencesWindowTests: XCTestCase {
    func testSidebarSectionsCoverAllDomains() {
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            ["Terminal", "Themes", "iCloud Sync", "Credentials", "Backup"]
        )
    }

    func testActivateSectionUpdatesSelection() {
        let ctrl = PreferencesWindowController()
        ctrl.activate(.themes)
        XCTAssertEqual(ctrl.model.selection, .themes)
    }

    func testUseSettingsStoreReplacesFallbackStore() throws {
        let first = try makeSettingsStore()
        let second = try makeSettingsStore()
        let ctrl = PreferencesWindowController(settingsStore: first)

        ctrl.use(settingsStore: second)

        XCTAssertTrue(ctrl.settingsStore === second)
    }
}

extension PreferencesWindowTests {
    func testSharedInstanceShowsAndReuses() {
        let first = PreferencesWindowController.shared
        let second = PreferencesWindowController.shared
        XCTAssertTrue(first === second)
    }

    func testSyncSectionsConstructibleWithoutSyncEnvironment() {
        // With no syncEnvironment injected the sync-related sections render
        // SyncUnavailableView, so tests can still construct a bare
        // PreferencesWindowController without the sync stack.
        let ctrl = PreferencesWindowController()
        ctrl.activate(.cloudSync)
        XCTAssertNotNil(ctrl.window?.contentViewController)
        XCTAssertEqual(ctrl.model.selection, .cloudSync)
        XCTAssertNil(ctrl.syncEnvironment)
    }

    private func makeSettingsStore() throws -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesWindowTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
    }
}
