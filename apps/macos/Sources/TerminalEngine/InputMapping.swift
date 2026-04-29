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
///   - bits 1..3 ...... momentum phase as a 3-bit `ghostty_input_mouse_momentum_e`
///                      value:
///                        0 = NONE
///                        1 = BEGAN
///                        2 = STATIONARY
///                        3 = CHANGED
///                        4 = ENDED
///                        5 = CANCELLED
///                        6 = MAY_BEGIN
///
/// AppKit's `NSEvent.momentumPhase` is an `NS_OPTIONS` set, so we check each
/// flag in turn and emit the matching ghostty enum value. Keep this layout in
/// sync if libghostty is upgraded — the enum order is the contract.
public func scrollMods(precise: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
	var bits: Int32 = 0
	if precise { bits |= 0x1 }

	let phase: Int32
	if momentum.contains(.began) {
		phase = 1 // GHOSTTY_MOUSE_MOMENTUM_BEGAN
	} else if momentum.contains(.stationary) {
		phase = 2 // GHOSTTY_MOUSE_MOMENTUM_STATIONARY
	} else if momentum.contains(.changed) {
		phase = 3 // GHOSTTY_MOUSE_MOMENTUM_CHANGED
	} else if momentum.contains(.ended) {
		phase = 4 // GHOSTTY_MOUSE_MOMENTUM_ENDED
	} else if momentum.contains(.cancelled) {
		phase = 5 // GHOSTTY_MOUSE_MOMENTUM_CANCELLED
	} else if momentum.contains(.mayBegin) {
		phase = 6 // GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
	} else {
		phase = 0 // GHOSTTY_MOUSE_MOMENTUM_NONE
	}

	bits |= (phase & 0x7) << 1
	return ghostty_input_scroll_mods_t(bits)
}
