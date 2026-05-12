import Foundation

enum CloudSyncRuntimeOptions {
	private static let disableCloudSyncKey = "CATERM_DISABLE_CLOUD_SYNC"

	static func cloudSyncDisabled(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> Bool {
		guard let value = environment[disableCloudSyncKey] else { return false }
		switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "1", "true", "yes", "on":
			return true
		default:
			return false
		}
	}
}
