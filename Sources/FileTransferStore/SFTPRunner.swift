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
	public init() {}
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
			let stdoutPipe = Pipe()
			let stdinPipe = Pipe()
			do {
				let processID = try spawn(
					inv,
					stdinFileDescriptor: stdinPipe.fileHandleForReading.fileDescriptor,
					stdoutFileDescriptor: stdoutPipe.fileHandleForWriting.fileDescriptor
				)
				try stdinPipe.fileHandleForReading.close()
				try stdoutPipe.fileHandleForWriting.close()
				cancellation.install(processID: processID)

				DispatchQueue.global(qos: .utility).async {
				let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
					var status: Int32 = 0
					while waitpid(processID, &status, 0) == -1, errno == EINTR {}
					cancellation.clear(processID: processID)
				if cancellation.isCancelled {
					continuation.resume(throwing: CancellationError())
				} else {
					continuation.resume(returning: (
						String(data: data, encoding: .utf8) ?? "",
						Self.exitCode(from: status)
					))
				}
				}
				try? stdinPipe.fileHandleForWriting.write(
					contentsOf: inv.scriptStdin.data(using: .utf8) ?? Data()
				)
				try stdinPipe.fileHandleForWriting.close()
			} catch {
				continuation.resume(throwing: error)
			}
		}
	}

	private func spawn(
		_ invocation: SFTPInvocation,
		stdinFileDescriptor: Int32,
		stdoutFileDescriptor: Int32
	) throws -> pid_t {
		var actions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else {
			throw SFTPProcessError.spawnSetupFailed
		}
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_adddup2(&actions, stdinFileDescriptor, STDIN_FILENO)
		posix_spawn_file_actions_adddup2(&actions, stdoutFileDescriptor, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&actions, stdoutFileDescriptor, STDERR_FILENO)

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
}

private final class SFTPProcessCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var processID: pid_t?
	private var cancelled = false
	private let escalationDelay = DispatchTimeInterval.milliseconds(250)

	var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
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
