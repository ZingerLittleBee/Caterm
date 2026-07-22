import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SSHCommandBuilder

public enum MobileSFTPEntryType: Equatable, Sendable {
	case file
	case directory
	case unknown
}

public struct MobileSFTPEntry: Equatable, Sendable {
	public let path: String
	public let name: String
	public let type: MobileSFTPEntryType
	public var isDirectory: Bool { type == .directory }
	public let size: Int64?
	public let modificationDate: Date?
	public let permissions: UInt16?
}

public enum MobileSFTPError: Error, Equatable, Sendable {
	case cancelled
	case permissionDenied(message: String)
	case notFound(path: String)
	case alreadyExists(path: String)
	case directoryNotEmpty(path: String)
	case failure(path: String, message: String)
	case disconnected
	case unsupportedVersion(UInt32)
	case invalidResponse(message: String)
	case cleanupFailed(originalMessage: String, cleanupMessage: String)
	case transport(message: String)
}

extension MobileSFTPError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .cancelled:
			"Remote file browsing was cancelled."
		case .permissionDenied(let message):
			message
		case .notFound(let path):
			"Remote path not found: \(path)"
		case .alreadyExists(let path):
			"A remote item already exists at \(path)."
		case .directoryNotEmpty(let path):
			"Remote folder is not empty: \(path)."
		case .failure(let path, let message):
			message.isEmpty
				? "SFTP request failed for \(path)."
				: message
		case .disconnected:
			"The SFTP connection closed."
		case .unsupportedVersion(let version):
			"The SFTP server selected unsupported protocol version \(version)."
		case .invalidResponse(let message), .transport(let message):
			message
		case .cleanupFailed(let originalMessage, let cleanupMessage):
			"\(originalMessage) Cleanup also failed: \(cleanupMessage)"
		}
	}
}

public final class MobileSFTPClient: @unchecked Sendable {
	private let group: MultiThreadedEventLoopGroup
	private let connection: Channel
	private let channel: Channel
	private let handler: MobileSFTPChannelHandler
	private let lock = NSLock()
	private var closed = false

	private init(
		group: MultiThreadedEventLoopGroup,
		connection: Channel,
		channel: Channel,
		handler: MobileSFTPChannelHandler
	) {
		self.group = group
		self.connection = connection
		self.channel = channel
		self.handler = handler
	}

	public static func connect(
		host: SSHHost,
		plan: SSHAuthPlan,
		knownHosts: MobileKnownHostsStore
	) async throws -> MobileSFTPClient {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		let attempt = MobileSFTPConnectionAttempt(group: group)
		return try await withTaskCancellationHandler {
			do {
				try Task.checkCancellation()
				let endpoint = "\(host.hostname):\(host.port)"
				let trustFailure = MobileSFTPTrustFailureRelay()
				let userAuth = NIOSSHAuthDelegate(host: host, plan: plan) { _ in }
				let serverAuth = NIOSSHHostKeyDelegate(
					endpoint: endpoint,
					knownHosts: knownHosts,
					sink: { _ in },
					onFailure: { trustFailure.fail($0) }
				)
				let bootstrap = ClientBootstrap(group: group)
					.channelInitializer { channel in
						let ssh = NIOSSHHandler(
							role: .client(.init(
								userAuthDelegate: userAuth,
								serverAuthDelegate: serverAuth
							)),
							allocator: channel.allocator,
							inboundChildChannelInitializer: nil
						)
						return channel.pipeline.addHandler(ssh)
					}
				let connection = try await bootstrap
					.connect(host: host.hostname, port: host.port)
					.get()
				try attempt.register(connection: connection)
				let ssh = try await connection.pipeline
					.handler(type: NIOSSHHandler.self)
					.get()
				let childPromise = connection.eventLoop.makePromise(of: Channel.self)
				let sftpHandler = MobileSFTPChannelHandler()
				ssh.createChannel(childPromise, channelType: .session) { child, _ in
					child.pipeline.addHandler(sftpHandler)
				}
				let child = try await trustFailure.race(childPromise.futureResult)
				try attempt.register(child: child)
				try await child.triggerUserOutboundEvent(
					SSHChannelRequestEvent.SubsystemRequest(
						subsystem: "sftp",
						wantReply: true
					)
				).get()
				try await sftpHandler.initializeProtocol().get()
				try Task.checkCancellation()
				try attempt.transferOwnership()
				return MobileSFTPClient(
					group: group,
					connection: connection,
					channel: child,
					handler: sftpHandler
				)
			} catch {
				let mapped = Self.map(error)
				if let cleanupError = await attempt.cleanup() {
					throw MobileSFTPError.cleanupFailed(
						originalMessage: mapped.localizedDescription,
						cleanupMessage: cleanupError.localizedDescription
					)
				}
				throw mapped
			}
		} onCancel: {
			attempt.cancel()
		}
	}

