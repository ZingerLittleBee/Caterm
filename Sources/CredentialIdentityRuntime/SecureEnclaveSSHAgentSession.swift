#if os(macOS)
import CredentialIdentitySecurity
import Darwin
import Foundation
import os

public enum SecureEnclaveSSHAgentSessionError: Error, Equatable {
	case socketCreationFailed(Int32)
	case directoryCreationFailed(Int32)
	case socketPathTooLong
	case bindFailed(Int32)
	case permissionFailed(Int32)
	case listenFailed(Int32)
	case cleanupFailed(operation: String, cleanup: String)
}

public final class SecureEnclaveSSHAgentSession: @unchecked Sendable {
	private static let log = Logger(
		subsystem: "com.caterm.app",
		category: "secure-enclave-ssh-agent"
	)
	public let socketURL: URL

	private let signer: any P256SSHAgentSigning
	private let comment: String
	private let directoryURL: URL
	private let queue: DispatchQueue
	private let lock = NSLock()
	private var listenerFileDescriptor: Int32
	private var activeClientFileDescriptor: Int32?
	private var isStopped = false

	public convenience init(
		key: SecureEnclaveIdentityKey,
		comment: String
	) throws {
		try self.init(
			signer: SecureEnclaveP256SSHAgentSigner(key: key),
			comment: comment
		)
	}

	public init(
		signer: any P256SSHAgentSigning,
		comment: String
	) throws {
		self.signer = signer
		self.comment = comment
		directoryURL = try Self.createPrivateDirectory()
		socketURL = directoryURL.appendingPathComponent("agent.sock")
		queue = DispatchQueue(
			label: "com.caterm.secure-enclave-ssh-agent.\(UUID().uuidString)",
			qos: .userInitiated
		)

		let fileDescriptor = socket(
			AF_UNIX,
			SOCK_STREAM,
			0
		)
			guard fileDescriptor >= 0 else {
				let code = errno
				do {
					try FileManager.default.removeItem(at: directoryURL)
				} catch {
					throw SecureEnclaveSSHAgentSessionError.cleanupFailed(
						operation: String(
							describing:
								SecureEnclaveSSHAgentSessionError
									.socketCreationFailed(code)
						),
						cleanup: String(describing: error)
					)
				}
				throw SecureEnclaveSSHAgentSessionError
					.socketCreationFailed(code)
		}
		listenerFileDescriptor = fileDescriptor

		do {
			try Self.bind(
				fileDescriptor: fileDescriptor,
				path: socketURL.path
			)
			guard chmod(socketURL.path, 0o600) == 0 else {
				throw SecureEnclaveSSHAgentSessionError
					.permissionFailed(errno)
			}
			guard listen(fileDescriptor, 4) == 0 else {
				throw SecureEnclaveSSHAgentSessionError
					.listenFailed(errno)
			}
			} catch {
				let operationError = error
				Darwin.close(fileDescriptor)
				unlink(socketURL.path)
				do {
					try FileManager.default.removeItem(at: directoryURL)
				} catch {
					throw SecureEnclaveSSHAgentSessionError.cleanupFailed(
						operation: String(describing: operationError),
						cleanup: String(describing: error)
					)
				}
				throw operationError
		}

		queue.async { [weak self] in
			self?.acceptConnections()
		}
	}

	deinit {
		stop()
	}

	public func stop() {
		lock.lock()
		guard !isStopped else {
			lock.unlock()
			return
		}
		isStopped = true
		let listener = listenerFileDescriptor
		listenerFileDescriptor = -1
		let client = activeClientFileDescriptor
		activeClientFileDescriptor = nil
		lock.unlock()

		if let client {
			shutdown(client, SHUT_RDWR)
			Darwin.close(client)
		}
		shutdown(listener, SHUT_RDWR)
		Darwin.close(listener)
			unlink(socketURL.path)
			do {
				try FileManager.default.removeItem(at: directoryURL)
			} catch {
				Self.log.error(
					"SSH agent directory cleanup failed: \(String(describing: error), privacy: .public)"
				)
			}
	}

