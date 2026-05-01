import AppKit
import FileTransferStore

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var observer: NSObjectProtocol?

	/// On app quit we synchronously tear down all live ControlMaster
	/// sockets. Runs on a background dispatch group with a 1-second timeout
	/// so a stuck `ssh -O exit` cannot block app termination indefinitely.
	func applicationWillTerminate(_: Notification) {
		let group = DispatchGroup()
		group.enter()
		Task { @MainActor in
			await ControlMasterManager.shared.tearDownAll()
			group.leave()
		}
		_ = group.wait(timeout: .now() + 1.0)
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
