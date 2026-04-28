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
		theme = catppuccin-mocha
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

	#if canImport(AppKit)
		public static func revealInFinder(_ url: URL) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		}
	#endif
}
