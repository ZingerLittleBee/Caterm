import Foundation

@MainActor
final class CredentialIdentitySyncScheduler {
	private let isEnabled: () -> Bool
	private let sync: () async throws -> Void
	private let reportFailure: (any Error) -> Void
	private var isRunning = false
	private var needsAnotherPass = false

	init(
		isEnabled: @escaping () -> Bool,
		sync: @escaping () async throws -> Void,
		reportFailure: @escaping (any Error) -> Void = { _ in }
	) {
		self.isEnabled = isEnabled
		self.sync = sync
		self.reportFailure = reportFailure
	}

	func schedule() {
		guard isEnabled() else { return }
		needsAnotherPass = true
		guard !isRunning else { return }
		isRunning = true
		Task { @MainActor [weak self] in
			await self?.drain()
		}
	}

	private func drain() async {
		while needsAnotherPass, isEnabled() {
			needsAnotherPass = false
			do {
				try await sync()
			} catch {
				reportFailure(error)
			}
		}
		isRunning = false
	}
}
