import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHCommandBuilder

/// A concrete ``SSHChannelTransport`` backed by swift-nio-ssh.
///
/// Establishes one TCP connection, opens a single `.session` child channel,
/// requests an interactive PTY plus a shell, and bridges stdout/stderr bytes
/// to the injected event sink. Auth is driven from an ``SSHAuthPlan`` and host
/// keys are validated against a ``MobileKnownHostsStore`` using a trust-on-
/// first-use policy.
///
/// NIO callbacks may fire on event-loop threads; every emission hops through
/// the provided `@Sendable` sink, which is responsible for any further
/// dispatch.
public final class NIOSSHTransport: SSHChannelTransport, @unchecked Sendable {
	private let host: SSHHost
	private let plan: SSHAuthPlan
	private let knownHosts: MobileKnownHostsStore
	private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	private let lock = NSLock()
	private var connection: Channel?
	private var child: Channel?
	private var sink: (@Sendable (SSHTransportEvent) -> Void)?
	private var closed = false

	public init(host: SSHHost, plan: SSHAuthPlan, knownHosts: MobileKnownHostsStore) {
		self.host = host
		self.plan = plan
		self.knownHosts = knownHosts
	}

	public func start(onEvent: @escaping @Sendable (SSHTransportEvent) -> Void) {
		lock.lock()
		sink = onEvent
		lock.unlock()

		onEvent(.connecting)

		let endpoint = "\(host.hostname):\(host.port)"
		let userAuth = NIOSSHAuthDelegate(host: host, plan: plan, sink: onEvent)
		let serverAuth = NIOSSHHostKeyDelegate(
			endpoint: endpoint,
			knownHosts: knownHosts,
			sink: onEvent)

		let bootstrap = ClientBootstrap(group: group)
			.channelInitializer { channel in
				let handler = NIOSSHHandler(
					role: .client(.init(
						userAuthDelegate: userAuth,
						serverAuthDelegate: serverAuth)),
					allocator: channel.allocator,
					inboundChildChannelInitializer: nil)
				return channel.pipeline.addHandlers([handler])
			}
			.channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)

		bootstrap.connect(host: host.hostname, port: host.port).whenComplete { result in
			switch result {
			case .failure(let error):
				onEvent(.failed(reason: "connect: \(error)"))
			case .success(let channel):
				self.lock.lock()
				self.connection = channel
				self.lock.unlock()
				self.openShell(on: channel, onEvent: onEvent)
				channel.closeFuture.whenComplete { _ in
					self.emitClosedOnce("connection closed")
				}
			}
		}
	}

	private func openShell(
		on channel: Channel,
		onEvent: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		let promise = channel.eventLoop.makePromise(of: Channel.self)
		channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
			switch result {
			case .failure(let error):
				onEvent(.failed(reason: "pipeline: \(error)"))
			case .success(let ssh):
				ssh.createChannel(promise, channelType: .session) { child, _ in
					let shell = ShellHandler(
						sink: onEvent,
						ready: {
							self.lock.lock()
							self.child = child
							self.lock.unlock()
							onEvent(.connected)
						})
					return child.pipeline.addHandler(shell)
				}
			}
		}

		promise.futureResult.whenFailure { error in
			onEvent(.failed(reason: "channel: \(error)"))
		}
		promise.futureResult.whenSuccess { child in
			let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
				wantReply: true,
				term: "xterm-256color",
				terminalCharacterWidth: 80,
				terminalRowHeight: 24,
				terminalPixelWidth: 0,
				terminalPixelHeight: 0,
				terminalModes: SSHTerminalModes([:]))
			child.triggerUserOutboundEvent(pty).whenComplete { result in
				switch result {
				case .failure(let error):
					onEvent(.failed(reason: "pty: \(error)"))
				case .success:
					let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
					child.triggerUserOutboundEvent(shell, promise: nil)
				}
			}
		}
	}

	public func write(_ bytes: [UInt8]) {
		lock.lock()
		let child = child
		lock.unlock()
		guard let child else { return }
		var buf = child.allocator.buffer(capacity: bytes.count)
		buf.writeBytes(bytes)
		let data = SSHChannelData(type: .channel, data: .byteBuffer(buf))
		child.writeAndFlush(data, promise: nil)
	}

	public func resize(_ grid: TerminalResize.Grid) {
		lock.lock()
		let child = child
		lock.unlock()
		guard let child else { return }
		let event = SSHChannelRequestEvent.WindowChangeRequest(
			terminalCharacterWidth: grid.cols,
			terminalRowHeight: grid.rows,
			terminalPixelWidth: 0,
			terminalPixelHeight: 0)
		child.triggerUserOutboundEvent(event, promise: nil)
	}

	public func close() {
		lock.lock()
		let child = child
		let connection = connection
		lock.unlock()
		child?.close(promise: nil)
		connection?.close(promise: nil)
		try? group.syncShutdownGracefully()
		emitClosedOnce("client closed")
	}

	private func emitClosedOnce(_ reason: String) {
		lock.lock()
		if closed {
			lock.unlock()
			return
		}
		closed = true
		let sink = sink
		lock.unlock()
		sink?(.closed(reason: reason))
	}
}

// MARK: - Shell channel handler

