import AppKit
import GhosttyKit

/// Pure mapping helpers between AppKit input events and libghostty C enums.
///
/// These intentionally have no `GhosttySurface` dependency so they can be unit
/// tested without a `@MainActor` context or a live surface handle.

/// Convert AppKit `NSEvent.ModifierFlags` into libghostty's `ghostty_input_mods_e`
/// bitmask. Unmapped bits (e.g. `.numericPad`, `.function`) are intentionally
/// dropped — libghostty has no equivalent.
public func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
	var raw: UInt32 = 0
	if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
	if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
	if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
	if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
	if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
	return ghostty_input_mods_e(raw)
}

/// Convert an AppKit `NSEvent.buttonNumber` into libghostty's mouse button
/// enum. Out-of-range / unmapped values clamp to `GHOSTTY_MOUSE_UNKNOWN` so
/// libghostty can decide how to ignore them.
public func ghosttyMouseButton(buttonNumber: Int) -> ghostty_input_mouse_button_e {
	switch buttonNumber {
	case 0: return GHOSTTY_MOUSE_LEFT
	case 1: return GHOSTTY_MOUSE_RIGHT
	case 2: return GHOSTTY_MOUSE_MIDDLE
	default: return GHOSTTY_MOUSE_UNKNOWN
	}
}

/// Pack a `ghostty_input_scroll_mods_t` from AppKit scroll-wheel state.
///
/// libghostty packs these as bit flags (see `src/input/mouse.zig` and the
/// header comment near `ghostty_input_scroll_mods_t`):
///   - bit 0 .......... precise scrolling (trackpad / Magic Mouse)
///   - bits 1..3 ...... momentum phase (3-bit value, mapped from AppKit's
///                      `NSEvent.momentumPhase`)
///
/// Keep this layout in sync if libghostty is upgraded.
public func scrollMods(precise: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
	var bits: Int32 = 0
	if precise { bits |= 0x1 }
	// `NSEvent.Phase` is an `NS_OPTIONS` set; check membership in priority
	// order. Only one of these bits should be set at a time in practice.
	if momentum.contains(.began) {
		bits |= (1 << 1)
	} else if momentum.contains(.changed) {
		bits |= (2 << 1)
	} else if momentum.contains(.ended) {
		bits |= (3 << 1)
	} else if momentum.contains(.cancelled) {
		bits |= (4 << 1)
	}
	return ghostty_input_scroll_mods_t(bits)
}
