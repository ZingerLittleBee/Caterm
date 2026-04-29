import AppKit
import Foundation
import GhosttyKit

/// Wraps a single libghostty surface. Each surface owns its own PTY (started
/// by libghostty itself, not by us) and renders into the host `NSView` via
/// Metal.
///
/// Ownership / threading:
///   - The libghostty surface API is **not** thread-safe; all methods on this
///     class are `@MainActor`-isolated.
///   - C strings passed via `ghostty_surface_config_s` (command, env vars)
///     must outlive the call to `ghostty_surface_new`. We `strdup` them and
///     free in `deinit` to be safe — libghostty may copy internally, but we
///     don't rely on that.
///   - A static registry (`registry`) maps the underlying `ghostty_surface_t`
///     pointer to the Swift wrapper so the global C action callback can
///     dispatch back to us.
@MainActor
public final class GhosttySurface {
	public let raw: ghostty_surface_t
	public weak var hostView: NSView?

	/// Fired when libghostty reports the PTY child process has exited
	/// (`GHOSTTY_ACTION_SHOW_CHILD_EXITED`). Wired in Task 1.4 by SessionStore;
	/// Task 1.1 just declares the property and the surface won't fire it for
	/// `$SHELL` (which doesn't exit on its own).
	public var onChildExit: ((Int32) -> Void)?

	private(set) public var processExited: Bool = false

	/// Pixel dimensions of one terminal cell, updated by
	/// `GHOSTTY_ACTION_CELL_SIZE`. The default is a sane fallback used for
	/// imprecise wheel-scroll deltas before libghostty reports a real value.
	public private(set) var cellSize: NSSize = .init(width: 8, height: 16)

	/// Heap-allocated C strings whose pointers were stuffed into the surface
	/// config. Held here so we can free them when the surface dies.
	private var ownedCStrings: [UnsafeMutablePointer<CChar>] = []
	/// Backing storage for `ghostty_env_var_s` array, if any.
	private var envStorage: UnsafeMutablePointer<ghostty_env_var_s>?
	private var envStorageCount: Int = 0

	// MARK: - Registry
	//
	// libghostty hands us back `ghostty_target_s` containing a raw surface
	// pointer (`ghostty_surface_t`). To dispatch back to the Swift wrapper
	// from the static C action callback, we keep a process-wide table.

	private static var registry: [OpaquePointer: GhosttySurface] = [:]

	static func lookup(_ raw: ghostty_surface_t?) -> GhosttySurface? {
		guard let raw else { return nil }
		return registry[OpaquePointer(raw)]
	}

	public init(
		hostView: NSView,
		command: String? = nil,
		env: [(String, String)] = []
	) throws {
		self.hostView = hostView

		var surfaceConfig = ghostty_surface_config_new()
		surfaceConfig.userdata = Unmanaged.passUnretained(hostView).toOpaque()
		surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
		surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
			nsview: Unmanaged.passUnretained(hostView).toOpaque()
		))
		let scale = hostView.window?.backingScaleFactor
			?? NSScreen.main?.backingScaleFactor
			?? 2.0
		surfaceConfig.scale_factor = Double(scale)
		surfaceConfig.font_size = 0 // inherit from config
		surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

		// Keep references to any C strings we hand to libghostty so they
		// outlive the call. libghostty may or may not copy; we assume it
		// does not.
		var ownedStrings: [UnsafeMutablePointer<CChar>] = []

		if let command {
			let dup = strdup(command)!
			ownedStrings.append(dup)
			surfaceConfig.command = UnsafePointer(dup)
		}
		// When `command == nil`, we deliberately leave `surfaceConfig.command`
		// as the zero-init value (NULL) so libghostty falls back to `$SHELL`.

		// Optional env var array. Allocated as a contiguous C array; freed in
		// `deinit` along with each key/value strdup.
		var envBuffer: UnsafeMutablePointer<ghostty_env_var_s>?
		if !env.isEmpty {
			let count = env.count
			let buf = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: count)
			for (idx, pair) in env.enumerated() {
				let keyDup = strdup(pair.0)!
				let valDup = strdup(pair.1)!
				ownedStrings.append(keyDup)
				ownedStrings.append(valDup)
				buf[idx] = ghostty_env_var_s(key: UnsafePointer(keyDup), value: UnsafePointer(valDup))
			}
			surfaceConfig.env_vars = buf
			surfaceConfig.env_var_count = count
			envBuffer = buf
		}

		guard let surfaceHandle = ghostty_surface_new(GhosttyApp.shared.raw, &surfaceConfig) else {
			// Free anything we allocated before throwing.
			for ptr in ownedStrings { free(ptr) }
			if let buf = envBuffer { buf.deallocate() }
			throw GhosttyError.surfaceCreateFailed
		}

		self.raw = surfaceHandle
		self.ownedCStrings = ownedStrings
		self.envStorage = envBuffer
		self.envStorageCount = env.count

		Self.registry[OpaquePointer(surfaceHandle)] = self
	}

	deinit {
		// `deinit` runs on whichever thread released the last strong ref; it
		// is not @MainActor isolated. Hop to the main actor to touch the
		// libghostty handle and the registry, both of which are main-only.
		// We capture the raw pointers (Sendable) by value so we don't need to
		// pass `self` across the boundary.
		let surfaceHandle = raw
		let strings = ownedCStrings
		let envBuf = envStorage
		MainActor.assumeIsolated {
			Self.registry.removeValue(forKey: OpaquePointer(surfaceHandle))
			ghostty_surface_free(surfaceHandle)
		}
		for ptr in strings { free(ptr) }
		if let buf = envBuf { buf.deallocate() }
	}

	// MARK: - Public API

	public func setSize(width: UInt32, height: UInt32) {
		ghostty_surface_set_size(raw, width, height)
	}

	public func setContentScale(_ scale: CGFloat) {
		ghostty_surface_set_content_scale(raw, scale, scale)
	}

	public func setFocus(_ focused: Bool) {
		ghostty_surface_set_focus(raw, focused)
	}

	/// Forwards an `NSEvent` keyDown/keyUp to libghostty. Mirrors the spike's
	/// mapping: keycode + modifier flags + raw text payload, plus the
	/// unshifted codepoint. libghostty handles binding lookup, IME, and PTY
	/// write internally.
	public func sendKey(_ event: NSEvent) {
		let chars = event.characters ?? ""
		let mods = ghosttyMods(event.modifierFlags)
		let action: ghostty_input_action_e = event.isARepeat
			? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

		// `text` is read by libghostty during the call, so a stack-scoped
		// pointer (via `withCString`) is sufficient here.
		_ = chars.withCString { textPtr -> Bool in
			var k = ghostty_input_key_s()
			k.action = action
			k.mods = mods
			k.consumed_mods = mods
			k.keycode = UInt32(event.keyCode)
			k.text = chars.isEmpty ? nil : textPtr
			k.unshifted_codepoint = chars.unicodeScalars.first.map { UInt32($0.value) } ?? 0
			k.composing = false
			return ghostty_surface_key(raw, k)
		}
	}

	// MARK: - Internal hooks (called by the global action callback)

	func handleChildExited(exitCode: UInt32) {
		processExited = true
		onChildExit?(Int32(bitPattern: exitCode))
	}

	func updateCellSize(width: Double, height: Double) {
		cellSize = NSSize(width: width, height: height)
	}

}
