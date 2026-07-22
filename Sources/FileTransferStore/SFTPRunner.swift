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
			let proc = Process()
			proc.executableURL = URL(fileURLWithPath: inv.argv[0])
			proc.arguments = Array(inv.argv.dropFirst())
			if !inv.environment.isEmpty {
				var e = ProcessInfo.processInfo.environment
				for (k, v) in inv.environment { e[k] = v }
				proc.environment = e
			}
			let stdoutPipe = Pipe()
			let stdinPipe = Pipe()
			proc.standardOutput = stdoutPipe
			proc.standardInput = stdinPipe
			proc.standardError = stdoutPipe // merge for parsing simplicity
			proc.terminationHandler = { p in
				let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
				cancellation.clear(process: p)
				if cancellation.isCancelled {
					continuation.resume(throwing: CancellationError())
				} else {
					continuation.resume(returning: (
						String(data: data, encoding: .utf8) ?? "",
						p.terminationStatus
					))
				}
			}
			guard cancellation.install(proc) else {
				continuation.resume(throwing: CancellationError())
				return
			}
			do {
				try proc.run()
				if cancellation.isCancelled {
					proc.terminate()
					return
				}
				stdinPipe.fileHandleForWriting.write(
					inv.scriptStdin.data(using: .utf8) ?? Data()
				)
				try stdinPipe.fileHandleForWriting.close()
			} catch {
				cancellation.clear(process: proc)
				continuation.resume(throwing: error)
			}
		}
	}
}

private final class SFTPProcessCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var process: Process?
	private var cancelled = false

	var isCancelled: Bool {
		lock.lock()
		defer { lock.unlock() }
		return cancelled
	}

	func install(_ process: Process) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !cancelled else { return false }
		self.process = process
		return true
	}

	func cancel() {
		lock.lock()
		cancelled = true
		let process = process
		lock.unlock()
		if process?.isRunning == true {
			process?.terminate()
		}
	}

	func clear(process: Process) {
		lock.lock()
		if self.process === process {
			self.process = nil
		}
		lock.unlock()
	}
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
