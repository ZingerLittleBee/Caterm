import Foundation

package enum SyncSchedulingStrategy<Request> {
	/// A new request cancels the active pass, drains it, then runs exclusively.
	case latest
	/// Keep the active pass and merge all triggers into at most one follow-up.
	case coalescing(merge: (Request, Request) -> Request)
}

/// Main-actor single-flight scheduling for sync stores.
///
/// The scheduler owns task replacement, drain ordering, queued-trigger merging,
/// cancellation, and running-state transitions. Stores retain ownership of
/// domain gates such as sign-in state, manual-vs-automatic priority, and grace
/// barriers.
@MainActor
package final class SyncScheduler<Request> {
	package typealias Operation = @MainActor (Request) async throws -> Void
	package typealias RunningStateObserver = @MainActor (Bool) -> Void

	private let strategy: SyncSchedulingStrategy<Request>
	private let operation: Operation
	private let onRunningStateChange: RunningStateObserver
	private var activeTask: Task<Void, Error>?
	private var pendingRequest: Request?
	private var generation: UInt64 = 0

	package private(set) var isRunning = false

	package init(
		strategy: SyncSchedulingStrategy<Request>,
		onRunningStateChange: @escaping RunningStateObserver = { _ in },
		operation: @escaping Operation
	) {
		self.strategy = strategy
		self.operation = operation
		self.onRunningStateChange = onRunningStateChange
	}

	/// Submit a trigger and return the task representing its serialized cycle.
	@discardableResult
	package func submit(_ request: Request) -> Task<Void, Error> {
		switch strategy {
		case .latest:
			return submitLatest(request)
		case let .coalescing(merge):
			return submitCoalescing(request, merge: merge)
		}
	}

	/// Cancel queued and active work immediately. The active operation receives
	/// cooperative cancellation but remains the active lane until it exits.
	/// A replacement still drains it, so non-cooperative work cannot overlap.
	package func cancel() {
		pendingRequest = nil
		guard let activeTask else {
			setRunning(false)
			return
		}
		activeTask.cancel()
	}

	/// Cancel queued and active work, then wait until the active operation has
	/// fully exited. A newer submission is never cleared by this drain.
	package func cancelAndDrain() async {
		generation &+= 1
		let cancellationGeneration = generation
		pendingRequest = nil
		let task = activeTask
		task?.cancel()
		_ = await task?.result
		guard generation == cancellationGeneration else { return }
		activeTask = nil
		setRunning(false)
	}

	/// Test and lifecycle seam that waits through replacements and follow-ups.
	package func waitUntilIdle() async {
		while let task = activeTask {
			let observedGeneration = generation
			_ = await task.result
			if generation == observedGeneration { return }
		}
	}

	private func submitLatest(_ request: Request) -> Task<Void, Error> {
		let previous = activeTask
		previous?.cancel()
		generation &+= 1
		let submissionGeneration = generation
		setRunning(true)

		let task = Task { @MainActor [weak self] in
			defer { self?.finish(generation: submissionGeneration) }
			_ = await previous?.result
			try Task.checkCancellation()
			guard let self else { return }
			try await self.operation(request)
		}
		activeTask = task
		return task
	}

	private func submitCoalescing(
		_ request: Request,
		merge: (Request, Request) -> Request
	) -> Task<Void, Error> {
		if let activeTask {
			if activeTask.isCancelled {
				return launchCoalescing(request, after: activeTask)
			}
			if let pendingRequest {
				self.pendingRequest = merge(pendingRequest, request)
			} else {
				pendingRequest = request
			}
			return activeTask
		}

		return launchCoalescing(request, after: nil)
	}

	private func launchCoalescing(
		_ request: Request,
		after previous: Task<Void, Error>?
	) -> Task<Void, Error> {
		generation &+= 1
		let submissionGeneration = generation
		setRunning(true)
		let task = Task { @MainActor [weak self] in
			defer { self?.finish(generation: submissionGeneration) }
			_ = await previous?.result
			try Task.checkCancellation()
			guard let self else { return }
			var next: Request? = request
			while let current = next {
				try Task.checkCancellation()
				try await self.operation(current)
				try Task.checkCancellation()
				next = self.takePendingRequest()
			}
		}
		activeTask = task
		return task
	}

	private func takePendingRequest() -> Request? {
		defer { pendingRequest = nil }
		return pendingRequest
	}

	private func finish(generation completedGeneration: UInt64) {
		guard generation == completedGeneration else { return }
		activeTask = nil
		pendingRequest = nil
		setRunning(false)
	}

	private func setRunning(_ value: Bool) {
		guard isRunning != value else { return }
		isRunning = value
		onRunningStateChange(value)
	}
}
