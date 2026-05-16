import AppKit
import XCTest
@testable import Caterm
@testable import SSHCommandBuilder

@MainActor
final class HostListDoubleClickConnectorTests: XCTestCase {
	private final class DummyTarget: NSObject {
		@objc func onAction(_: Any?) {}
	}

	func testInstallOnReappliesDoubleActionWhenTableWasMutatedExternally() {
		let coordinator = HostListDoubleClickConnector.Coordinator()
		let host = SSHHost(name: "n", hostname: "h", port: 22,
		                   username: "u", credential: .password)
		coordinator.update(hosts: [host], onDoubleClick: { _ in })

		let table = NSTableView()
		let originalTarget = DummyTarget()
		table.target = originalTarget
		table.doubleAction = #selector(DummyTarget.onAction(_:))

		coordinator.install(on: table)
		XCTAssertTrue(table.target === coordinator)
		XCTAssertEqual(table.doubleAction, HostListDoubleClickConnector.Coordinator.installedDoubleAction)

		// Simulate SwiftUI/AppKit resetting the table's action while the same
		// backing NSTableView instance stays alive.
		table.doubleAction = #selector(DummyTarget.onAction(_:))

		coordinator.install(on: table)
		XCTAssertTrue(table.target === coordinator)
		XCTAssertEqual(table.doubleAction, HostListDoubleClickConnector.Coordinator.installedDoubleAction)
	}
}
