import SessionStore
import SSHCommandBuilder
import SwiftUI

public enum FailureIcon: Equatable {
	case red
	case orange
}

/// View-model for `FailureOverlay`. Maps a `FailureKind` + the host being
/// connected to a presentation triple (icon color, short title, optional
/// detail line). Pure function; no SwiftUI state.
public struct FailurePresentation: Equatable {
	public var icon: FailureIcon
	public var title: String
	public var detail: String?

	public static func from(failure: FailureKind, host: SSHHost) -> FailurePresentation {
		switch failure {
		case .networkUnreachable(.dnsFailed):
			return .init(icon: .orange,
			             title: "Host not found",
			             detail: "Could not resolve hostname \(host.hostname)")
		case .networkUnreachable(.connectionRefused):
			return .init(icon: .orange,
			             title: "Connection refused",
			             detail: "Port \(host.port) is not accepting connections")
		case .networkUnreachable(.timedOut):
			return .init(icon: .orange,
			             title: "Connection timed out",
			             detail: "No response from \(host.hostname):\(host.port) after 5 seconds")
		case .networkUnreachable(.networkDown):
			return .init(icon: .orange,
			             title: "No network",
			             detail: "Check your internet connection")
		case .networkUnreachable(.invalidPort(let p)):
			return .init(icon: .red,
			             title: "Invalid port",
			             detail: "Port \(p) is out of range (1–65535) — edit host to fix")
		case .networkUnreachable(.other(_, let message)):
			return .init(icon: .orange,
			             title: "Connection failed",
			             detail: message)
		case .authOrSetupFail:
			return .init(icon: .red,
			             title: "Authentication failed",
			             detail: "Permission denied — check credentials")
		case .cleanExit, .connectionDropped:
			// Caller filters these out before presenting; keep a defensive
			// empty value to avoid a crash if the filter is bypassed.
			return .init(icon: .orange, title: "", detail: nil)
		}
	}
}
