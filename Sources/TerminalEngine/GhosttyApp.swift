import AppKit
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
	private static var instance: GhosttyApp?

	public static var shared: GhosttyApp {
		if let instance { return instance }
		do {
			let created = try GhosttyApp()
			instance = created
			return created
		} catch {
			fatalError("GhosttyApp init failed: \(error)")
		}
	}

	@discardableResult
	public static func updateSharedConfigIfInitialized(
		catermConfigPath: String? = ConfigStore.defaultPath.path
	) -> [ConfigDiagnostic] {
		guard let instance else { return [] }
		return instance.updateConfig(catermConfigPath: catermConfigPath)
	}

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

	@discardableResult
	public func updateConfig(
		catermConfigPath: String? = ConfigStore.defaultPath.path
	) -> [ConfigDiagnostic] {
		let cfg: ghostty_config_t
		do {
			cfg = try GhosttyConfigLoader.make(
				catermConfigPath: catermConfigPath,
				perHostConfigPath: nil
			)
		} catch {
			return [ConfigDiagnostic(message: "Ghostty app config reload failed: \(error)")]
		}
		let diagnostics = ConfigDiagnostic.collect(from: cfg)
		ghostty_app_update_config(raw, cfg)
		ghostty_config_free(cfg)
		return diagnostics
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

		case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD:
			// We don't consume these (no window-title / pwd UI yet) — return
			// false so libghostty's default handling is unchanged. We only
			// peek at them as a "the remote shell is interactive" heartbeat
			// to dismiss the connecting overlay the instant the session is
			// genuinely live instead of after a fixed grace timer.
			MainActor.assumeIsolated {
				wrapper.handleSessionLive()
			}
			return false

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

		case GHOSTTY_ACTION_MOUSE_OVER_LINK:
			// `info.url` is a `const char*` valid for the duration of this
			// callback only — snapshot into Swift before any hop. A NULL
			// pointer means hover ended (libghostty fires this when the
			// pointer leaves the link).
			let info = action.action.mouse_over_link
			let url: String? = info.url.map { String(cString: $0) }
			MainActor.assumeIsolated {
				wrapper.handleHoverURL(url)
			}
			return true

		case GHOSTTY_ACTION_OPEN_URL:
			// Sent on ⌘-click of a detected URL. `kind` tells us whether the
			// payload is plain text or HTML; the host view ignores it for now
			// and just hands the URL to NSWorkspace (after scheme whitelist).
			let info = action.action.open_url
			guard let cstr = info.url else { return false }
			let url = String(cString: cstr)
			let kind = info.kind
			MainActor.assumeIsolated {
				wrapper.handleOpenURL(url, kind: kind)
			}
			return true

		default:
			return false
		}
	}

	// libghostty calls `write_clipboard_cb` when a remote OSC 52 sequence
	// (or some other surface action) wants to push text onto the host
	// clipboard. We cherry-pick the first text/* MIME entry and copy it onto
	// `NSPasteboard.general`. The hop to main is conservative — `NSPasteboard`
	// is thread-safe for `setString` but UI state observers may not be.
	private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = {
		_, kind, contentsPtr, count, _ in
		guard kind == GHOSTTY_CLIPBOARD_STANDARD,
		      let contentsPtr else { return }

		var picked: String?
		for i in 0..<Int(count) {
			let entry = contentsPtr[i]
			guard let dataCStr = entry.data else { continue }
			let mime = entry.mime.map { String(cString: $0) } ?? ""
			if mime.isEmpty || mime.hasPrefix("text/") {
				picked = String(cString: dataCStr)
				break
			}
		}
		guard let str = picked else { return }

		DispatchQueue.main.async {
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(str, forType: .string)
		}
	}

	// libghostty calls `read_clipboard_cb` synchronously when the surface
	// needs the current clipboard contents (paste, OSC 52 read). We must
	// fulfill before returning, so this callback cannot defer to a later
	// runloop turn. The `pendingLocalPaste` token disambiguates a local
	// ⌘V/drag (allow) from a remote OSC 52 read (blanket deny per
	// spec §5.4 policy B / 5.4-OQ-1 resolved as deny).
	//
	// The `Thread.isMainThread` assert from the 2.0 spike stays as a
	// tripwire — if libghostty ever fires this off-main the design needs
	// the change-count-based pre-cache fallback (spec §6).
	private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = {
		userdata, _, state in
		assert(Thread.isMainThread, "read_clipboard_cb off-main — see 6-OQ-2 fallback")
		guard let userdata else { return false }
		return MainActor.assumeIsolated {
			let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
			guard let surface = view.surface else { return false }

			if surface.pendingLocalPaste {
				surface.pendingLocalPaste = false
				let text = surface.pendingPasteText
					?? NSPasteboard.general.string(forType: .string)
					?? ""
				surface.pendingPasteText = nil
				text.withCString { ptr in
					ghostty_surface_complete_clipboard_request(surface.raw, ptr, state, false)
				}
				return true
			}

			// Remote OSC 52 read — blanket deny per spec §5.4 policy B
			// (5.4-OQ-1 resolved as deny).
			ghostty_surface_complete_clipboard_request(surface.raw, nil, state, false)
			return false
		}
	}

	// libghostty calls `confirm_read_clipboard_cb` for PASTE-confirm and OSC
	// 52 write requests. Per spec §5.4 policy B (resolved via 5.4-OQ-1):
	//   - PASTE                   → auto-confirm (we already gated via pendingLocalPaste)
	//   - OSC_52_WRITE            → auto-confirm (writes are low-risk, just push to clipboard)
	//   - OSC_52_READ             → blanket deny (also denied earlier in
	//                               readClipboardCallback so this branch is
	//                               only a defense-in-depth no-op)
	//
	// The C string `dataCStr` is only valid for the synchronous duration of
	// this callback, so we snapshot it before any async hop.
	private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = {
		userdata, dataCStr, request, requestKind in
		guard let userdata else { return }
		let snapshot = dataCStr.map { String(cString: $0) } ?? ""

		DispatchQueue.main.async {
			let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
			guard let surface = view.surface else { return }

			switch requestKind {
			case GHOSTTY_CLIPBOARD_REQUEST_PASTE,
			     GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
				snapshot.withCString { ptr in
					ghostty_surface_complete_clipboard_request(surface.raw, ptr, request, true)
				}

			default:
				// OSC_52_READ and any future request kind: deny by default.
				ghostty_surface_complete_clipboard_request(surface.raw, nil, request, false)
			}
		}
	}

	private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in
	}
}
