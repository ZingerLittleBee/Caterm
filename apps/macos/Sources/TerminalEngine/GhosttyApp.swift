import ConfigStore
import Foundation
import GhosttyKit

/// Process-wide libghostty app handle. There is exactly one of these per
/// process — libghostty's runtime is global. Surfaces are created against
/// `GhosttyApp.shared`.
///
/// Lifecycle:
///   1. First call to `GhosttyApp.shared` runs `ghostty_init` + builds a
///      `ghostty_runtime_config_s` whose callbacks dispatch to per-surface
///      Swift wrappers (see `GhosttySurface`).
///   2. The app handle and the underlying config are freed when the singleton
///      is torn down — in practice the process exits first, so this is best
///      effort.
@MainActor
public final class GhosttyApp {
	public static let shared: GhosttyApp = {
		do {
			return try GhosttyApp()
		} catch {
			fatalError("GhosttyApp init failed: \(error)")
		}
	}()

	public let raw: ghostty_app_t
	public let config: GhosttyConfig

	private init() throws {
		// `ghostty_init` is required before any other ghostty C call. It also
		// reads argv to honor any libghostty-recognized CLI flags.
		if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
			throw GhosttyError.initFailed
		}

		let catermConfigPath = ConfigStore.defaultPath.path
		let config = try GhosttyConfig(catermConfigPath: catermConfigPath)

		// Runtime config: a struct of C function pointers libghostty calls
		// back into when something happens (action requested, clipboard,
		// surface close, etc.). Pointers must be capture-less — Swift bridges
		// them to plain @convention(c) functions.
		var runtime = ghostty_runtime_config_s(
			userdata: nil,
			supports_selection_clipboard: false,
			wakeup_cb: GhosttyApp.wakeupCallback,
			action_cb: GhosttyApp.actionCallback,
			read_clipboard_cb: GhosttyApp.readClipboardCallback,
			confirm_read_clipboard_cb: GhosttyApp.confirmReadClipboardCallback,
			write_clipboard_cb: GhosttyApp.writeClipboardCallback,
			close_surface_cb: GhosttyApp.closeSurfaceCallback
		)

		guard let appHandle = ghostty_app_new(&runtime, config.raw) else {
			throw GhosttyError.appCreateFailed
		}

		self.raw = appHandle
		self.config = config
	}

	deinit {
		ghostty_app_free(raw)
	}

	// MARK: - C callback trampolines
	//
	// These are `@convention(c)` so they cannot capture Swift state directly.
	// Per-surface dispatch goes through `GhosttySurface.registry`, which maps
	// a surface pointer back to the Swift wrapper.

	private static let wakeupCallback: ghostty_runtime_wakeup_cb = { _ in
		// Tick is currently driven by libghostty internally; nothing to do.
	}

	private static let actionCallback: ghostty_runtime_action_cb = { _, target, action in
		// We rely on libghostty calling us back on the main thread (see v1.5
		// spec §6 / 6-OQ-1). All `MainActor.assumeIsolated` blocks below are
		// assertions, not hops; if this assertion ever fires, the threading
		// model needs revisiting before any of those blocks are safe.
		assert(Thread.isMainThread, "actionCallback fired off-main; revisit threading model in §6")
		// Dispatch to the surface wrapper, if any. Most actions are no-ops at
		// Phase 1 (we don't yet implement tabs / splits / new-window). The one
		// case we care about is GHOSTTY_ACTION_SHOW_CHILD_EXITED so SessionStore
		// (Task 1.4) can react to the PTY child exiting.
		guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
		let surfaceHandle = target.target.surface
		guard let wrapper = MainActor.assumeIsolated({
			GhosttySurface.lookup(surfaceHandle)
		}) else {
			return false
		}

		switch action.tag {
		case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
			let info = action.action.child_exited
			MainActor.assumeIsolated {
				wrapper.handleChildExited(exitCode: info.exit_code)
			}
			return true

		case GHOSTTY_ACTION_MOUSE_SHAPE:
			let shape = action.action.mouse_shape
			MainActor.assumeIsolated {
				wrapper.handleMouseShape(shape)
			}
			return true

		case GHOSTTY_ACTION_MOUSE_VISIBILITY:
			let visibility = action.action.mouse_visibility
			MainActor.assumeIsolated {
				wrapper.handleMouseVisibility(visibility)
			}
			return true

		case GHOSTTY_ACTION_CELL_SIZE:
			let size = action.action.cell_size
			MainActor.assumeIsolated {
				wrapper.updateCellSize(width: Double(size.width), height: Double(size.height))
			}
			return true

		default:
			return false
		}
	}

	private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = { _, _, _ in
		assert(Thread.isMainThread, "read_clipboard_cb fired off-main; revisit 6-OQ-2 fallback")
		return false
	}

	private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, kind in
		NSLog("[v1.5 spike] confirm_read_clipboard_cb fired kind=\(kind.rawValue) thread=\(Thread.isMainThread ? "main" : "bg")")
	}

	private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, _, _, _, _ in
		NSLog("[v1.5 spike] write_clipboard_cb fired thread=\(Thread.isMainThread ? "main" : "bg")")
	}

	private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in
	}
}
