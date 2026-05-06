import Foundation
import GhosttyKit
import SnippetSyncClient

@MainActor
public extension GhosttySurface {
	/// Paste mode: deliver content through the paste path. Bracketed-paste
	/// wrapping (when the shell has mode 2004 enabled) keeps multi-line
	/// content sitting at the prompt for the user to inspect / press Return.
	func pasteSnippet(_ content: String) {
		guard !content.isEmpty else { return }
		// Defensive: clear any stale preedit before injecting. The palette
		// owns focus so this is normally already empty; idempotent.
		setPreedit("")
		sendText(content)
	}

	/// Run mode: deliver content via the paste path, then a synthesized
	/// Return keystroke via the keyboard-protocol path. The bracketed-paste
	/// end-marker (\e[201~) released by the body causes readline to finalize
	/// paste mode; the subsequent synthesized \r is delivered as a real
	/// Return and submits the buffered line(s) to the shell for execution.
	func executeSnippet(_ content: String) {
		guard !content.isEmpty else { return }
		setPreedit("")
		sendText(content)
		sendSynthesizedReturn()
	}

	/// Builds a ghostty_input_key_s for the Return key directly (no NSEvent
	/// synthesis) and calls ghostty_surface_key. Mirrors the field choices
	/// in `sendKey(_:composing:)` for a real Return event.
	private func sendSynthesizedReturn() {
		var k = ghostty_input_key_s()
		k.action = GHOSTTY_ACTION_PRESS
		k.mods = ghostty_input_mods_e(0)
		k.consumed_mods = ghostty_input_mods_e(0)
		k.keycode = 0x24
		k.unshifted_codepoint = 0x0D
		k.text = nil
		k.composing = false
		_ = ghostty_surface_key(raw, k)
	}
}

extension GhosttySurface: SnippetDispatchTarget {
	public func paste(_ text: String) { pasteSnippet(text) }
	public func run(_ text: String) { executeSnippet(text) }
}
