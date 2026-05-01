import XCTest
@testable import Caterm

@MainActor
final class PreferencesWindowTests: XCTestCase {
    func testWindowHasFourTabs() {
        let ctrl = PreferencesWindowController()
        XCTAssertEqual(ctrl.tabs.map(\.title), ["General", "Terminal", "Themes", "Sync"])
    }

    func testSwitchingTabUpdatesActiveIndex() {
        let ctrl = PreferencesWindowController()
        ctrl.activate(tabIndex: 2)
        XCTAssertEqual(ctrl.activeTabIndex, 2)
    }
}

extension PreferencesWindowTests {
    func testSharedInstanceShowsAndReuses() {
        let first = PreferencesWindowController.shared
        let second = PreferencesWindowController.shared
        XCTAssertTrue(first === second)
    }
}
