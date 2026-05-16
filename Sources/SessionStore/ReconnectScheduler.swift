import Foundation

public enum ReconnectScheduler {
	public static let maxAttempts = 5

	public static func backoff(attempt: Int) -> TimeInterval {
		switch attempt {
		case 1: return 1
		case 2: return 2
		case 3: return 5
		case 4: return 10
		default: return 30
		}
	}

	public static func shouldReconnect(failureKind: FailureKind, attempt: Int) -> Bool {
		guard attempt <= maxAttempts else { return false }
		switch failureKind {
		case .connectionDropped: return true
		case .authOrSetupFail, .cleanExit, .networkUnreachable, .portForwardBindFailed: return false
		}
	}
}
