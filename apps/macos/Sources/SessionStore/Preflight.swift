import Foundation
import Network

/// TCP preflight probe. Uses NWConnection to determine reachability and
/// classify failure type before the libghostty ssh subprocess is launched.
///
/// Threading: `probe` returns to the calling actor via a `CheckedContinuation`.
/// The internal `stateUpdateHandler` runs on `queue` (default
/// `DispatchQueue.global(qos: .userInitiated)`).
public struct Preflight: PreflightProbing {
	public init() {}

	public func probe(host: String, port: UInt16, timeout: TimeInterval = 5) async -> PreflightOutcome {
		guard let nwPort = NWEndpoint.Port(rawValue: port) else {
			// Should be unreachable: callers validate range before calling. Be
			// defensive anyway — `.other` is fine here since we never
			// construct an NWConnection.
			return .failed(.other(code: -1, message: "Port \(port) is invalid"))
		}
		let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
		let connection = NWConnection(to: endpoint, using: .tcp)
		let queue = DispatchQueue.global(qos: .userInitiated)

		return await withCheckedContinuation { continuation in
			// Guard against double-resume from racing state callbacks vs timeout.
			let resumed = ResumedFlag()

			connection.stateUpdateHandler = { state in
				switch state {
				case .ready:
					if resumed.markIfFirst() {
						connection.cancel()
						continuation.resume(returning: .ok)
					}
				case .failed(let error):
					if resumed.markIfFirst() {
						connection.cancel()
						continuation.resume(returning: .failed(Self.mapNWError(error)))
					}
				case .waiting(let error):
					// .waiting fires when NWConnection cannot establish (e.g. no route,
					// refused). Treat it as a terminal failure for our short-window probe.
					if resumed.markIfFirst() {
						connection.cancel()
						continuation.resume(returning: .failed(Self.mapNWError(error)))
					}
				case .cancelled, .preparing, .setup:
					break
				@unknown default:
					break
				}
			}
			connection.start(queue: queue)

			// Manual timeout — NWConnection's own .waiting may take long.
			queue.asyncAfter(deadline: .now() + timeout) {
				if resumed.markIfFirst() {
					connection.cancel()
					continuation.resume(returning: .failed(.timedOut))
				}
			}
		}
	}

	/// Maps an `NWError` to our typed `NetworkErrorReason`. Internal so unit
	/// tests can drive every branch without spinning up real connections.
	static func mapNWError(_ error: NWError) -> NetworkErrorReason {
		switch error {
		case .posix(let code):
			switch code {
			case .ECONNREFUSED: return .connectionRefused
			case .ETIMEDOUT:    return .timedOut
			case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH: return .networkDown
			default:
				return .other(code: Int(code.rawValue),
				              message: error.localizedDescription)
			}
		case .dns:
			return .dnsFailed
		case .tls:
			return .other(code: 0, message: error.localizedDescription)
		@unknown default:
			return .other(code: 0, message: error.localizedDescription)
		}
	}
}

/// Thread-safe one-shot flag. NWConnection state callbacks and the timeout
/// timer can both fire after one another resolved the continuation; this
/// ensures `continuation.resume` is called exactly once.
private final class ResumedFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var done = false
	func markIfFirst() -> Bool {
		lock.lock(); defer { lock.unlock() }
		if done { return false }
		done = true
		return true
	}
}