	public func listDirectory(at path: String) async throws -> [MobileSFTPEntry] {
		try await withTaskCancellationHandler {
			do {
				try Task.checkCancellation()
				let protocolPath: String
				if path == "~" {
					protocolPath = "."
				} else if path.hasPrefix("~/") {
					protocolPath = "." + path.dropFirst()
				} else {
					protocolPath = path
				}
				let canonicalPath = try await handler.realPath(protocolPath).get()
				let handle = try await handler.openDirectory(canonicalPath).get()
				var entries: [MobileSFTPEntry] = []
				do {
					while true {
						try Task.checkCancellation()
						switch try await handler.readDirectory(handle).get() {
						case .entries(let batch):
							entries.append(contentsOf: batch.compactMap { item in
								guard item.name != ".", item.name != ".." else {
									return nil
								}
								return item.entry(parent: canonicalPath)
							})
						case .end:
							try await handler.closeHandle(handle).get()
							return entries.sorted {
								if $0.isDirectory != $1.isDirectory {
									return $0.isDirectory
								}
								return $0.name.localizedStandardCompare($1.name)
									== .orderedAscending
							}
						}
					}
				} catch {
					if Task.isCancelled { throw CancellationError() }
					do {
						try await handler.closeHandle(handle).get()
					} catch let cleanupError {
						throw MobileSFTPError.cleanupFailed(
							originalMessage: error.localizedDescription,
							cleanupMessage: cleanupError.localizedDescription
						)
					}
					throw error
				}
			} catch is CancellationError {
				throw MobileSFTPError.cancelled
			} catch {
				throw Self.map(error, path: path)
			}
		} onCancel: { [weak self] in
			self?.close()
		}
	}

	public func stat(at path: String) async throws -> MobileSFTPEntry {
		try await withTaskCancellationHandler {
			do {
				try Task.checkCancellation()
				let canonicalPath = try await handler.realPath(
					Self.protocolPath(for: path)
				).get()
				let attributes = try await handler.stat(canonicalPath).get()
				try Task.checkCancellation()
				return MobileSFTPEntry(
					path: canonicalPath,
					name: (canonicalPath as NSString).lastPathComponent,
					type: attributes.type,
					size: attributes.size,
					modificationDate: attributes.modificationDate,
					permissions: attributes.permissions.map { UInt16($0 & 0o7777) }
				)
			} catch is CancellationError {
				throw MobileSFTPError.cancelled
			} catch MobileSFTPError.notFound {
				throw MobileSFTPError.notFound(path: path)
			} catch {
				throw Self.map(error, path: path)
			}
		} onCancel: { [weak self] in
			self?.close()
		}
	}

	public func createDirectory(at path: String) async throws {
		try await withTaskCancellationHandler {
			do {
				try Task.checkCancellation()
				let protocolPath = Self.protocolPath(for: path)
				do {
					_ = try await handler.lstat(protocolPath).get()
					throw MobileSFTPError.alreadyExists(path: path)
				} catch MobileSFTPError.notFound {
					// The path is available at this instant; the server remains authoritative.
				}
				do {
					try await handler.createDirectory(protocolPath).get()
				} catch let failure as MobileSFTPError where failure.isGenericFailure {
					if (try? await handler.lstat(protocolPath).get()) != nil {
						throw MobileSFTPError.alreadyExists(path: path)
					}
					throw failure
				}
				try Task.checkCancellation()
			} catch is CancellationError {
				throw MobileSFTPError.cancelled
			} catch MobileSFTPError.alreadyExists {
				throw MobileSFTPError.alreadyExists(path: path)
			} catch {
				throw Self.map(error, path: path)
			}
		} onCancel: { [weak self] in
			self?.close()
		}
	}

