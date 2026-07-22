#if os(macOS)
import Foundation
import XCTest
@testable import FileTransferStore
import SFTPCommandBuilder

final class SystemSFTPRunnerTests: XCTestCase {
	func testCancellingRunTerminatesSubprocessPromptly() async throws {
		let invocation = SFTPInvocation(
			argv: ["/bin/sleep", "2"],
			environment: [:],
			scriptStdin: ""
		)
		let task = Task {
			try await SystemSFTPRunner().run(invocation)
		}
		try await Task.sleep(for: .milliseconds(100))
		let clock = ContinuousClock()
		let started = clock.now
		task.cancel()

		do {
			_ = try await task.value
			XCTFail("Expected cancellation")
		} catch is CancellationError {
			// Expected.
		}

		XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
	}

	func testCancellationEscalatesWhenSubprocessIgnoresTerm() async throws {
		let invocation = SFTPInvocation(
			argv: [
				"/bin/sh",
				"-c",
				"trap '' TERM; while :; do sleep 1; done",
			],
			environment: [:],
			scriptStdin: ""
		)
		let task = Task { try await SystemSFTPRunner().run(invocation) }
		try await Task.sleep(for: .milliseconds(100))
		let clock = ContinuousClock()
		let started = clock.now
		task.cancel()

		do {
			_ = try await task.value
			XCTFail("Expected cancellation")
		} catch is CancellationError {
			// Expected.
		}

		XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
	}

	func testCancellationTerminatesChildProcessGroup() async throws {
		let sentinel = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-child-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: sentinel) }
		let invocation = SFTPInvocation(
			argv: [
				"/bin/sh",
				"-c",
				"trap '' TERM; (sleep 1; printf child > \"$1\") & while :; do sleep 1; done",
				"caterm-sftp-fixture",
				sentinel.path,
			],
			environment: [:],
			scriptStdin: ""
		)
		let task = Task { try await SystemSFTPRunner().run(invocation) }
		try await Task.sleep(for: .milliseconds(100))
		task.cancel()

		do {
			_ = try await task.value
			XCTFail("Expected cancellation")
		} catch is CancellationError {
			// Expected.
		}
		try await Task.sleep(for: .milliseconds(1_200))

		XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
	}

	func testLargeOutputDoesNotDeadlockPipe() async throws {
		let invocation = SFTPInvocation(
			argv: [
				"/bin/sh",
				"-c",
				"dd if=/dev/zero bs=1048576 count=2 2>/dev/null",
			],
			environment: [:],
			scriptStdin: ""
		)

		let result = try await SystemSFTPRunner().run(invocation)

		XCTAssertEqual(result.exit, 0)
		XCTAssertEqual(result.stdout.utf8.count, 2 * 1_048_576)
	}

	func testInputWriteFailureReapsProcessGroup() async throws {
		let sentinel = FileManager.default.temporaryDirectory
			.appendingPathComponent("caterm-sftp-write-failure-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: sentinel) }
		let invocation = SFTPInvocation(
			argv: [
				"/bin/sh",
				"-c",
				"trap '' TERM; (sleep 1; printf child > \"$1\") & cat",
				"caterm-sftp-fixture",
				sentinel.path,
			],
			environment: [:],
			scriptStdin: "trigger write"
		)
		let runner = SystemSFTPRunner(inputWriter: { _, _ in
			throw InputFailure.fixture
		})

		do {
			_ = try await runner.run(invocation)
			XCTFail("Expected input failure")
		} catch InputFailure.fixture {
			// Expected.
		}
		try await Task.sleep(for: .milliseconds(1_200))

		XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
	}

	func testCancellationWinsRaceWithSubsequentInputFailure() async throws {
		let gate = InputWriterGate()
		let invocation = SFTPInvocation(
			argv: ["/bin/sh", "-c", "trap '' TERM; cat"],
			environment: [:],
			scriptStdin: "trigger write"
		)
		let runner = SystemSFTPRunner(inputWriter: { _, _ in
			gate.started.signal()
			gate.release.wait()
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
		})
		let task = Task { try await runner.run(invocation) }
		XCTAssertEqual(gate.started.wait(timeout: .now() + 1), .success)

		task.cancel()
		gate.release.signal()

		do {
			_ = try await task.value
			XCTFail("Expected cancellation")
		} catch is CancellationError {
			// Expected.
		}
	}
}

private enum InputFailure: LocalizedError {
	case fixture

	var errorDescription: String? { "fixture input failure" }
}

private final class InputWriterGate: @unchecked Sendable {
	let started = DispatchSemaphore(value: 0)
	let release = DispatchSemaphore(value: 0)
}
#endif
