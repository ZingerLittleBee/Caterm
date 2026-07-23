import SessionStore
import XCTest
@testable import Caterm

final class WorkspacePaneAccessibilityTests: XCTestCase {
	func testDescriptorNamesHostConnectionPositionFocusAndBroadcastState() {
		let descriptor = WorkspacePaneAccessibility.descriptor(
			hostName: "Build Server",
			connection: "Connected",
			position: 2,
			count: 4,
			isActive: true,
			broadcastMarker: "Broadcast Receiver · Pane 2"
		)

		XCTAssertEqual(
			descriptor.label,
			"Build Server, Connected, Pane 2 of 4, Active Pane, Broadcast Receiver · Pane 2"
		)
	}

	func testDescriptorExplicitlyNamesInactiveNonReceiver() {
		let descriptor = WorkspacePaneAccessibility.descriptor(
			hostName: "No Host",
			connection: "Not Connected",
			position: 1,
			count: 1,
			isActive: false,
			broadcastMarker: nil
		)

		XCTAssertEqual(
			descriptor.label,
			"No Host, Not Connected, Pane 1 of 1, Inactive Pane, Not a Broadcast Receiver"
		)
	}

	func testConnectionLabelsDistinguishProvisionalAndConfirmedSessions() {
		let startedAt = Date()

		XCTAssertEqual(
			WorkspacePaneAccessibility.connectionLabel(
				state: .connected(connectedAt: startedAt),
				hadConnected: false,
				hasHost: true
			),
			"Connecting"
		)
		XCTAssertEqual(
			WorkspacePaneAccessibility.connectionLabel(
				state: .connected(connectedAt: startedAt),
				hadConnected: true,
				hasHost: true
			),
			"Connected"
		)
	}

	func testConnectionLabelsCoverReconnectFailureAndMissingRuntime() {
		XCTAssertEqual(
			WorkspacePaneAccessibility.connectionLabel(
				state: .reconnecting(attempt: 3, nextRetryAt: Date()),
				hadConnected: true,
				hasHost: true
			),
			"Reconnecting, attempt 3"
		)
		XCTAssertEqual(
			WorkspacePaneAccessibility.connectionLabel(
				state: .failed(.authOrSetupFail),
				hadConnected: false,
				hasHost: true
			),
			"Authentication or setup failed"
		)
		XCTAssertEqual(
			WorkspacePaneAccessibility.connectionLabel(
				state: nil,
				hadConnected: false,
				hasHost: false
			),
			"Not Connected"
		)
	}
}