	public func rename(from source: String, to destination: String) async throws {
		try await withTaskCancellationHandler {
			do {
				try Task.checkCancellation()
				let protocolSource = Self.protocolPath(for: source)
				let protocolDestination = Self.protocolPath(for: destination)
				do {
					_ = try await handler.lstat(protocolDestination).get()
					throw MobileSFTPError.alreadyExists(path: destination)
				} catch MobileSFTPError.notFound {
					// The destination is available at this instant; the server remains authoritative.
				}
				do {
					try await handler.rename(
						from: protocolSource,
						to: protocolDestination
					).get()
				} catch let failure as MobileSFTPError where failure.isGenericFailure {
					if (try? await handler.lstat(protocolDestination).get()) != nil {
						throw MobileSFTPError.alreadyExists(path: destination)
					}
					throw failure
				}
				try Task.checkCancellation()
			} catch is CancellationError {
				throw MobileSFTPError.cancelled
			} catch MobileSFTPError.alreadyExists {
				throw MobileSFTPError.alreadyExists(path: destination)
			} catch MobileSFTPError.notFound {
				throw MobileSFTPError.notFound(path: source)
			} catch {
				throw Self.map(error, path: source)
			}
		} onCancel: { [weak self] in
			self?.close()
		}
	}

	public func delete(at path: String, isDirectory: Bool) async throws {
		if isDirectory {
			let entries = try await listDirectory(at: path)
			guard entries.isEmpty else {
				throw MobileSFTPError.directoryNotEmpty(path: path)
			}
		}
		do {
			try await performMutation(path: path) { handler, protocolPath in
				if isDirectory {
					try await handler.removeDirectory(protocolPath).get()
				} else {
					try await handler.removeFile(protocolPath).get()
				}
			}
		} catch let failure as MobileSFTPError where failure.isGenericFailure && isDirectory {
			if let entries = try? await listDirectory(at: path), !entries.isEmpty {
				throw MobileSFTPError.directoryNotEmpty(path: path)
			}
			throw failure
		}
	}

	public func close() {
		lock.lock()
		guard !closed else {
			lock.unlock()
			return
		}
		closed = true
		lock.unlock()
		channel.close(promise: nil)
		connection.close(promise: nil)
		group.shutdownGracefully { error in
			if let error {
				NSLog("[MobileSFTPClient] Event loop shutdown failed: \(error)")
			}
		}
	}

	deinit { close() }

	private static func map(_ error: Error, path: String = "") -> Error {
		if let trust = error as? MobileSSHTrustError { return trust }
		if let key = error as? MobileSSHPrivateKeyError { return key }
		if let sftp = error as? MobileSFTPError { return sftp }
		if error is CancellationError { return MobileSFTPError.cancelled }
		return MobileSFTPError.transport(message: error.localizedDescription)
	}

	private func performMutation(
		path: String,
		operation: @escaping @Sendable (MobileSFTPChannelHandler, String) async throws -> Void
	) async throws {
		try await withTaskCancellationHandler {
			do {
				try Task.checkCancellation()
				try await operation(handler, Self.protocolPath(for: path))
				try Task.checkCancellation()
			} catch is CancellationError {
				throw MobileSFTPError.cancelled
			} catch MobileSFTPError.alreadyExists {
				throw MobileSFTPError.alreadyExists(path: path)
			} catch MobileSFTPError.directoryNotEmpty {
				throw MobileSFTPError.directoryNotEmpty(path: path)
			} catch MobileSFTPError.notFound {
				throw MobileSFTPError.notFound(path: path)
			} catch {
				throw Self.map(error, path: path)
			}
		} onCancel: { [weak self] in
			self?.close()
		}
	}

	private static func protocolPath(for path: String) -> String {
		if path == "~" { return "." }
		if path.hasPrefix("~/") { return "." + path.dropFirst() }
		return path
	}
}

private final class MobileSFTPConnectionAttempt: @unchecked Sendable {
	private let group: MultiThreadedEventLoopGroup
	private let lock = NSLock()
	private var connection: Channel?
	private var child: Channel?
	private var cancelled = false
	private var transferred = false
	private var shutdownStarted = false
	private var shutdownResult: Result<Void, Error>?
	private var shutdownWaiters: [CheckedContinuation<Error?, Never>] = []

