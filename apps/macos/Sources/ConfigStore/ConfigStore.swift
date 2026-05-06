import Foundation
import SettingsStore

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

	@MainActor
	public static func ensureManagedSnapshotExists(
		from settings: PartialSettings = CatermSettings.defaultsSeed,
		at path: URL = managedConfigPath
	) throws {
		if FileManager.default.fileExists(atPath: path.path) { return }
		try renderManagedSnapshot(from: settings, to: path)
	}

	#if canImport(AppKit)
		public static func revealInFinder(_ url: URL) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		}
	#endif
}

public extension ConfigStore {
	static var perHostPatchDirectory: URL {
		FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Caterm/per-host")
	}

	static func perHostPatchPath(for hostId: HostId) -> URL {
		perHostPatchDirectory.appendingPathComponent("\(hostId.rawValue).config")
	}

	@MainActor
	static func renderManagedSnapshot(
		from settings: PartialSettings,
		to path: URL = managedConfigPath
	) throws {
		try FileManager.default.createDirectory(
			at: path.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		let desired = SettingsRenderer.render(settings)
		if let existing = try? String(contentsOf: path, encoding: .utf8), existing == desired {
			return
		}
		try desired.write(to: path, atomically: true, encoding: .utf8)
	}
}

public extension ConfigStore {
	@MainActor
	static func writePerHostPatch(theme: String, to path: URL) throws {
		try FileManager.default.createDirectory(
			at: path.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try "theme = \(theme)\n".write(to: path, atomically: true, encoding: .utf8)
	}

	@MainActor
	static func regeneratePerHostPatches(
		from settings: CatermSettings,
		in directory: URL = perHostPatchDirectory
	) throws {
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true
		)
		let needed: [HostId: String] = settings.hostOverrides.compactMapValues { $0.theme }
			.reduce(into: [:]) { acc, kv in acc[kv.key] = kv.value }

		for (id, theme) in needed {
			try writePerHostPatch(theme: theme, to: directory.appendingPathComponent("\(id.rawValue).config"))
		}

		let neededFilenames = Set(needed.keys.map { "\($0.rawValue).config" })
		let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		for name in entries where !neededFilenames.contains(name) {
			try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
		}
	}
}
