import XCTest
@testable import Caterm

@MainActor
final class UpdaterControllerTests: XCTestCase {
    final class FakeUpdater: UpdaterDriving {
        var canCheck = true
        private(set) var checkCount = 0
        var canCheckForUpdates: Bool { canCheck }
        func checkForUpdates() { checkCount += 1 }
    }

    func testCheckForUpdatesForwardsToDriver() {
        let fake = FakeUpdater()
        let controller = UpdaterController(updater: fake)
        controller.checkForUpdates()
        controller.checkForUpdates()
        XCTAssertEqual(fake.checkCount, 2)
    }

    func testCanCheckForUpdatesPassesThrough() {
        let fake = FakeUpdater()
        let controller = UpdaterController(updater: fake)
        fake.canCheck = false
        XCTAssertFalse(controller.canCheckForUpdates)
        fake.canCheck = true
        XCTAssertTrue(controller.canCheckForUpdates)
    }
}