	init(group: MultiThreadedEventLoopGroup) {
		self.group = group
	}

	func register(connection: Channel) throws {
		try register(channel: connection, asChild: false)
	}

	func register(child: Channel) throws {
		try register(channel: child, asChild: true)
	}

	func transferOwnership() throws {
		lock.lock()
		defer { lock.unlock() }
		guard !cancelled else { throw CancellationError() }
		transferred = true
		connection = nil
		child = nil
	}

	func cancel() {
		lock.lock()
		guard !transferred else {
			lock.unlock()
			return
		}
		cancelled = true
		let connection = self.connection
		let child = self.child
		let shouldShutdown = !shutdownStarted
		shutdownStarted = true
		lock.unlock()

		child?.close(promise: nil)
		connection?.close(promise: nil)
		if shouldShutdown {
			group.shutdownGracefully { [weak self] error in
				self?.finishShutdown(error)
			}
		}
	}

	func cleanup() async -> Error? {
		cancel()
		return await withCheckedContinuation { continuation in
			lock.lock()
			if let shutdownResult {
				lock.unlock()
				continuation.resume(returning: shutdownResult.failure)
			} else {
				shutdownWaiters.append(continuation)
				lock.unlock()
			}
		}
	}

	private func register(channel: Channel, asChild: Bool) throws {
		lock.lock()
		guard !cancelled, !transferred else {
			lock.unlock()
			channel.close(promise: nil)
			throw CancellationError()
		}
		if asChild {
			child = channel
		} else {
			connection = channel
		}
		lock.unlock()
	}

	private func finishShutdown(_ error: Error?) {
		lock.lock()
		shutdownResult = error.map(Result.failure) ?? .success(())
		let waiters = shutdownWaiters
		shutdownWaiters.removeAll()
		lock.unlock()
		for waiter in waiters { waiter.resume(returning: error) }
	}
}

private extension Result where Success == Void, Failure == Error {
	var failure: Error? {
		if case .failure(let error) = self { return error }
		return nil
	}
}

private final class MobileSFTPTrustFailureRelay: @unchecked Sendable {
	private let lock = NSLock()
	private var failure: MobileSSHTrustError?
	private var observer: (@Sendable (MobileSSHTrustError) -> Void)?

	func fail(_ error: MobileSSHTrustError) {
		lock.lock()
		if failure == nil { failure = error }
		let observer = self.observer
		lock.unlock()
		observer?(error)
	}

	func race(_ future: EventLoopFuture<Channel>) async throws -> Channel {
		try await withCheckedThrowingContinuation { continuation in
			let completion = MobileSFTPChannelCompletion(continuation)
			lock.lock()
			observer = { completion.resume(.failure($0)) }
			let failure = self.failure
			lock.unlock()
			if let failure { completion.resume(.failure(failure)) }
			future.whenComplete { completion.resume($0) }
		}
	}
}

private final class MobileSFTPChannelCompletion: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<Channel, Error>?

	init(_ continuation: CheckedContinuation<Channel, Error>) {
		self.continuation = continuation
	}

	func resume(_ result: Result<Channel, Error>) {
		lock.lock()
		guard let continuation else {
			lock.unlock()
			return
		}
		self.continuation = nil
		lock.unlock()
		continuation.resume(with: result)
	}
}

