import Foundation

/// Outcome of a TCP preflight probe. Independent of NWError so callers
/// don't need to import Network.framework.
public enum PreflightOutcome: Equatable {
	case ok
	case failed(NetworkErrorReason)
}

/// Abstraction over `Preflight.probe`. `SessionStore` consumes a value of
/// this protocol so tests can inject a fake without spinning up real
/// `NWConnection`s.
public protocol PreflightProbing: Sendable {
	func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome
}
