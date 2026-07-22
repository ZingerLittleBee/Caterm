#if canImport(UIKit)
import CloudKitSyncClient
import os
import ServerSyncClient
import UIKit

public final class MobilePushDelegate: NSObject, UIApplicationDelegate {
	private static let log = Logger(
		subsystem: "app.caterm.mobile",
		category: "cloudkit-push"
	)
	public var hostPushHandler: (@MainActor () async -> MobileHostSyncExecutionResult)?
	public var snippetPushHandler: (@MainActor () async -> MobileHostSyncExecutionResult)?

	public func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions _: [
			UIApplication.LaunchOptionsKey: Any
		]? = nil
	) -> Bool {
		application.registerForRemoteNotifications()
		return true
	}

	public func application(
		_: UIApplication,
		didReceiveRemoteNotification userInfo: [AnyHashable: Any],
		fetchCompletionHandler completionHandler: @escaping (
			UIBackgroundFetchResult
		) -> Void
	) {
		let payload: [String: Any] = Dictionary(
			uniqueKeysWithValues: userInfo.compactMap {
			guard let key = $0.key as? String else { return nil }
			return (key, $0.value)
			}
		)
		guard let pushKind = cloudKitPushKind(payload) else {
			completionHandler(.noData)
			return
		}
		let handler: (@MainActor () async -> MobileHostSyncExecutionResult)?
		switch pushKind {
		case .host:
			handler = hostPushHandler
		case .snippet:
			handler = snippetPushHandler
		}
		guard let handler else {
			completionHandler(.failed)
			return
		}
		Task { @MainActor in
			switch await handler() {
			case .newData:
				completionHandler(.newData)
			case .noData:
				completionHandler(.noData)
			case .failed, .cancelled:
				completionHandler(.failed)
			}
		}
	}

	public func application(
		_: UIApplication,
		didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
	) {
		Self.log.info("APS registration succeeded: bytes=\(deviceToken.count)")
	}

	public func application(
		_: UIApplication,
		didFailToRegisterForRemoteNotificationsWithError error: any Error
	) {
		Self.log.error(
			"APS registration failed: \(error.localizedDescription, privacy: .public)"
		)
	}
}
#endif
