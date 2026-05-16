import AppKit
import GhosttyKit

/// Thin wrappers around the libghostty surface mouse API. These don't translate
/// AppKit events themselves — that lives in `GhosttySurfaceNSView+Mouse.swift`.
/// Keeping the wrappers `@MainActor` matches `GhosttySurface`'s isolation: the
/// libghostty surface API is not thread-safe.
@MainActor
public extension GhosttySurface {
	/// Forward a mouse button press/release. Returns `true` if libghostty
	/// consumed the event (e.g., it was bound to a click action).
	@discardableResult
	func sendMouseButton(
		state: ghostty_input_mouse_state_e,
		button: ghostty_input_mouse_button_e,
		mods: NSEvent.ModifierFlags
	) -> Bool {
		ghostty_surface_mouse_button(raw, state, button, ghosttyMods(mods))
	}

	/// Forward a pointer position. Coordinates are in view-local points
	/// (origin top-left if the host view is `isFlipped`).
	func sendMousePos(x: Double, y: Double, mods: NSEvent.ModifierFlags) {
		ghostty_surface_mouse_pos(raw, x, y, ghosttyMods(mods))
	}

	/// Forward a scroll-wheel delta. The mods bitmask is built via
	/// `scrollMods(precise:momentum:)`.
	func sendMouseScroll(deltaX: Double, deltaY: Double, mods: ghostty_input_scroll_mods_t) {
		ghostty_surface_mouse_scroll(raw, deltaX, deltaY, mods)
	}

	/// Forward a Force Touch pressure update.
	func sendMousePressure(stage: UInt32, pressure: Double) {
		ghostty_surface_mouse_pressure(raw, stage, pressure)
	}

	/// `true` if libghostty currently has the mouse "captured" — i.e. a
	/// terminal app has enabled mouse-reporting (DECSET 1000/1002/1006) so
	/// AppKit-level selection should defer.
	var isMouseCaptured: Bool {
		ghostty_surface_mouse_captured(raw)
	}
}
