import AppKit

/// Sheet-based confirmation prompt for OSC 52 *read* requests (a remote
/// process asking the host clipboard's current contents).
///
/// Per spec §5.4 policy B, OSC 52 *write* requests are auto-allowed; only
/// reads need confirmation. The sheet defaults to **Deny** — pressing Enter
/// or Esc denies — to make the safer outcome the default.
@MainActor
public enum ClipboardConfirm {
	public static func present(on window: NSWindow?, completion: @escaping (Bool) -> Void) {
		guard let window else {
			completion(false)
			return
		}
		let alert = NSAlert()
		alert.messageText = "Allow remote process to read your clipboard?"
		alert.informativeText = """
		A program running in this terminal is requesting the contents of your \
		system clipboard. Only allow this if you trust the remote session.
		"""
		alert.alertStyle = .warning
		alert.addButton(withTitle: "Deny")        // first button is default → Enter / Esc denies
		alert.addButton(withTitle: "Allow Once")

		alert.beginSheetModal(for: window) { resp in
			completion(resp == .alertSecondButtonReturn)
		}
	}
}
