import XCTest
import SettingsStore
@testable import Caterm

@MainActor
final class HostThemeOverrideTests: XCTestCase {
	func testSetOverrideStoresThemeAndRegeneratesPatch() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
		let logic = HostThemeOverrideLogic(store: store)
		logic.setTheme("Dracula", forHost: HostId("h1"))
		store.flushNow()
		XCTAssertEqual(store.settings.hostOverrides[HostId("h1")]?.theme, "Dracula")
	}

	func testClearOverrideRemovesEntry() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
		let logic = HostThemeOverrideLogic(store: store)
		logic.setTheme("Dracula", forHost: HostId("h1"))
		logic.setTheme(nil, forHost: HostId("h1"))
		store.flushNow()
		XCTAssertNil(store.settings.hostOverrides[HostId("h1")]?.theme)
	}
}
