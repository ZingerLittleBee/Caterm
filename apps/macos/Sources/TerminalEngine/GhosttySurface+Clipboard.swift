import AppKit
import GhosttyKit

/// Thin wrappers around libghostty's selection / clipboard / binding-action
/// C API. Kept separate from the main `GhosttySurface` body so callsites in
/// the AppKit responder chain (Edit menu, drag-drop, context menu) can stay
/// at the NSView layer without dragging libghostty includes around.
@MainActor
public extension GhosttySurface {
	/// Whether libghostty currently has an active selection in this surface.
	var hasSelection: Bool {
		ghostty_surface_has_selection(raw)
	}

	/// Copies the current selection into a Swift `String`, or returns nil if
	/// there is no selection. The libghostty-owned text buffer is freed via
	/// `ghostty_surface_free_text` before this method returns.
	func readSelection() -> String? {
		guard hasSelection else { return nil }
		var text = ghostty_text_s()
		guard ghostty_surface_read_selection(raw, &text) else { return nil }
		defer { ghostty_surface_free_text(raw, &text) }
		guard let bytes = text.text else { return nil }
		return String(cString: bytes)
	}

	/// Triggers a libghostty named binding action (e.g. `paste_from_clipboard`).
	/// Returns `false` if libghostty rejected the action.
	@discardableResult
	func triggerBindingAction(_ action: String) -> Bool {
		action.withCString { ptr in
			ghostty_surface_binding_action(raw, ptr, UInt(strlen(ptr)))
		}
	}
}
