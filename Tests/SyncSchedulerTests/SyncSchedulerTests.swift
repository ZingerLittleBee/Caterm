import SyncScheduler
import XCTest

@MainActor
final class SyncSchedulerTests: XCTestCase {
	private actor LatestProbe {
		private(set) var starts: [Int] = []
		private(set) var cancellations: [Int] = []
		private var activeCount = 0
		private(set) var maximumActiveCount = 0

		func run(_ value: Int) async throws {
			starts.append(value)
			activeCount += 1
			maximumActiveCount = max(maximumActiveCount, activeCount)
			defer { activeCount -= 1 }
			guard value == 1 else { return }
			do {
				try await Task.sleep(for: .seconds(10))
			} catch {
				cancellations.append(value)
				throw error
			}
		}

		func snapshot() -> (starts: [Int], cancellations: [Int], maximumActiveCount: Int) {
			(starts, cancellations, maximumActiveCount)
		}
	}

	private actor CoalescingProbe {
		private(set) var starts: [Int] = []
		private var firstContinuation: CheckedContinuation<Void, Never>?

		func run(_ value: Int) async {
			starts.append(value)
			guard starts.count == 1 else { return }
			await withCheckedContinuation { continuation in
				firstContinuation = continuation
			}
		}

		func releaseFirst() {
			firstContinuation?.resume()
			firstContinuation = nil
		}

		func startsSnapshot() -> [Int] { starts }
	}

	private actor NonCooperativeProbe {
		private let blockedValues: Set<Int>
		private(set) var starts: [Int] = []
		private var activeCount = 0
		private(set) var maximumActiveCount = 0
		private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

		init(blockedValues: Set<Int> = [1]) {
			self.blockedValues = blockedValues
		}

		func run(_ value: Int) async {
			starts.append(value)
			activeCount += 1
			maximumActiveCount = max(maximumActiveCount, activeCount)
			defer { activeCount -= 1 }
			guard blockedValues.contains(value) else { return }
			await withCheckedContinuation { continuation in
				continuations[value] = continuation
			}
		}

		func releaseFirst() {
			release(1)
		}

		func release(_ value: Int) {
			continuations.removeValue(forKey: value)?.resume()
		}

		func snapshot() -> (starts: [Int], maximumActiveCount: Int) {
			(starts, maximumActiveCount)
		}
	}

	func testLatestCancelsAndDrainsBeforeReplacement() async throws {
		let probe = LatestProbe()
		let scheduler = SyncScheduler<Int>(strategy: .latest) { value in
			try await probe.run(value)
		}
		_ = scheduler.submit(1)
		await waitUntil { await probe.starts == [1] }

		try await scheduler.submit(2).value

		let snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.starts, [1, 2])
		XCTAssertEqual(snapshot.cancellations, [1])
		XCTAssertEqual(snapshot.maximumActiveCount, 1)
	}

	func testCoalescingMergesTriggersIntoOneFollowUp() async {
		let probe = CoalescingProbe()
		let scheduler = SyncScheduler<Int>(
			strategy: .coalescing(merge: max)
		) { value in
			await probe.run(value)
		}
		_ = scheduler.submit(1)
		await waitUntil { await probe.starts == [1] }

		_ = scheduler.submit(2)
		_ = scheduler.submit(3)
		await probe.releaseFirst()
		await scheduler.waitUntilIdle()

		let starts = await probe.startsSnapshot()
		XCTAssertEqual(starts, [1, 3])
	}

	func testRunningStateDoesNotFlickerAcrossLatestReplacement() async throws {
		let probe = LatestProbe()
		var transitions: [Bool] = []
		let scheduler = SyncScheduler<Int>(
			strategy: .latest,
			onRunningStateChange: { transitions.append($0) }
		) { value in
			try await probe.run(value)
		}
		_ = scheduler.submit(1)
		await waitUntil { await probe.starts == [1] }

		try await scheduler.submit(2).value

		XCTAssertEqual(transitions, [true, false])
	}

	func testCancelAndDrainWaitsForActiveOperationToExit() async {
		let probe = LatestProbe()
		let scheduler = SyncScheduler<Int>(strategy: .latest) { value in
			try await probe.run(value)
		}
		_ = scheduler.submit(1)
		await waitUntil { await probe.starts == [1] }

		await scheduler.cancelAndDrain()

		XCTAssertFalse(scheduler.isRunning)
		let snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.cancellations, [1])
	}

	func testCancelKeepsNonCooperativeOperationInLaneUntilReplacementDrainsIt() async throws {
		let probe = NonCooperativeProbe()
		let scheduler = SyncScheduler<Int>(strategy: .latest) { value in
			await probe.run(value)
		}
		_ = scheduler.submit(1)
		await waitUntil { await probe.starts == [1] }

		scheduler.cancel()
		let replacement = scheduler.submit(2)
		for _ in 0..<20 { await Task.yield() }
		var snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.starts, [1])
		XCTAssertTrue(scheduler.isRunning)

		await probe.releaseFirst()
		try await replacement.value

		snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.starts, [1, 2])
		XCTAssertEqual(snapshot.maximumActiveCount, 1)
		XCTAssertFalse(scheduler.isRunning)
	}

	func testSubmissionDuringCancelAndDrainSurvivesTheOlderDrain() async throws {
		let probe = NonCooperativeProbe(blockedValues: [1, 2])
		let scheduler = SyncScheduler<Int>(strategy: .latest) { value in
			await probe.run(value)
		}
		let first = scheduler.submit(1)
		await waitUntil { await probe.starts == [1] }

		let drain = Task { await scheduler.cancelAndDrain() }
		await waitUntil { first.isCancelled }
		let replacement = scheduler.submit(2)

		for _ in 0..<20 { await Task.yield() }
		var snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.starts, [1])
		XCTAssertTrue(scheduler.isRunning)

		await probe.release(1)
		await drain.value
		await waitUntil { await probe.starts == [1, 2] }
		snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.maximumActiveCount, 1)
		XCTAssertTrue(
			scheduler.isRunning,
			"the older drain must not clear the replacement lane"
		)

		await probe.release(2)
		try await replacement.value

		snapshot = await probe.snapshot()
		XCTAssertEqual(snapshot.starts, [1, 2])
		XCTAssertEqual(snapshot.maximumActiveCount, 1)
		XCTAssertFalse(scheduler.isRunning)
	}

	func testOperationFailureClearsLaneForNextSubmission() async throws {
		enum ExpectedError: Error { case failed }
		var starts: [Int] = []
		let scheduler = SyncScheduler<Int>(strategy: .latest) { value in
			starts.append(value)
			if value == 1 { throw ExpectedError.failed }
		}

		do {
			try await scheduler.submit(1).value
			XCTFail("expected operation to fail")
		} catch ExpectedError.failed {
			// Expected.
		} catch {
			XCTFail("unexpected error: \(error)")
		}
		XCTAssertFalse(scheduler.isRunning)

		try await scheduler.submit(2).value
		XCTAssertEqual(starts, [1, 2])
		XCTAssertFalse(scheduler.isRunning)
	}

	private func waitUntil(
		_ predicate: @escaping () async -> Bool
	) async {
		for _ in 0..<1_000 {
			if await predicate() { return }
			await Task.yield()
		}
		XCTFail("condition was not reached")
	}
}
