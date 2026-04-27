import AppKit
import GhosttyKit

/// `NSView` host for a `GhosttySurface`. Owns the surface, forwards key events
/// into it, and propagates resize / scale changes back to libghostty.
///
/// libghostty paints into this view's `CAMetalLayer` (created on demand via
/// `wantsLayer`). We don't draw anything ourselves.
@MainActor
public final class GhosttySurfaceNSView: NSView {
	public private(set) var surface: GhosttySurface?

	private let pendingCommand: String?
	private let pendingEnv: [(String, String)]
	private var didCreateSurface = false

	public init(command: String?, env: [(String, String)] = []) {
		self.pendingCommand = command
		self.pendingEnv = env
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	public override var acceptsFirstResponder: Bool { true }
	public override var canBecomeKeyView: Bool { true }
	public override var isFlipped: Bool { true }
	public override var wantsUpdateLayer: Bool { true }

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard !didCreateSurface, window != nil else { return }
		do {
			let surface = try GhosttySurface(
				hostView: self,
				command: pendingCommand,
				env: pendingEnv
			)
			self.surface = surface
			didCreateSurface = true
			window?.makeFirstResponder(self)
			propagateSize()
			surface.setFocus(true)
		} catch {
			// Surfacing this through the UI is Task 1.4's job; for the smoke
			// path we just log and let the window stay blank.
			NSLog("[TerminalEngine] surface creation failed: \(error)")
		}
	}

	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		guard didCreateSurface else { return }
		propagateSize()
	}

	public override func becomeFirstResponder() -> Bool {
		surface?.setFocus(true)
		return super.becomeFirstResponder()
	}

	public override func resignFirstResponder() -> Bool {
		surface?.setFocus(false)
		return super.resignFirstResponder()
	}

	public override func keyDown(with event: NSEvent) {
		guard let surface else {
			super.keyDown(with: event)
			return
		}
		surface.sendKey(event)
	}

	private func propagateSize() {
		guard let surface else { return }
		let scaled = convertToBacking(bounds.size)
		let width = UInt32(max(1, scaled.width))
		let height = UInt32(max(1, scaled.height))
		surface.setSize(width: width, height: height)
	}
}