private final class MobileSFTPChannelHandler: ChannelInboundHandler,
	@unchecked Sendable {
	typealias InboundIn = SSHChannelData

	private var channel: Channel?
	private var inbound = ByteBuffer()
	private var nextRequestID: UInt32 = 1
	private var versionPromise: EventLoopPromise<UInt32>?
	private var responses: [UInt32: EventLoopPromise<SFTPResponse>] = [:]

	func handlerAdded(context: ChannelHandlerContext) {
		channel = context.channel
	}

	func initializeProtocol() -> EventLoopFuture<Void> {
		guard let channel else {
			return failedFuture(MobileSFTPError.disconnected)
		}
		return channel.eventLoop.flatSubmit {
			let promise = channel.eventLoop.makePromise(of: UInt32.self)
			self.versionPromise = promise
			var payload = channel.allocator.buffer(capacity: 5)
			payload.writeInteger(UInt8(1))
			payload.writeInteger(UInt32(3))
			return self.write(payload, on: channel).flatMap {
				promise.futureResult.flatMapThrowing { version in
					guard version == 3 else {
						throw MobileSFTPError.unsupportedVersion(version)
					}
				}
			}
		}
	}

	func realPath(_ path: String) -> EventLoopFuture<String> {
		send(type: 16) { $0.writeSFTPString(path) }.flatMapThrowing { response in
			guard case .names(let names) = response,
				let first = names.first else {
				throw response.error(path: path)
			}
			return first.name
		}
	}

	func openDirectory(_ path: String) -> EventLoopFuture<Data> {
		send(type: 11) { $0.writeSFTPString(path) }.flatMapThrowing { response in
			guard case .handle(let handle) = response else {
				throw response.error(path: path)
			}
			return handle
		}
	}

	func readDirectory(_ handle: Data) -> EventLoopFuture<SFTPDirectoryBatch> {
		send(type: 12) { $0.writeSFTPData(handle) }.flatMapThrowing { response in
			switch response {
			case .names(let names):
				.entries(names)
			case .status(let status) where status.code == 1:
				.end
			default:
				throw response.error(path: "")
			}
		}
	}

	func closeHandle(_ handle: Data) -> EventLoopFuture<Void> {
		send(type: 4) { $0.writeSFTPData(handle) }.flatMapThrowing { response in
			guard case .status(let status) = response, status.code == 0 else {
				throw response.error(path: "")
			}
		}
	}

	func stat(_ path: String) -> EventLoopFuture<SFTPAttributes> {
		send(type: 17) { $0.writeSFTPString(path) }.flatMapThrowing { response in
			guard case .attributes(let attributes) = response else {
				throw response.error(path: path)
			}
			return attributes
		}
	}

	func lstat(_ path: String) -> EventLoopFuture<SFTPAttributes> {
		send(type: 7) { $0.writeSFTPString(path) }.flatMapThrowing { response in
			guard case .attributes(let attributes) = response else {
				throw response.error(path: path)
			}
			return attributes
		}
	}

	func createDirectory(_ path: String) -> EventLoopFuture<Void> {
		send(type: 14) {
			$0.writeSFTPString(path)
			$0.writeInteger(UInt32(0))
		}.flatMapThrowing { response in
			try response.requireSuccess(path: path)
		}
	}

	func rename(from source: String, to destination: String) -> EventLoopFuture<Void> {
		send(type: 18) {
			$0.writeSFTPString(source)
			$0.writeSFTPString(destination)
		}.flatMapThrowing { response in
			try response.requireSuccess(path: source)
		}
	}

	func removeFile(_ path: String) -> EventLoopFuture<Void> {
		send(type: 13) { $0.writeSFTPString(path) }.flatMapThrowing { response in
			try response.requireSuccess(path: path)
		}
	}

	func removeDirectory(_ path: String) -> EventLoopFuture<Void> {
		send(type: 15) { $0.writeSFTPString(path) }.flatMapThrowing { response in
			try response.requireSuccess(path: path)
		}
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let value = unwrapInboundIn(data)
		guard case .byteBuffer(var bytes) = value.data else { return }
		inbound.writeBuffer(&bytes)
		do {
			while let packet = try inbound.readSFTPPacket() {
				try receive(packet)
			}
			inbound.discardReadBytes()
		} catch {
			failAll(error)
			context.close(promise: nil)
		}
	}

	func channelInactive(context: ChannelHandlerContext) {
		failAll(MobileSFTPError.disconnected)
		context.fireChannelInactive()
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		failAll(error)
		context.close(promise: nil)
	}

	private func send(
		type: UInt8,
		body: @escaping (inout ByteBuffer) -> Void
	) -> EventLoopFuture<SFTPResponse> {
		guard let channel else {
			return failedFuture(MobileSFTPError.disconnected)
		}
		return channel.eventLoop.flatSubmit {
			let id = self.nextRequestID
			self.nextRequestID &+= 1
			let promise = channel.eventLoop.makePromise(of: SFTPResponse.self)
			self.responses[id] = promise
			var payload = channel.allocator.buffer(capacity: 64)
			payload.writeInteger(type)
			payload.writeInteger(id)
			body(&payload)
			return self.write(payload, on: channel).flatMapError { error in
				self.responses.removeValue(forKey: id)?.fail(error)
				return channel.eventLoop.makeFailedFuture(error)
			}.flatMap { promise.futureResult }
		}
	}

	private func write(
		_ payload: ByteBuffer,
		on channel: Channel
	) -> EventLoopFuture<Void> {
		var payload = payload
		var frame = channel.allocator.buffer(capacity: payload.readableBytes + 4)
		frame.writeInteger(UInt32(payload.readableBytes))
		frame.writeBuffer(&payload)
		return channel.writeAndFlush(
			SSHChannelData(type: .channel, data: .byteBuffer(frame))
		)
	}

	private func receive(_ packet: ByteBuffer) throws {
		var packet = packet
		guard let type = packet.readInteger(as: UInt8.self) else {
			throw MobileSFTPError.invalidResponse(message: "Missing SFTP message type.")
		}
		if type == 2 {
			guard let version = packet.readInteger(as: UInt32.self) else {
				throw MobileSFTPError.invalidResponse(message: "Missing SFTP version.")
			}
			versionPromise?.succeed(version)
			versionPromise = nil
			return
		}
		guard let id = packet.readInteger(as: UInt32.self),
			let promise = responses.removeValue(forKey: id) else {
			throw MobileSFTPError.invalidResponse(
				message: "Unexpected SFTP response identifier."
			)
		}
		do {
			let payload = Data(packet.readableBytesView)
			promise.succeed(try MobileSFTPCodec.decodeResponse(
				type: type,
				payload: payload
			))
		} catch {
			promise.fail(error)
		}
	}

	private func failAll(_ error: Error) {
		versionPromise?.fail(error)
		versionPromise = nil
		let pending = responses.values
		responses.removeAll()
		for promise in pending { promise.fail(error) }
	}

	private func failedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
		if let channel { return channel.eventLoop.makeFailedFuture(error) }
		return MultiThreadedEventLoopGroup.singleton.any().makeFailedFuture(error)
	}
}