private final class ShellHandler: ChannelDuplexHandler {
	typealias InboundIn = SSHChannelData
	typealias InboundOut = SSHChannelData
	typealias OutboundIn = SSHChannelData
	typealias OutboundOut = SSHChannelData

	private let sink: @Sendable (SSHTransportEvent) -> Void
	private let ready: () -> Void
	private var announced = false

	init(
		sink: @escaping @Sendable (SSHTransportEvent) -> Void,
		ready: @escaping () -> Void
	) {
		self.sink = sink
		self.ready = ready
	}

	func channelActive(context: ChannelHandlerContext) {
		if !announced {
			announced = true
			ready()
		}
		context.fireChannelActive()
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let channelData = unwrapInboundIn(data)
		guard case .byteBuffer(let buf) = channelData.data else { return }
		switch channelData.type {
		case .channel, .stdErr:
			sink(.data(Array(buf.readableBytesView)))
		default:
			sink(.data(Array(buf.readableBytesView)))
		}
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		sink(.failed(reason: "\(error)"))
		context.close(promise: nil)
	}

	func channelInactive(context: ChannelHandlerContext) {
		sink(.closed(reason: "channel closed"))
		context.fireChannelInactive()
	}
}

// MARK: - User authentication delegate

private final class NIOSSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
	private let host: SSHHost
	private let plan: SSHAuthPlan
	private let sink: @Sendable (SSHTransportEvent) -> Void

	init(
		host: SSHHost,
		plan: SSHAuthPlan,
		sink: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		self.host = host
		self.plan = plan
		self.sink = sink
	}

	func nextAuthenticationType(
		availableMethods: NIOSSHAvailableUserAuthenticationMethods,
		nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
	) {
		if let missing = plan.missing {
			sink(.authPrompt(missing))
			nextChallengePromise.succeed(nil)
			return
		}

		guard let attempt = plan.attempts.first else {
			nextChallengePromise.succeed(nil)
			return
		}

		switch attempt {
		case .password(let password) where availableMethods.contains(.password):
			let offer = NIOSSHUserAuthenticationOffer(
				username: host.username,
				serviceName: "",
				offer: .password(.init(password: password)))
			nextChallengePromise.succeed(offer)

		case .password:
			// Server does not accept password auth.
			nextChallengePromise.succeed(nil)

		case .privateKey:
			// swift-nio-ssh 0.13.0 has no OpenSSH private key (PEM) initializer
			// on NIOSSHPrivateKey — only typed CryptoKit key inits. We cannot
			// parse an arbitrary OpenSSH key blob, so report this honestly
			// rather than inventing an API.
			sink(.failed(reason: "private key auth unsupported by NIOSSH 0.13.0"))
			nextChallengePromise.succeed(nil)

		case .keyboardInteractive:
			// swift-nio-ssh 0.13.0 exposes no keyboard-interactive offer; the
			// only client offers are password / privateKey / hostBased / none.
			// Surface a prompt for credentials instead of faking success.
			sink(.authPrompt(.password))
			nextChallengePromise.succeed(nil)
		}
	}
}

// MARK: - Host key validation delegate

private struct HostKeyMismatchError: Error {
	let endpoint: String
}

private final class NIOSSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
	private let endpoint: String
	private let knownHosts: MobileKnownHostsStore
	private let sink: @Sendable (SSHTransportEvent) -> Void

	init(
		endpoint: String,
		knownHosts: MobileKnownHostsStore,
		sink: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		self.endpoint = endpoint
		self.knownHosts = knownHosts
		self.sink = sink
	}

	func validateHostKey(
		hostKey: NIOSSHPublicKey,
		validationCompletePromise: EventLoopPromise<Void>
	) {
		let fingerprint = Self.fingerprint(for: hostKey)
		switch knownHosts.evaluate(endpoint: endpoint, fingerprint: fingerprint) {
		case .trusted:
			validationCompletePromise.succeed(())
		case .unknown:
			sink(.hostKeyPrompt(endpoint: endpoint, fingerprint: fingerprint))
			try? knownHosts.trust(endpoint: endpoint, fingerprint: fingerprint)
			validationCompletePromise.succeed(())
		case .mismatch:
			sink(.failed(reason: "host key mismatch for \(endpoint)"))
			validationCompletePromise.fail(HostKeyMismatchError(endpoint: endpoint))
		}
	}

	/// Computes a stable SHA-256 fingerprint of the SSH wire-format host key.
	///
	/// `String(openSSHPublicKey:)` yields `"<algo> <base64-wire-blob>"`; the
	/// base64 payload is the SSH wire encoding of the key (the same bytes
	/// OpenSSH hashes for its `SHA256:` fingerprint). We hash that blob.
	static func fingerprint(for key: NIOSSHPublicKey) -> String {
		let openSSH = String(openSSHPublicKey: key)
		let parts = openSSH.split(separator: " ", maxSplits: 2)
		let blob: Data
		if parts.count >= 2, let decoded = Data(base64Encoded: String(parts[1])) {
			blob = decoded
		} else {
			blob = Data(openSSH.utf8)
		}
		let digest = SHA256.hash(data: blob)
		return digest.map { String(format: "%02x", $0) }.joined()
	}
}
