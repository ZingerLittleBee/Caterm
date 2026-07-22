import Foundation
import SFTPCommandBuilder

public protocol SFTPRunner: Sendable {
	func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32)
}

public protocol ControlMasterLiveness: Sendable {
	func isAlive(hostId: UUID) async -> Bool
}

public enum SFTPRunnerUnavailable: Error, Equatable {
	/// SFTP transfers shell out to `/usr/bin/sftp` via `Process`, which is
	/// unavailable on iOS/iPadOS. Phase-1 mobile has no file transfer; this
	/// is the explicit unsupported state rather than a hidden no-op.
	case platformUnsupported
}

/// Non-macOS default runner. Construction is allowed so model-only mobile
/// code can link `FileTransferStore`; invoking a transfer throws the
/// explicit unsupported error instead of silently doing nothing.
public struct UnavailableSFTPRunner: SFTPRunner {
	public init() {}
	public func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
		throw SFTPRunnerUnavailable.platformUnsupported
	}
}

#if os(macOS)
import Darwin

public struct SystemSFTPRunner: SFTPRunner {
	typealias InputWriter = @Sendable (Int32, Data) throws -> Void

	private let inputWriter: InputWriter

	public init() {
		inputWriter = { fileDescriptor, data in
			try Self.writeAll(data, to: fileDescriptor)
		}
	}

