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
	private let environment: [HostEnvironmentVariable]
	private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	private let lock = NSLock()
	private var connection: Channel?
	private var child: Channel?
	private var sink: (@Sendable (SSHTransportEvent) -> Void)?
	private var closed = false

	public init(
		host: SSHHost,
		plan: SSHAuthPlan,
		knownHosts: MobileKnownHostsStore,
		environment: [HostEnvironmentVariable] = []
	) {
		self.host = host
		self.plan = plan
		self.knownHosts = knownHosts
		self.environment = environment
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
					let shell = ShellHandler(sink: onEvent)
					return child.pipeline.addHandlers([
						ChannelRequestReplyHandler(),
						shell,
					])
				}
			}
		}

		promise.futureResult.whenFailure { error in
			onEvent(.failed(reason: "channel: \(error)"))
		}
		promise.futureResult.whenSuccess { child in
			child.pipeline.handler(
				type: ChannelRequestReplyHandler.self
			).whenComplete { result in
				switch result {
				case .failure(let error):
					onEvent(.failed(reason: "request replies: \(error)"))
				case .success(let replies):
					self.requestEnvironment(
						self.environment,
						on: child,
						replies: replies,
						onEvent: onEvent
					)
				}
			}
		}
	}

	private func requestEnvironment(
		_ variables: [HostEnvironmentVariable],
		on child: Channel,
		replies: ChannelRequestReplyHandler,
		onEvent: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		guard !variables.isEmpty else {
			requestPTY(on: child, replies: replies, onEvent: onEvent)
			return
		}
		onEvent(.environmentRequestsStarted(names: variables.map(\.name)))
		requestEnvironment(
			variables,
			at: 0,
			accepted: [],
			rejected: [],
			on: child,
			replies: replies,
			onEvent: onEvent
		)
	}

	private func requestEnvironment(
		_ variables: [HostEnvironmentVariable],
		at index: Int,
		accepted: [String],
		rejected: [String],
		on child: Channel,
		replies: ChannelRequestReplyHandler,
		onEvent: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		guard index < variables.count else {
			onEvent(
				.environmentRequestsCompleted(
					accepted: accepted,
					rejected: rejected
				)
			)
			requestPTY(on: child, replies: replies, onEvent: onEvent)
			return
		}
		let variable = variables[index]
		let request = SSHChannelRequestEvent.EnvironmentRequest(
			wantReply: true,
			name: variable.name,
			value: variable.value
		)
		var timeout: Scheduled<Void>?
		let requestToken = replies.expectReply { acceptedByServer in
			timeout?.cancel()
			var nextAccepted = accepted
			var nextRejected = rejected
			if acceptedByServer {
				nextAccepted.append(variable.name)
			} else {
				nextRejected.append(variable.name)
			}
			self.requestEnvironment(
				variables,
				at: index + 1,
				accepted: nextAccepted,
				rejected: nextRejected,
				on: child,
				replies: replies,
				onEvent: onEvent
			)
		}
		timeout = child.eventLoop.scheduleTask(in: .seconds(5)) {
			guard replies.cancelPendingReply(requestToken) else { return }
			onEvent(
				.failed(
					reason: "environment request timed out: \(variable.name)"
				)
			)
			child.close(promise: nil)
		}
		child.triggerUserOutboundEvent(request).whenFailure { error in
			timeout?.cancel()
			guard replies.cancelPendingReply(requestToken) else { return }
			onEvent(
				.failed(
					reason: "environment request \(variable.name): \(error)"
				)
			)
			child.close(promise: nil)
		}
	}

	private func requestPTY(
		on child: Channel,
		replies: ChannelRequestReplyHandler,
		onEvent: @escaping @Sendable (SSHTransportEvent) -> Void
	) {
		let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
			wantReply: true,
			term: "xterm-256color",
			terminalCharacterWidth: 80,
			terminalRowHeight: 24,
			terminalPixelWidth: 0,
			terminalPixelHeight: 0,
			terminalModes: SSHTerminalModes([:])
		)
		var ptyTimeout: Scheduled<Void>?
		let ptyToken = replies.expectReply { acceptedByServer in
			ptyTimeout?.cancel()
			guard acceptedByServer else {
				onEvent(.failed(reason: "server rejected PTY request"))
				child.close(promise: nil)
				return
			}
			let shell = SSHChannelRequestEvent.ShellRequest(wantReply: true)
			var shellTimeout: Scheduled<Void>?
			let shellToken = replies.expectReply { acceptedByServer in
				shellTimeout?.cancel()
				guard acceptedByServer else {
					onEvent(.failed(reason: "server rejected shell request"))
					child.close(promise: nil)
					return
				}
				self.lock.lock()
				self.child = child
				self.lock.unlock()
				onEvent(.connected)
			}
			shellTimeout = child.eventLoop.scheduleTask(in: .seconds(10)) {
				guard replies.cancelPendingReply(shellToken) else { return }
				onEvent(.failed(reason: "shell request timed out"))
				child.close(promise: nil)
			}
			child.triggerUserOutboundEvent(shell).whenFailure { error in
				shellTimeout?.cancel()
				guard replies.cancelPendingReply(shellToken) else { return }
				onEvent(.failed(reason: "shell request: \(error)"))
				child.close(promise: nil)
			}
		}
		ptyTimeout = child.eventLoop.scheduleTask(in: .seconds(10)) {
			guard replies.cancelPendingReply(ptyToken) else { return }
			onEvent(.failed(reason: "PTY request timed out"))
			child.close(promise: nil)
		}
		child.triggerUserOutboundEvent(pty).whenFailure { error in
			ptyTimeout?.cancel()
			guard replies.cancelPendingReply(ptyToken) else { return }
			onEvent(.failed(reason: "PTY request: \(error)"))
			child.close(promise: nil)
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

// MARK: - Request replies

final class ChannelRequestReplyHandler: ChannelInboundHandler {
	typealias InboundIn = SSHChannelData

	private var pendingReply: (token: UInt64, callback: (Bool) -> Void)?
	private var nextToken: UInt64 = 0

	@discardableResult
	func expectReply(_ reply: @escaping (Bool) -> Void) -> UInt64 {
		precondition(pendingReply == nil, "SSH channel requests must be serialized")
		nextToken &+= 1
		pendingReply = (nextToken, reply)
		return nextToken
	}

	func cancelPendingReply(_ token: UInt64) -> Bool {
		guard pendingReply?.token == token else { return false }
		pendingReply = nil
		return true
	}

	@discardableResult
	func cancelPendingReply() -> Bool {
		guard pendingReply != nil else { return false }
		pendingReply = nil
		return true
	}

	func receiveReply(_ accepted: Bool) {
		let reply = pendingReply?.callback
		pendingReply = nil
		reply?(accepted)
	}

	func userInboundEventTriggered(
		context: ChannelHandlerContext,
		event: Any
	) {
		if event is ChannelSuccessEvent {
			receiveReply(true)
		} else if event is ChannelFailureEvent {
			receiveReply(false)
		} else {
			context.fireUserInboundEventTriggered(event)
		}
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		context.fireChannelRead(data)
	}

	func channelInactive(context: ChannelHandlerContext) {
		cancelPendingReply()
		context.fireChannelInactive()
	}
}

// MARK: - Shell channel handler

private final class ShellHandler: ChannelDuplexHandler {
	typealias InboundIn = SSHChannelData
	typealias InboundOut = SSHChannelData
	typealias OutboundIn = SSHChannelData
	typealias OutboundOut = SSHChannelData

	private let sink: @Sendable (SSHTransportEvent) -> Void

	init(sink: @escaping @Sendable (SSHTransportEvent) -> Void) {
		self.sink = sink
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

final class NIOSSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
	@unchecked Sendable {
	private let host: SSHHost
	private let plan: SSHAuthPlan
	private let sink: @Sendable (SSHTransportEvent) -> Void
	private var nextAttemptIndex = 0

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

		guard nextAttemptIndex < plan.attempts.count else {
			nextChallengePromise.succeed(nil)
			return
		}
		let attempt = plan.attempts[nextAttemptIndex]
		nextAttemptIndex += 1

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

		case let .privateKey(blob, passphrase)
			where availableMethods.contains(.publicKey):
			do {
				let key = try OpenSSHPrivateKeyParser.parse(
					blob,
					passphrase: passphrase
				)
				let offer = NIOSSHUserAuthenticationOffer(
					username: host.username,
					serviceName: "",
					offer: .privateKey(.init(privateKey: key))
				)
				nextChallengePromise.succeed(offer)
			} catch {
				sink(.failed(reason: error.localizedDescription))
				nextChallengePromise.fail(error)
			}

		case .privateKey:
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

public enum MobileSSHTrustError: Error, Equatable, Sendable {
	case changed(endpoint: String)
	case persistenceFailed(endpoint: String)
}

extension MobileSSHTrustError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .changed(let endpoint):
			"The SSH host key changed for \(endpoint)."
		case .persistenceFailed(let endpoint):
			"Caterm could not save the SSH host key for \(endpoint)."
		}
	}
}

final class NIOSSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate,
	@unchecked Sendable {
	private let endpoint: String
	private let knownHosts: MobileKnownHostsStore
	private let sink: @Sendable (SSHTransportEvent) -> Void
	private let onFailure: @Sendable (MobileSSHTrustError) -> Void

	init(
		endpoint: String,
		knownHosts: MobileKnownHostsStore,
		sink: @escaping @Sendable (SSHTransportEvent) -> Void,
		onFailure: @escaping @Sendable (MobileSSHTrustError) -> Void = { _ in }
	) {
		self.endpoint = endpoint
		self.knownHosts = knownHosts
		self.sink = sink
		self.onFailure = onFailure
	}

	func validateHostKey(
		hostKey: NIOSSHPublicKey,
		validationCompletePromise: EventLoopPromise<Void>
	) {
		let fingerprint = Self.fingerprint(for: hostKey)
		do {
			switch try knownHosts.evaluate(
				endpoint: endpoint,
				fingerprint: fingerprint
			) {
			case .trusted:
				validationCompletePromise.succeed(())
			case .unknown:
				sink(.hostKeyPrompt(endpoint: endpoint, fingerprint: fingerprint))
				try knownHosts.trust(endpoint: endpoint, fingerprint: fingerprint)
				validationCompletePromise.succeed(())
			case .mismatch:
				sink(.failed(reason: "host key mismatch for \(endpoint)"))
				let failure = MobileSSHTrustError.changed(endpoint: endpoint)
				onFailure(failure)
				validationCompletePromise.fail(failure)
			}
		} catch MobileKnownHostsError.concurrentKeyChange {
			let failure = MobileSSHTrustError.changed(endpoint: endpoint)
			onFailure(failure)
			validationCompletePromise.fail(failure)
		} catch {
			let failure = MobileSSHTrustError.persistenceFailed(endpoint: endpoint)
			onFailure(failure)
			validationCompletePromise.fail(failure)
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
