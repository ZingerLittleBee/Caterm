import AppKit
import GhosttyKit

/// AppKit → libghostty mouse-event translation. Lives in an extension so
/// `GhosttySurfaceNSView` proper stays focused on surface lifecycle.
///
/// Selection, mouse-reporting (DECSET 1000/1002/1006), and click-drag are
/// handled inside libghostty — we just forward raw button / position / scroll
/// events. Cursor-shape feedback comes back through
/// `GhosttySurface.onMouseShape` (wired up in `viewDidMoveToWindow`).
extension GhosttySurfaceNSView {
	public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		let area = NSTrackingArea(
			rect: bounds,
			options: [
				.activeInKeyWindow,
				.mouseMoved,
				.mouseEnteredAndExited,
				.inVisibleRect,
				.cursorUpdate,
			],
			owner: self,
			userInfo: nil
		)
		addTrackingArea(area)
	}

	// MARK: - Button events

	public override func mouseDown(with event: NSEvent) {
		forwardButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
	}

	public override func mouseUp(with event: NSEvent) {
		forwardButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
	}

	public override func rightMouseDown(with event: NSEvent) {
		forwardButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT)
	}

	public override func rightMouseUp(with event: NSEvent) {
		forwardButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT)
	}

	public override func otherMouseDown(with event: NSEvent) {
		forwardButton(event, GHOSTTY_MOUSE_PRESS, ghosttyMouseButton(buttonNumber: event.buttonNumber))
	}

	public override func otherMouseUp(with event: NSEvent) {
		forwardButton(event, GHOSTTY_MOUSE_RELEASE, ghosttyMouseButton(buttonNumber: event.buttonNumber))
	}

	// MARK: - Motion / drag

	public override func mouseDragged(with event: NSEvent) { forwardPos(event) }
	public override func rightMouseDragged(with event: NSEvent) { forwardPos(event) }
	public override func otherMouseDragged(with event: NSEvent) { forwardPos(event) }
	public override func mouseMoved(with event: NSEvent) { forwardPos(event) }

	// MARK: - Scroll

	public override func scrollWheel(with event: NSEvent) {
		guard let surface else { return }
		var dx = event.scrollingDeltaX
		var dy = event.scrollingDeltaY
		// AppKit reports trackpad/Magic-Mouse deltas in pixels (precise) and
		// classic-wheel deltas in lines. libghostty wants pixels in both
		// modes, so multiply imprecise deltas by the cell size so one tick
		// scrolls one row / column.
		if !event.hasPreciseScrollingDeltas {
			dx *= surface.cellSize.width
			dy *= surface.cellSize.height
		}
		let mods = scrollMods(precise: event.hasPreciseScrollingDeltas, momentum: event.momentumPhase)
		surface.sendMouseScroll(deltaX: Double(dx), deltaY: Double(dy), mods: mods)
	}

	// MARK: - Private helpers

	private func forwardButton(
		_ event: NSEvent,
		_ state: ghostty_input_mouse_state_e,
		_ button: ghostty_input_mouse_button_e
	) {
		// Make sure libghostty has the latest pointer position before we
		// fire the click — otherwise selection / mouse-reporting may use a
		// stale coordinate.
		forwardPos(event)
		surface?.sendMouseButton(state: state, button: button, mods: event.modifierFlags)
	}

	private func forwardPos(_ event: NSEvent) {
		guard let surface else { return }
		let p = convert(event.locationInWindow, from: nil)
		surface.sendMousePos(x: Double(p.x), y: Double(p.y), mods: event.modifierFlags)
	}
}
