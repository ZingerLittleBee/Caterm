import Foundation

#if canImport(AppKit)
	import AppKit
#endif

public enum ConfigStore {
	public static let defaultConfig = """
		# Caterm-managed Ghostty config — edit freely, restart Caterm to apply.
		# Full reference: https://ghostty.org/docs/config

		font-family = SF Mono
		font-size = 13
		theme = Catppuccin Mocha
		cursor-style = block
		macos-titlebar-style = tabs
		"""

	public static func ensureExists(at url: URL) throws {
		if FileManager.default.fileExists(atPath: url.path) { return }
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try defaultConfig.write(to: url, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o644],
			ofItemAtPath: url.path)
	}

	public static var defaultPath: URL {
		FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm/config")
	}

	public static var managedConfigPath: URL {
		FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm/caterm-managed.config")
	}

	/// Writes the Caterm-managed config snapshot atomically. Idempotent: if the
	/// content matches what's already on disk, no write happens (avoids fsevents churn).
	@MainActor
	public static func writeManagedConfig() throws {
		let path = managedConfigPath
		try FileManager.default.createDirectory(
			at: path.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		let desired = managedConfigContent

		if let existing = try? String(contentsOf: path, encoding: .utf8), existing == desired {
			return
		}
		try desired.write(to: path, atomically: true, encoding: .utf8)
	}

	private static let managedConfigContent = """
		# Caterm-managed; do not edit. Override in your user config at:
		#   ~/Library/Application Support/Caterm/config
		keybind = super+up=scroll_page_lines:-1
		keybind = super+down=scroll_page_lines:1
		keybind = super+page_up=scroll_page_fractional:-1
		keybind = super+page_down=scroll_page_fractional:1
		keybind = super+home=scroll_to_top
		keybind = super+end=scroll_to_bottom
		keybind = super+k=clear_screen
		"""

	#if canImport(AppKit)
		public static func revealInFinder(_ url: URL) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		}
	#endif
}
