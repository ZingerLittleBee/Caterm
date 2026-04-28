import Combine
import XCTest
@testable import HostSyncStore

@MainActor
final class SyncPreferencesTests: XCTestCase {
    func testDefaultEnabledIsTrueWhenKeyMissing() {
        let defaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        let prefs = SyncPreferences(defaults: defaults)
        XCTAssertTrue(prefs.periodicSyncEnabled,
            "Default must be true when no key has been written yet (spec §3.1)")
    }

    func testEnabledRoundtripsThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        do {
            let prefs = SyncPreferences(defaults: defaults)
            prefs.periodicSyncEnabled = false
        }
        // Build a fresh instance over the same suite — must read back false.
        let prefs2 = SyncPreferences(defaults: defaults)
        XCTAssertFalse(prefs2.periodicSyncEnabled,
            "didSet must persist to UserDefaults so a fresh init reads it back")
    }

    func testEnabledIsObservable() {
        let defaults = UserDefaults(suiteName: "caterm-test-\(UUID().uuidString)")!
        let prefs = SyncPreferences(defaults: defaults)
        var received: [Bool] = []
        let cancellable = prefs.$periodicSyncEnabled.sink { received.append($0) }
        prefs.periodicSyncEnabled = false
        cancellable.cancel()
        XCTAssertEqual(received, [true, false],
            "@Published sink fires once with current value (true), then with the new value (false)")
    }
}
