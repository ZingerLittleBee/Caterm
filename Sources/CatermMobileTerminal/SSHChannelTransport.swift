import Foundation

public enum SSHTransportEvent: Sendable {
	case connecting
	case hostKeyPrompt(endpoint: String, fingerprint: String)
	case authPrompt(SSHAuthPlan.Missing)
	case connected
	case data([UInt8])
	case failed(reason: String)
	case closed(reason: String)
}

public protocol SSHChannelTransport: AnyObject, Sendable {
	func start(onEvent: @escaping @Sendable (SSHTransportEvent) -> Void)
	func write(_ bytes: [UInt8])
	func resize(_ grid: TerminalResize.Grid)
	func close()
}
