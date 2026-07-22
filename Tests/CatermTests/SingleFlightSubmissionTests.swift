import XCTest
@testable import Caterm

@MainActor
final class SingleFlightSubmissionTests: XCTestCase {
	func testSecondSubmissionIsRejectedUntilFirstFinishes() async {
		let submission = SingleFlightSubmission()
		let finished = expectation(description: "first submission finishes")
		var executionCount = 0

		XCTAssertTrue(submission.submit {
			executionCount += 1
			try? await Task.sleep(for: .milliseconds(30))
			finished.fulfill()
		})
		XCTAssertFalse(submission.submit { executionCount += 1 })
		XCTAssertTrue(submission.isSubmitting)

		await fulfillment(of: [finished], timeout: 1)
		await Task.yield()

		XCTAssertEqual(executionCount, 1)
		XCTAssertFalse(submission.isSubmitting)
	}

	func testCancelPropagatesToActiveOperation() async {
		let submission = SingleFlightSubmission()
		let cancelled = expectation(description: "submission observes cancellation")

		submission.submit {
			do {
				try await Task.sleep(for: .seconds(10))
			} catch is CancellationError {
				cancelled.fulfill()
			} catch {
				XCTFail("Unexpected error: \(error)")
			}
		}
		submission.cancel()

		await fulfillment(of: [cancelled], timeout: 1)
	}
}