enum SFTPDirectoryBatch {
	case entries([SFTPName])
	case end
}

struct SFTPName {
	let name: String
	let attributes: SFTPAttributes

	func entry(parent: String) -> MobileSFTPEntry {
		let separator = parent == "/" ? "" : "/"
		return MobileSFTPEntry(
			path: "\(parent)\(separator)\(name)",
			name: name,
			type: attributes.type,
			size: attributes.size,
			modificationDate: attributes.modificationDate,
			permissions: attributes.permissions.map { UInt16($0 & 0o7777) }
		)
	}
}

struct SFTPAttributes {
	let size: Int64?
	let permissions: UInt32?
	let modificationDate: Date?

	var type: MobileSFTPEntryType {
		guard let permissions else { return .unknown }
		switch permissions & 0o170000 {
		case 0o040000: return .directory
		case 0o100000: return .file
		default: return .unknown
		}
	}
}

struct SFTPStatus {
	let code: UInt32
	let message: String
}

enum SFTPResponse {
	case status(SFTPStatus)
	case handle(Data)
	case names([SFTPName])
	case attributes(SFTPAttributes)

	init(type: UInt8, payload: inout ByteBuffer) throws {
		switch type {
		case 101:
			guard let code = payload.readInteger(as: UInt32.self),
				let message = payload.readSFTPString(),
				payload.readSFTPString() != nil else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP status.")
			}
			self = .status(SFTPStatus(code: code, message: message))
		case 102:
			guard let handle = payload.readSFTPData() else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP handle.")
			}
			self = .handle(handle)
		case 104:
			guard let count = payload.readInteger(as: UInt32.self), count <= 100_000 else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP name count.")
			}
			var names: [SFTPName] = []
			names.reserveCapacity(Int(count))
			for _ in 0..<count {
				guard let name = payload.readSFTPString(),
					payload.readSFTPString() != nil else {
					throw MobileSFTPError.invalidResponse(message: "Invalid SFTP name.")
				}
				names.append(SFTPName(
					name: name,
					attributes: try payload.readSFTPAttributes()
				))
			}
			self = .names(names)
		case 105:
			self = .attributes(try payload.readSFTPAttributes())
		default:
			throw MobileSFTPError.invalidResponse(
				message: "Unexpected SFTP response type \(type)."
			)
		}
	}

	func error(path: String) -> MobileSFTPError {
		guard case .status(let status) = self else {
			return .invalidResponse(message: "Unexpected SFTP response.")
		}
		switch status.code {
		case 2:
			return .notFound(path: path)
		case 3:
			return .permissionDenied(message: status.message)
		case 4:
			return .failure(path: path, message: status.message)
		case 7:
			return .disconnected
		default:
			return .transport(message: status.message.isEmpty
				? "SFTP request failed with status \(status.code)."
				: status.message)
		}
	}

	func requireSuccess(path: String) throws {
		guard case .status(let status) = self, status.code == 0 else {
			throw error(path: path)
		}
	}
}

