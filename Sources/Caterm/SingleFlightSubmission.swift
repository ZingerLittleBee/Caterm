import Combine
import Foundation

@MainActor
final class SingleFlightSubmission: ObservableObject {
	@Published private(set) var isSubmitting = false
	private var task: Task<Void, Never>?

	@discardableResult
	func submit(_ operation: @escaping @MainActor () async -> Void) -> Bool {
		guard task == nil else { return false }
		isSubmitting = true
		task = Task { @MainActor [weak self] in
			await operation()
			guard let self else { return }
			task = nil
			isSubmitting = false
		}
		return true
	}

	func cancel() {
		task?.cancel()
	}
}
