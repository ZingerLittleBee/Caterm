import AppKit
import GhosttyKit

/// URL hover + ⌘-click open. libghostty detects URLs in the terminal grid via
/// regex; on hover-with-⌘ it fires `GHOSTTY_ACTION_MOUSE_OVER_LINK`, and on
/// click it fires `GHOSTTY_ACTION_OPEN_URL`. We surface hover state through
/// `cursorUpdate(with:)` (so the cursor flips to `pointingHand`) and route
/// open requests through `NSWorkspace` after a scheme whitelist check.
extension GhosttySurfaceNSView {

	/// Wire the `GhosttySurface` URL hooks to view-side state. Called from
	/// `viewDidMoveToWindow` once the surface is alive.
	func wireURLHandlers() {
		guard let surface else { return }
		surface.onHoverURL = { [weak self] url in
			guard let self else { return }
			self.hoveredURL = url
			// `cursorUpdate(with:)` is the AppKit hook that fires on the
			// next mouse-motion event; ask AppKit to schedule one so the
			// pointing-hand flip happens promptly. `flagsChanged` is the
			// other path — when ⌘ is pressed/released without motion.
			self.window?.invalidateCursorRects(for: self)
		}
		surface.onOpenURL = { [weak self] urlString, _ in
			self?.openURL(urlString)
		}
	}

	/// Open `urlString` after a scheme whitelist check. Whitelisted schemes
	/// (`http`, `https`, `mailto`, `ssh`, `ftp`, `ftps`) go straight to
	/// `NSWorkspace.open`; anything else triggers a confirm sheet so a
	/// remote SSH host can't trick the user into opening a `file:` or
	/// `javascript:` URL by printing it.
	fileprivate func openURL(_ urlString: String) {
		guard let url = URL(string: urlString),
		      let scheme = url.scheme
		else { return }

		if isSafeURLScheme(scheme) {
			NSWorkspace.shared.open(url)
			return
		}

		guard let win = window else { return }
		let alert = NSAlert()
		alert.messageText = "Open this URL?"
		alert.informativeText = "The URL uses scheme \"\(scheme)\" which Caterm doesn't open by default:\n\n\(urlString)"
		alert.alertStyle = .warning
		alert.addButton(withTitle: "Cancel")     // default
		alert.addButton(withTitle: "Open")
		alert.beginSheetModal(for: win) { resp in
			if resp == .alertSecondButtonReturn {
				NSWorkspace.shared.open(url)
			}
		}
	}
}
