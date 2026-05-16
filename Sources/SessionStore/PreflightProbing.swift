import Foundation
import SSHCommandBuilder

/// Outcome of a TCP preflight probe. Independent of NWError so callers
/// don't need to import Network.framework.
public enum PreflightOutcome: Equatable {
	case ok
	case failed(NetworkErrorReason)
}

/// Outcome of a local-bind probe (used for port-forward conflict detection).
public enum PortBindOutcome: Equatable {
	case available
	case unavailable(PortForward.BindFailureReason)
}

/// Abstraction over `Preflight.probe` / `Preflight.probeLocalBind`.
/// `SessionStore` consumes a value of this protocol so tests can inject a
/// fake without spinning up real `NWConnection` / `NWListener`s.
public protocol PreflightProbing: Sendable {
	func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome
	func probeLocalBind(address: String, port: UInt16) async -> PortBindOutcome
}