	init(inputWriter: @escaping InputWriter) {
		self.inputWriter = inputWriter
	}
	public func run(_ inv: SFTPInvocation) async throws -> (stdout: String, exit: Int32) {
		let cancellation = SFTPProcessCancellation()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await run(inv, cancellation: cancellation)
		} onCancel: {
			cancellation.cancel()
		}
	}

	private func run(
		_ inv: SFTPInvocation,
		cancellation: SFTPProcessCancellation
	) async throws -> (stdout: String, exit: Int32) {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Int32), Error>) in
			let continuation = SFTPContinuationGate(cont)
			guard !inv.argv.isEmpty else {
				continuation.resume(throwing: SFTPProcessError.missingExecutable)
				return
			}
			let stdinPipe: SFTPPipe
			let stdoutPipe: SFTPPipe
			do {
				stdinPipe = try Self.makePipe()
				do {
					stdoutPipe = try Self.makePipe()
				} catch {
					Self.closeIgnoringFailure(stdinPipe.read)
					Self.closeIgnoringFailure(stdinPipe.write)
					throw error
				}
			} catch {
				continuation.resume(throwing: error)
				return
			}

			let processID: pid_t
			do {
				processID = try spawn(inv, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
			} catch {
				Self.closeIgnoringFailure(stdinPipe.read)
				Self.closeIgnoringFailure(stdinPipe.write)
				Self.closeIgnoringFailure(stdoutPipe.read)
				Self.closeIgnoringFailure(stdoutPipe.write)
				continuation.resume(throwing: error)
				return
			}

			cancellation.install(processID: processID)
			Self.startReaper(
				processID: processID,
				stdoutFileDescriptor: stdoutPipe.read,
				cancellation: cancellation,
				continuation: continuation
			)

			var descriptors = [stdinPipe.read, stdoutPipe.write, stdinPipe.write]
			do {
				try Self.closeDescriptor(descriptors[0])
				descriptors[0] = -1
				try Self.closeDescriptor(descriptors[1])
				descriptors[1] = -1
				guard fcntl(descriptors[2], F_SETNOSIGPIPE, 1) != -1 else {
					throw Self.posixError()
				}
				try inputWriter(
					descriptors[2],
					inv.scriptStdin.data(using: .utf8) ?? Data()
				)
				try Self.closeDescriptor(descriptors[2])
				descriptors[2] = -1
			} catch {
				let cleanupErrors = descriptors.filter { $0 >= 0 }.compactMap {
					Self.closeError($0)
				}
				let failure: Error = cleanupErrors.isEmpty
					? error
					: SFTPProcessError.postSpawnCleanupFailed(
						original: error.localizedDescription,
						cleanup: cleanupErrors
							.map(\.localizedDescription)
							.joined(separator: "; ")
					)
				cancellation.fail(processID: processID, error: failure)
			}
		}
	}

	private func spawn(
		_ invocation: SFTPInvocation,
		stdinPipe: SFTPPipe,
		stdoutPipe: SFTPPipe
	) throws -> pid_t {
		var actions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else {
			throw SFTPProcessError.spawnSetupFailed
		}
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawn_file_actions_adddup2(
			&actions, stdinPipe.read, STDIN_FILENO
		) == 0,
		posix_spawn_file_actions_adddup2(
			&actions, stdoutPipe.write, STDOUT_FILENO
		) == 0,
		posix_spawn_file_actions_adddup2(
			&actions, stdoutPipe.write, STDERR_FILENO
		) == 0,
		posix_spawn_file_actions_addclose(&actions, stdinPipe.read) == 0,
		posix_spawn_file_actions_addclose(&actions, stdinPipe.write) == 0,
		posix_spawn_file_actions_addclose(&actions, stdoutPipe.read) == 0,
		posix_spawn_file_actions_addclose(&actions, stdoutPipe.write) == 0 else {
			throw SFTPProcessError.spawnSetupFailed
		}

		var attributes: posix_spawnattr_t?
		guard posix_spawnattr_init(&attributes) == 0 else {
			throw SFTPProcessError.spawnSetupFailed
		}
		defer { posix_spawnattr_destroy(&attributes) }
		guard posix_spawnattr_setflags(
			&attributes,
			Int16(POSIX_SPAWN_SETPGROUP)
		) == 0,
		posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
			throw SFTPProcessError.spawnSetupFailed
		}

		var environment = ProcessInfo.processInfo.environment
		for (key, value) in invocation.environment {
			environment[key] = value
		}
		let environmentValues = environment
			.sorted { $0.key < $1.key }
			.map { "\($0.key)=\($0.value)" }
		return try withCStringArray(invocation.argv) { arguments in
			try withCStringArray(environmentValues) { environmentPointer in
				var processID: pid_t = 0
				let result = posix_spawn(
					&processID,
					arguments[0],
					&actions,
					&attributes,
					arguments.baseAddress,
					environmentPointer.baseAddress
				)
				guard result == 0 else {
					throw NSError(
						domain: NSPOSIXErrorDomain,
						code: Int(result)
					)
				}
				return processID
			}
		}
	}

	private func withCStringArray<Result>(
		_ strings: [String],
		body: (UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) throws -> Result
	) throws -> Result {
		var pointers = strings.map { strdup($0) }
		defer { pointers.forEach { free($0) } }
		pointers.append(nil)
		return try pointers.withUnsafeMutableBufferPointer { buffer in
			try body(buffer)
		}
	}

	private static func exitCode(from waitStatus: Int32) -> Int32 {
		let signal = waitStatus & 0x7f
		return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
	}

	private static func makePipe() throws -> SFTPPipe {
		var descriptors = [Int32](repeating: 0, count: 2)
		guard Darwin.pipe(&descriptors) == 0 else { throw posixError() }
		return SFTPPipe(read: descriptors[0], write: descriptors[1])
	}

	private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
		try data.withUnsafeBytes { bytes in
			guard let baseAddress = bytes.baseAddress else { return }
			var offset = 0
			while offset < bytes.count {
				let written = Darwin.write(
					fileDescriptor,
					baseAddress.advanced(by: offset),
					bytes.count - offset
				)
				if written == -1, errno == EINTR { continue }
				guard written > 0 else { throw posixError() }
				offset += written
			}
		}
	}

	private static func readAll(from fileDescriptor: Int32) throws -> Data {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 16_384)
		while true {
			let count = buffer.withUnsafeMutableBytes { bytes in
				Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
			}
			if count == 0 { return data }
			if count == -1, errno == EINTR { continue }
			guard count > 0 else { throw posixError() }
			data.append(contentsOf: buffer.prefix(count))
		}
	}

	private static func startReaper(
		processID: pid_t,
		stdoutFileDescriptor: Int32,
		cancellation: SFTPProcessCancellation,
		continuation: SFTPContinuationGate
	) {
		DispatchQueue.global(qos: .utility).async {
			let output = Result { try readAll(from: stdoutFileDescriptor) }
			let closeFailure = closeError(stdoutFileDescriptor)
			var status: Int32 = 0
			var waitResult: pid_t
			repeat {
				waitResult = waitpid(processID, &status, 0)
			} while waitResult == -1 && errno == EINTR
			let waitFailure = waitResult == -1 ? posixError() : nil
			let processFailure = cancellation.completionFailure
			let wasCancelled = cancellation.isCancelled
			cancellation.clear(processID: processID)

			if let processFailure {
				continuation.resume(throwing: processFailure)
			} else if let closeFailure {
				continuation.resume(throwing: closeFailure)
			} else if let waitFailure {
				continuation.resume(throwing: waitFailure)
			} else if case .failure(let error) = output {
				continuation.resume(throwing: error)
			} else if wasCancelled {
				continuation.resume(throwing: CancellationError())
			} else if case .success(let data) = output {
				continuation.resume(returning: (
					String(data: data, encoding: .utf8) ?? "",
					exitCode(from: status)
				))
			}
		}
	}

	private static func closeDescriptor(_ fileDescriptor: Int32) throws {
		guard Darwin.close(fileDescriptor) == 0 else { throw posixError() }
	}

	private static func closeError(_ fileDescriptor: Int32) -> Error? {
		guard Darwin.close(fileDescriptor) != 0 else { return nil }
		return posixError()
	}

	private static func closeIgnoringFailure(_ fileDescriptor: Int32) {
		_ = Darwin.close(fileDescriptor)
	}

	private static func posixError() -> NSError {
		NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
	}
}

