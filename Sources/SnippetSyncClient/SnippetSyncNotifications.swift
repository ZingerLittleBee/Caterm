import Foundation

public extension Notification.Name {
	/// Posted by `AppDelegate.application(_:didReceiveRemoteNotification:)`
	/// when an APS notification matching the snippet subscription arrives.
	/// Observed by `SnippetSyncStore`.
	static let catermCloudKitSnippetChanged =
		Notification.Name("catermCloudKitSnippetChanged")

	/// View → Open Snippet Palette (⌘⇧P).
	static let catermOpenSnippetPalette =
		Notification.Name("catermOpenSnippetPalette")

	/// View → New Snippet… (⌘⇧S).
	static let catermNewSnippet =
		Notification.Name("catermNewSnippet")

	/// View → Manage Snippets…
	static let catermOpenSnippetManager =
		Notification.Name("catermOpenSnippetManager")
}
