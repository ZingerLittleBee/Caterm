import Foundation
import HostAutomationRuntime
import SSHCommandBuilder

@MainActor
public final class SSHTerminalSession {
	public enum State: Equatable {
		case idle
		case connecting
		case hostKeyPrompt(endpoint: String, fingerprint: String)
		case authPrompt(SSHAuthPlan.Missing)
		case connected
		case failed(reason: String)
		case disconnected(reason: String)
	}

	public let host: SSHHost
	private let transport: SSHChannelTransport
	private var lastGrid: TerminalResize.Grid?

	public private(set) var state: State = .idle {
		didSet { if state != oldValue { onStateChange?(state) } }
	}

	public var onStateChange: ((State) -> Void)?
	public var onOutput: (([UInt8]) -> Void)?
	public var onEnvironmentStatusChange: ((HostEnvironmentRequestStatus) -> Void)?
	public private(set) var environmentRequestStatus: HostEnvironmentRequestStatus = .notRequested {
		didSet {
			if environmentRequestStatus != oldValue {
				onEnvironmentStatusChange?(environmentRequestStatus)
			}
		}
	}

	public init(host: SSHHost, transport: SSHChannelTransport) {
		self.host = host
		self.transport = transport
	}

	public func connect() async {
		state = .connecting
		transport.start { [weak self] event in
			guard let self else { return }
			if Thread.isMainThread {
				MainActor.assumeIsolated { self.handle(event) }
			} else {
				Task { @MainActor in self.handle(event) }
			}
		}
	}

	public func send(_ bytes: [UInt8]) async {
		guard !bytes.isEmpty else { return }
		transport.write(bytes)
	}

	public func resize(_ grid: TerminalResize.Grid) async {
		guard TerminalResize.shouldSend(grid, since: lastGrid) else { return }
		lastGrid = grid
		transport.resize(grid)
	}

	public func disconnect() async {
		transport.close()
	}

	private func handle(_ event: SSHTransportEvent) {
		switch event {
		case .connecting:
			state = .connecting
		case let .hostKeyPrompt(endpoint, fingerprint):
			state = .hostKeyPrompt(endpoint: endpoint, fingerprint: fingerprint)
		case let .authPrompt(missing):
			state = .authPrompt(missing)
		case .environmentRequestsStarted(let names):
			environmentRequestStatus = .pending(names: names)
		case .environmentRequestsCompleted(let accepted, let rejected):
			environmentRequestStatus = .completed(
				accepted: accepted,
				rejected: rejected
			)
		case .connected:
			state = .connected
		case let .data(bytes):
			onOutput?(bytes)
		case let .failed(reason):
			state = .failed(reason: reason)
		case let .closed(reason):
			state = .disconnected(reason: reason)
		}
	}
}
