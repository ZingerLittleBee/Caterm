import Foundation

@MainActor
func postKVSExternalChange(reason: Int) {
	NotificationCenter.default.post(
		name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
		object: nil,
		userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
	)
}
