import XCTest
@testable import Caterm

@MainActor
final class SettingsBannerStateTests: XCTestCase {
    func testReceivesAndDismissesDiagnosticBanner() {
        let state = SettingsBannerState()
        NotificationCenter.default.post(
            name: Notification.Name("catermConfigDiagnostics"),
            object: nil,
            userInfo: ["diagnostics": ["unknown key: foo"]]
        )
        // Allow notification to dispatch
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(state.diagnosticMessages, ["unknown key: foo"])

        state.dismissDiagnostics()
        XCTAssertTrue(state.diagnosticMessages.isEmpty)
    }

    func testReceivesNewSurfaceBanner() {
        let state = SettingsBannerState()
        NotificationCenter.default.post(name: Notification.Name("catermNewSurfaceBanner"), object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(state.showNewSurfaceBanner)
    }
}
