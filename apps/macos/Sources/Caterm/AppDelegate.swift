import AppKit
import FileTransferStore

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var observer: NSObjectProtocol?

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
	}
}
