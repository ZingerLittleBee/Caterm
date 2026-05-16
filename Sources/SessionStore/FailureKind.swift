import Foundation
import SSHCommandBuilder

public enum FailureKind: Equatable {
	/// auth fail or host key mismatch or DNS — short-lived, never reached Connected.
	/// UI: red, "重新填凭据"; do NOT auto-reconnect.
	case authOrSetupFail

	/// Remote shell exited with `exit` (status 0). UI: grey "会话结束"; no reconnect.
	case cleanExit

	/// Network drop after Connected. UI: yellow; enter §4.3 reconnect FSM.
	case connectionDropped

	/// TCP preflight failed before ssh subprocess was launched. Carries a
	/// typed reason for user-facing copy. Does NOT auto-reconnect — initial
	/// network-unreachable means user-visible error with manual Retry.
	case networkUnreachable(NetworkErrorReason)

	/// A required port forward could not bind locally during preflight.
	/// Carries the offending forward + the typed reason for UI copy.
	/// Only thrown by `Preflight`; never synthesized from ssh process exit.
	case portForwardBindFailed(forward: PortForward, reason: PortForward.BindFailureReason)

	/// Classify exit_code + connected-history into one of three exit-driven
	/// failures. `.networkUnreachable` is constructed directly by
	/// `SessionStore.startConnection` and never enters this path.
	public static func classify(exitCode: Int32, hadConnected: Bool) -> FailureKind {
		if exitCode == 0 { return .cleanExit }
		if hadConnected { return .connectionDropped }
		return .authOrSetupFail
	}
}

public enum NetworkErrorReason: Equatable {
	/// Hostname could not be resolved.
	case dnsFailed
	/// Host reachable but port not accepting connections (`ECONNREFUSED`).
	case connectionRefused
	/// Probe timed out (no SYN-ACK or NWConnection waiting state past timeout).
	case timedOut
	/// Local network down / route unreachable (`ENETDOWN`/`ENETUNREACH`/`EHOSTUNREACH`).
	case networkDown
	/// Persisted host port is outside 1...65535. Carried as Int because the
	/// invalid value itself is informational (UI shows "Port X is out of range").
	case invalidPort(Int)
	/// Catch-all: NWError that didn't match any specific case above.
	case other(code: Int, message: String)
}
