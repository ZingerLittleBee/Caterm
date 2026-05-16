import AppKit
import GhosttyKit

/// Thin wrappers around libghostty's IME / preedit C API. Drives the
/// `NSTextInputClient` flow on the host view: committed text goes through
/// `sendText`, in-flight composition (preedit) through `setPreedit`, and the
/// candidate panel anchor is fetched via `imePoint`.
///
/// All three calls are main-thread only (libghostty surface API is not
/// thread-safe; `NSTextInputClient` is a main-thread protocol anyway).
@MainActor
public extension GhosttySurface {
	/// Committed text (e.g. IME-confirmed Chinese characters, or US-Intl
	/// dead-key composed `é`). Bypasses the keyboard event path so it does
	/// not collide with the raw `NSEvent` we already forwarded via
	/// `sendKey(..., composing: true)`.
	func sendText(_ s: String) {
		guard !s.isEmpty else { return }
		s.withCString { ptr in
			ghostty_surface_text(raw, ptr, UInt(strlen(ptr)))
		}
	}

	/// Marked / preedit text rendered inline at the cursor. Pass an empty
	/// string to clear (e.g. on `unmarkText` or after a successful commit).
	func setPreedit(_ s: String) {
		if s.isEmpty {
			ghostty_surface_preedit(raw, nil, 0)
		} else {
			s.withCString { ptr in
				ghostty_surface_preedit(raw, ptr, UInt(strlen(ptr)))
			}
		}
	}

	/// Cursor anchor in surface-local (view) coordinates for the IME
	/// candidate panel. The host view converts this to screen coordinates
	/// for `NSTextInputClient.firstRect(forCharacterRange:actualRange:)`.
	func imePoint() -> NSRect {
		var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
		ghostty_surface_ime_point(raw, &x, &y, &w, &h)
		return NSRect(x: x, y: y, width: w, height: h)
	}
}
