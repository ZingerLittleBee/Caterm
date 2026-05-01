import XCTest
import SettingsStore
@testable import Caterm

@MainActor
final class TerminalSettingsBindingsTests: XCTestCase {
    func testFontSizeStepperUpdatesStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        let bindings = TerminalSettingsBindings(store: store)
        bindings.fontSize.wrappedValue = 17
        store.flushNow()
        XCTAssertEqual(store.settings.global.fontSize, 17)
    }

    func testCursorStyleSegmented() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SettingsStore.load(from: dir.appendingPathComponent("settings.plist"))
        let bindings = TerminalSettingsBindings(store: store)
        bindings.cursorStyle.wrappedValue = .bar
        store.flushNow()
        XCTAssertEqual(store.settings.global.cursorStyle, .bar)
    }
}
