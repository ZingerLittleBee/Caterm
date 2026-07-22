import AppKit
import Foundation
import SwiftUI

enum WindowCommandScope {
	static func shouldHandle(
		notificationObject: AnyObject?,
		receiverWindow: AnyObject?,
		receiverIsKeyWindow: Bool
	) -> Bool {
		guard let receiverWindow else { return false }
		if let notificationObject {
			return notificationObject === receiverWindow
		}
		return receiverIsKeyWindow
	}

	static func shouldHandle(_ notification: Notification, in window: NSWindow?) -> Bool {
		shouldHandle(
			notificationObject: notification.object as AnyObject?,
			receiverWindow: window,
			receiverIsKeyWindow: window?.isKeyWindow ?? false
		)
	}
}

struct SyncSettingsCommandBridge: View {
	@State private var window: NSWindow?
	let openSyncSettings: () -> Void

	var body: some View {
		WindowAccessor(window: $window)
			.frame(width: 0, height: 0)
			.onReceive(
				NotificationCenter.default.publisher(for: .catermOpenSyncSettings)
			) { notification in
				guard WindowCommandScope.shouldHandle(notification, in: window) else {
					return
				}
				openSyncSettings()
			}
	}
}
