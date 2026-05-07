import Foundation

public enum ConnectionState: Equatable {
	case idle
	/// TCP preflight in flight (NWConnection probing host:port).
	/// `surfaceGeneration` is NOT bumped here — the placeholder view stays.
	case preflight(startedAt: Date)
	/// ssh subprocess has been started; libghostty is driving it. Successor
	/// of the old `.connecting` case (semantically identical, renamed because
	/// "connecting" was ambiguous between TCP and SSH layers).
	case authenticating(startedAt: Date)
	case connected(connectedAt: Date)
	case reconnecting(attempt: Int, nextRetryAt: Date)
	case failed(FailureKind)
}
