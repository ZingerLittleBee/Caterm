import Foundation
import SessionStore

struct WorkspacePaneAccessibilityDescriptor: Equatable {
	let label: String
}

enum WorkspacePaneAccessibility {
	static func descriptor(
		hostName: String,
		connection: String,
		position: Int,
		count: Int,
		isActive: Bool,
		broadcastMarker: String?
	) -> WorkspacePaneAccessibilityDescriptor {
		let focus = isActive ? "Active Pane" : "Inactive Pane"
		let broadcast = broadcastMarker ?? "Not a Broadcast Receiver"
		return WorkspacePaneAccessibilityDescriptor(
			label: "\(hostName), \(connection), Pane \(position) of \(count), \(focus), \(broadcast)"
		)
	}

	static func connectionLabel(
		state: ConnectionState?,
		hadConnected: Bool,
		hasHost: Bool
	) -> String {
		guard let state else { return hasHost ? "Disconnected" : "Not Connected" }
		return switch state {
		case .idle:
			"Idle"
		case .preflight:
			"Checking Connection"
		case .authenticating:
			"Authenticating"
		case .connected:
			hadConnected ? "Connected" : "Connecting"
		case .reconnecting(let attempt, _):
			"Reconnecting, attempt \(attempt)"
		case .failed(let failure):
			failureLabel(failure)
		}
	}

	private static func failureLabel(_ failure: FailureKind) -> String {
		switch failure {
		case .authOrSetupFail:
			"Authentication or setup failed"
		case .cleanExit:
			"Session ended"
		case .connectionDropped:
			"Connection dropped"
		case .networkUnreachable:
			"Network unreachable"
		case .portForwardBindFailed:
			"Port forward failed"
		}
	}
}
