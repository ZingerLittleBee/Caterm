import AppKit
import XCTest
@testable import Caterm
@testable import SSHCommandBuilder

@MainActor
final class HostListDoubleClickConnectorTests: XCTestCase {
	private final class DummyTarget: NSObject {
		var actionCount = 0

		@objc func onAction(_: Any?) {
			actionCount += 1
		}
	}

	func testInstallOnReappliesDoubleActionWhenTableWasMutatedExternally() {
		_ = NSApplication.shared
		let coordinator = HostListDoubleClickConnector.Coordinator()
		let host = SSHHost(name: "n", hostname: "h", port: 22,
		                   username: "u", credential: .password)
		coordinator.update(hosts: [host], onDoubleClick: { _ in })

		let table = NSTableView()
		let originalTarget = DummyTarget()
		table.target = originalTarget
		table.action = #selector(DummyTarget.onAction(_:))
		table.doubleAction = #selector(DummyTarget.onAction(_:))
		XCTAssertTrue(table.target === originalTarget)

		coordinator.install(on: table)
		XCTAssertTrue(table.target === coordinator)
		XCTAssertEqual(table.action, HostListDoubleClickConnector.Coordinator.installedAction)
		XCTAssertEqual(table.doubleAction, HostListDoubleClickConnector.Coordinator.installedDoubleAction)

		// Simulate SwiftUI/AppKit resetting the table's action while the same
		// backing NSTableView instance stays alive.
		table.action = #selector(DummyTarget.onAction(_:))
		table.doubleAction = #selector(DummyTarget.onAction(_:))

		coordinator.install(on: table)
		XCTAssertTrue(table.target === coordinator)
		XCTAssertEqual(table.action, HostListDoubleClickConnector.Coordinator.installedAction)
		XCTAssertEqual(table.doubleAction, HostListDoubleClickConnector.Coordinator.installedDoubleAction)

		coordinator.forwardSingleAction(table)
		XCTAssertEqual(originalTarget.actionCount, 1)
		XCTAssertTrue(coordinator.responds(to: NSSelectorFromString("onAction:")))
	}
}