private extension MobileSFTPError {
	var isGenericFailure: Bool {
		if case .failure = self { return true }
		return false
	}
}

enum MobileSFTPCodec {
	static func decodeResponse(type: UInt8, payload: Data) throws -> SFTPResponse {
		var buffer = ByteBuffer(bytes: payload)
		return try SFTPResponse(type: type, payload: &buffer)
	}
}

private extension ByteBuffer {
	mutating func readSFTPPacket() throws -> ByteBuffer? {
		guard readableBytes >= 4,
			let length = getInteger(at: readerIndex, as: UInt32.self) else {
			return nil
		}
		guard length <= 16 * 1_024 * 1_024 else {
			throw MobileSFTPError.invalidResponse(message: "SFTP packet is too large.")
		}
		guard readableBytes >= 4 + Int(length) else { return nil }
		moveReaderIndex(forwardBy: 4)
		return readSlice(length: Int(length))
	}

	mutating func writeSFTPString(_ value: String) {
		writeSFTPData(Data(value.utf8))
	}

	mutating func writeSFTPData(_ value: Data) {
		writeInteger(UInt32(value.count))
		writeBytes(value)
	}

	mutating func readSFTPData() -> Data? {
		guard let length = readInteger(as: UInt32.self),
			length <= UInt32(readableBytes),
			let bytes = readBytes(length: Int(length)) else { return nil }
		return Data(bytes)
	}

	mutating func readSFTPString() -> String? {
		guard let data = readSFTPData() else { return nil }
		return String(data: data, encoding: .utf8)
	}

	mutating func readSFTPAttributes() throws -> SFTPAttributes {
		guard let flags = readInteger(as: UInt32.self) else {
			throw MobileSFTPError.invalidResponse(message: "Missing SFTP attributes.")
		}
		let size: Int64?
		if flags & 0x1 != 0 {
			guard let value = readInteger(as: Int64.self) else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP size.")
			}
			size = value
		} else {
			size = nil
		}
		if flags & 0x2 != 0 {
			guard readInteger(as: UInt32.self) != nil,
				readInteger(as: UInt32.self) != nil else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP ownership.")
			}
		}
		let permissions: UInt32?
		if flags & 0x4 != 0 {
			guard let value = readInteger(as: UInt32.self) else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP permissions.")
			}
			permissions = value
		} else {
			permissions = nil
		}
		var modificationDate: Date?
		if flags & 0x8 != 0 {
			guard readInteger(as: UInt32.self) != nil,
				let modified = readInteger(as: UInt32.self) else {
				throw MobileSFTPError.invalidResponse(message: "Invalid SFTP timestamps.")
			}
			modificationDate = Date(timeIntervalSince1970: TimeInterval(modified))
		}
		if flags & 0x8000_0000 != 0 {
			guard let count = readInteger(as: UInt32.self), count <= 10_000 else {
				throw MobileSFTPError.invalidResponse(message: "Invalid extended attributes.")
			}
			for _ in 0..<count {
				guard readSFTPData() != nil, readSFTPData() != nil else {
					throw MobileSFTPError.invalidResponse(message: "Invalid extended attributes.")
				}
			}
		}
		return SFTPAttributes(
			size: size,
			permissions: permissions,
			modificationDate: modificationDate
		)
	}
}
