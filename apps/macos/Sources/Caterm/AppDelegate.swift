import AppKit
import CloudKit
import CloudKitSyncClient
import FileTransferStore
import os
import Security
import ServerSyncClient
import SnippetSyncClient

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var observer: NSObjectProtocol?
	private static let pushLog = Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")
	private static let signingDiagLog = Logger(subsystem: "com.caterm.app", category: "signing-diag")

	/// On app quit, tear down all live ControlMaster sockets so the
	/// shared `ssh -M` masters exit cleanly instead of being killed by
	/// SIGTERM. We dispatch into a detached Task and block the calling
	/// thread (the AppKit termination thread) on a semaphore with a
	/// 1-second timeout so a stuck `ssh -O exit` cannot block app
	/// termination indefinitely.
	///
	/// The earlier `Task { @MainActor in … } + DispatchGroup.wait()`
	/// pattern deadlocked once sockets actually existed: this method is
	/// invoked on the main thread, so the inner `Task { @MainActor }` is
	/// scheduled to run on the same thread we're blocking via
	/// `group.wait`. A `Task.detached` (with `await` hopping back onto
	/// the main actor inside `tearDownAll`) avoids that inversion.
	func applicationWillTerminate(_: Notification) {
		let semaphore = DispatchSemaphore(value: 0)
		Task.detached {
			await ControlMasterManager.shared.tearDownAll()
			semaphore.signal()
		}
		_ = semaphore.wait(timeout: .now() + 1.0)
	}

	func applicationDidFinishLaunching(_: Notification) {
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		// Each SwiftUI WindowGroup window for a tabId becomes its own NSWindow.
		// With automatic tabbing on, macOS merges windows of the same kind into
		// the OS-provided native tab bar (like Safari/Terminal.app).
		NSWindow.allowsAutomaticWindowTabbing = true

		// SwiftUI's WindowGroup leaves each NSWindow's `tabbingMode` at
		// `.automatic`, which only auto-tabs when the user's system-wide
		// "Prefer tabs" pref is `.always` (System Settings > Desktop & Dock).
		// We override every spawned window to `.preferred` so AppKit always
		// merges new windows of this group into the existing tab bar,
		// independent of the user's system preference. Same `tabbingIdentifier`
		// across windows is what makes them group together; SwiftUI assigns a
		// stable identifier per WindowGroup, so we just need to opt into
		// preferred tabbing per window.
		observer = NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification,
			object: nil, queue: .main
		) { note in
			guard let win = note.object as? NSWindow else { return }
			if win.tabbingMode == .automatic {
				win.tabbingMode = .preferred
			}
		}
		NSApp.registerForRemoteNotifications()
		Self.logResolvedSigningEnvironment()
	}

	/// One-shot diagnostic at launch: read the running process's signing
	/// entitlements via `SecCodeCopySigningInformation` and log the resolved
	/// CloudKit container env + APS env. Plan E Task 3.0 Step 6.
	///
	/// In Production we expect `aps=production`, `ck-env=Production`. In dev
	/// we expect `aps=development` and `ck-env=<unset>` (the dev entitlements
	/// file has no `com.apple.developer.icloud-container-environment` — the
	/// CloudKit framework defaults to Development when unset and a development
	/// profile is embedded). Filter `Console.app` on subsystem
	/// `com.caterm.app` and category `signing-diag` to confirm.
	private static func logResolvedSigningEnvironment() {
		var dynCode: SecCode?
		let status = SecCodeCopySelf([], &dynCode)
		guard status == errSecSuccess, let code = dynCode else {
			signingDiagLog.error("SecCodeCopySelf failed: status=\(status)")
			return
		}
		var staticCode: SecStaticCode?
		let s1 = SecCodeCopyStaticCode(code, [], &staticCode)
		guard s1 == errSecSuccess, let staticCode else {
			signingDiagLog.error("SecCodeCopyStaticCode failed: status=\(s1)")
			return
		}
		var info: CFDictionary?
		let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
		let s2 = SecCodeCopySigningInformation(staticCode, flags, &info)
		guard s2 == errSecSuccess,
		      let dict = info as? [String: Any],
		      let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
		else {
			signingDiagLog.error("SecCodeCopySigningInformation failed: status=\(s2)")
			return
		}
		let aps = (entitlements["com.apple.developer.aps-environment"] as? String) ?? "<unset>"
		let ck = (entitlements["com.apple.developer.icloud-container-environment"] as? String) ?? "<unset>"
		signingDiagLog.info("Resolved entitlements: aps=\(aps, privacy: .public) ck-env=\(ck, privacy: .public)")
	}

	func application(_: NSApplication,
	                 didReceiveRemoteNotification userInfo: [String: Any]) {
		guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return }
		switch note.subscriptionID {
		case CloudKitPushNames.hostSubscriptionID:
			Self.pushLog.info("CloudKit Host push received → triggering sync")
			NotificationCenter.default.post(name: .catermCloudKitHostChanged, object: nil)
		case CloudKitPushNames.snippetSubscriptionID:
			Self.pushLog.info("CloudKit Snippet push received → triggering sync")
			NotificationCenter.default.post(name: .catermCloudKitSnippetChanged, object: nil)
		default:
			break
		}
	}

	func application(_: NSApplication,
	                 didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
		Self.pushLog.info("APS register OK: token-bytes=\(token.count)")
	}

	func application(_: NSApplication,
	                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
		Self.pushLog.error("APS register failed: \(error.localizedDescription)")
	}
}
