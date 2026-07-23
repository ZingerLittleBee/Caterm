import XCTest
@testable import Caterm

@MainActor
final class CredentialIdentitySyncSchedulerTests: XCTestCase {
	func testScheduleCoalescesRequestsIntoOneFollowUpPass() async {
		let gate = CredentialIdentitySyncTestGate()
		var callCount = 0
		let scheduler = CredentialIdentitySyncScheduler(
			isEnabled: { true },
			sync: {
				callCount += 1
				if callCount == 1 {
					await gate.wait()
				}
			}
		)

		scheduler.schedule()
		await waitUntil { callCount == 1 }
		scheduler.schedule()
		scheduler.schedule()
		await gate.release()
		await waitUntil { callCount == 2 }

		XCTAssertEqual(callCount, 2)
	}

	func testDisabledSchedulerDoesNotStartSync() async {
		var callCount = 0
		let scheduler = CredentialIdentitySyncScheduler(
			isEnabled: { false },
			sync: { callCount += 1 }
		)

		scheduler.schedule()
		for _ in 0..<10 {
			await Task.yield()
		}

		XCTAssertEqual(callCount, 0)
	}

	private func waitUntil(
		_ predicate: @escaping @MainActor () -> Bool
	) async {
		for _ in 0..<1_000 {
			if predicate() { return }
			await Task.yield()
		}
		XCTFail("Timed out waiting for scheduler state")
	}
}

private actor CredentialIdentitySyncTestGate {
	private var continuation: CheckedContinuation<Void, Never>?

	func wait() async {
		await withCheckedContinuation { continuation in
			self.continuation = continuation
		}
	}

	func release() {
		continuation?.resume()
		continuation = nil
	}
}
