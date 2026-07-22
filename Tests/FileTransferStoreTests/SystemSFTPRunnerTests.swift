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
}
#endif