	private func acceptConnections() {
		while true {
			lock.lock()
			let listener = listenerFileDescriptor
			let stopped = isStopped
			lock.unlock()
			guard !stopped, listener >= 0 else { return }

			let client = accept(listener, nil, nil)
			guard client >= 0 else {
				if errno == EINTR { continue }
				return
			}
			guard isSameUser(client) else {
				Darwin.close(client)
				continue
			}

			lock.lock()
			if isStopped {
				lock.unlock()
				Darwin.close(client)
				return
			}
			activeClientFileDescriptor = client
			lock.unlock()

			serve(client)

			lock.lock()
			if activeClientFileDescriptor == client {
				activeClientFileDescriptor = nil
				Darwin.close(client)
			}
			lock.unlock()
		}
	}

	private func serve(_ client: Int32) {
		while true {
			guard let header = readExactly(4, from: client) else {
				return
			}
			let length = header.reduce(UInt32(0)) {
				($0 << 8) | UInt32($1)
			}
			guard length > 0,
			      length <= UInt32(
			      	SecureEnclaveSSHAgentCodec.maximumMessageSize
			      ),
			      let message = readExactly(Int(length), from: client) else {
				return
			}

			let response: Data
			do {
				response = try SecureEnclaveSSHAgentCodec.response(
					to: message,
					signer: signer,
					comment: comment
				)
			} catch {
				response = SecureEnclaveSSHAgentCodec.failureResponse()
			}
			var frame = Data()
			frame.append(UInt8((response.count >> 24) & 0xff))
			frame.append(UInt8((response.count >> 16) & 0xff))
			frame.append(UInt8((response.count >> 8) & 0xff))
			frame.append(UInt8(response.count & 0xff))
			frame.append(response)
			guard writeAll(frame, to: client) else { return }
		}
	}

	private func readExactly(
		_ count: Int,
		from fileDescriptor: Int32
	) -> Data? {
		var result = Data(count: count)
		let didRead = result.withUnsafeMutableBytes { buffer -> Bool in
			guard let baseAddress = buffer.baseAddress else {
				return count == 0
			}
			var offset = 0
			while offset < count {
				let value = Darwin.read(
					fileDescriptor,
					baseAddress.advanced(by: offset),
					count - offset
				)
				if value > 0 {
					offset += value
				} else if value < 0, errno == EINTR {
					continue
				} else {
					return false
				}
			}
			return true
		}
		return didRead ? result : nil
	}

	private func writeAll(
		_ data: Data,
		to fileDescriptor: Int32
	) -> Bool {
		data.withUnsafeBytes { buffer -> Bool in
			guard let baseAddress = buffer.baseAddress else { return true }
			var offset = 0
			while offset < buffer.count {
				let value = Darwin.write(
					fileDescriptor,
					baseAddress.advanced(by: offset),
					buffer.count - offset
				)
				if value > 0 {
					offset += value
				} else if value < 0, errno == EINTR {
					continue
				} else {
					return false
				}
			}
			return true
		}
	}

	private func isSameUser(_ fileDescriptor: Int32) -> Bool {
		var userID = uid_t()
		var groupID = gid_t()
		return getpeereid(fileDescriptor, &userID, &groupID) == 0
			&& userID == geteuid()
	}

	private static func createPrivateDirectory() throws -> URL {
		for _ in 0..<8 {
			let suffix = UUID().uuidString
				.replacingOccurrences(of: "-", with: "")
				.lowercased()
			let url = URL(
				fileURLWithPath:
					"/tmp/caterm-agent-\(suffix)",
				isDirectory: true
			)
			if mkdir(url.path, 0o700) == 0 {
				return url
			}
			guard errno == EEXIST else {
				throw SecureEnclaveSSHAgentSessionError
					.directoryCreationFailed(errno)
			}
		}
		throw SecureEnclaveSSHAgentSessionError
			.directoryCreationFailed(EEXIST)
	}

	private static func bind(
		fileDescriptor: Int32,
		path: String
	) throws {
		let bytes = Array(path.utf8)
		var address = sockaddr_un()
		let capacity = MemoryLayout.size(
			ofValue: address.sun_path
		)
		guard bytes.count < capacity else {
			throw SecureEnclaveSSHAgentSessionError.socketPathTooLong
		}
		address.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &address.sun_path) { buffer in
			buffer.initializeMemory(as: UInt8.self, repeating: 0)
			buffer.copyBytes(from: bytes)
		}
		let result = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(
				to: sockaddr.self,
				capacity: 1
			) {
				Darwin.bind(
					fileDescriptor,
					$0,
					socklen_t(MemoryLayout<sockaddr_un>.size)
				)
			}
		}
		guard result == 0 else {
			throw SecureEnclaveSSHAgentSessionError.bindFailed(errno)
		}
	}
}
#endif