private struct SFTPPipe: Sendable {
	let read: Int32
	let write: Int32
}

private final class SFTPProcessCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var processID: pid_t?
	private var cancelled = false
	private var failure: Error?
	private let escalationDelay = DispatchTimeInterval.milliseconds(250)

	var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}

	var completionFailure: Error? {
		lock.lock()
		defer { lock.unlock() }
		return failure
	}

	func install(processID: pid_t) {
		lock.lock()
		self.processID = processID
		let shouldTerminate = cancelled
		lock.unlock()
		if shouldTerminate { terminate(processGroup: processID) }
	}

	func cancel() {
		lock.lock()
		cancelled = true
		let processID = processID
		lock.unlock()
		guard let processID else { return }
		terminate(processGroup: processID)
	}

	func fail(processID: pid_t, error: Error) {
		lock.lock()
		if failure == nil { failure = error }
		lock.unlock()
		terminate(processGroup: processID)
	}

	func clear(processID: pid_t) {
		lock.lock()
		if self.processID == processID {
			self.processID = nil
		}
		lock.unlock()
	}

	private func terminate(processGroup: pid_t) {
		guard processGroup > 0 else { return }
		kill(-processGroup, SIGTERM)
		DispatchQueue.global(qos: .utility).asyncAfter(
			deadline: .now() + escalationDelay
		) {
			if kill(-processGroup, 0) == 0 {
				kill(-processGroup, SIGKILL)
			}
		}
	}
}

private enum SFTPProcessError: Error {
	case missingExecutable
	case spawnSetupFailed
	case postSpawnCleanupFailed(original: String, cleanup: String)
}

private final class SFTPContinuationGate: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<(String, Int32), Error>?

	init(_ continuation: CheckedContinuation<(String, Int32), Error>) {
		self.continuation = continuation
	}

	func resume(returning value: (String, Int32)) {
		resume(with: .success(value))
	}

	func resume(throwing error: Error) {
		resume(with: .failure(error))
	}

	private func resume(with result: Result<(String, Int32), Error>) {
		lock.lock()
		let continuation = continuation
		self.continuation = nil
		lock.unlock()
		continuation?.resume(with: result)
	}
}

public typealias DefaultSFTPRunner = SystemSFTPRunner
#else
public typealias DefaultSFTPRunner = UnavailableSFTPRunner
#endif
