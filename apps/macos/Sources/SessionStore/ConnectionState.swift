import Foundation

public enum ConnectionState: Equatable {
    case idle
    case connecting(startedAt: Date)
    case connected(connectedAt: Date)
    case reconnecting(attempt: Int, nextRetryAt: Date)
    case failed(FailureKind)
}
