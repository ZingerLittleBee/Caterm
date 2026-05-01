import ConfigStore
import Foundation
import GhosttyKit

/// Owns a `ghostty_config_t` handle. Loads the user's default config files and
/// finalizes them. The handle is freed in `deinit`.
///
/// Load order: libghostty defaults → Caterm-managed snapshot → user config.
/// libghostty applies later loads on top of earlier ones, so the user's
/// `~/Library/Application Support/Caterm/config` always wins over the
/// Caterm-managed keybinds.
@MainActor
public final class GhosttyConfig {
	public let raw: ghostty_config_t

	public init(catermConfigPath: String? = nil) throws {
		guard let cfg = ghostty_config_new() else {
			throw GhosttyError.configCreateFailed
		}
		ghostty_config_load_default_files(cfg)

		// Caterm-managed snapshot — loaded BEFORE user file so user keybinds win.
		do {
			try ConfigStore.writeManagedConfig()
			ghostty_config_load_file(cfg, ConfigStore.managedConfigPath.path)
		} catch {
			NSLog("[GhosttyConfig] managed config write failed: \(error)")
		}

		if let path = catermConfigPath,
			FileManager.default.fileExists(atPath: path)
		{
			ghostty_config_load_file(cfg, path)
		}
		ghostty_config_finalize(cfg)
		self.raw = cfg
	}

	deinit {
		ghostty_config_free(raw)
	}
}

public enum GhosttyError: Error, CustomStringConvertible {
	case initFailed
	case configCreateFailed
	case appCreateFailed
	case surfaceCreateFailed

	public var description: String {
		switch self {
		case .initFailed: return "ghostty_init failed"
		case .configCreateFailed: return "ghostty_config_new returned nil"
		case .appCreateFailed: return "ghostty_app_new returned nil"
		case .surfaceCreateFailed: return "ghostty_surface_new returned nil"
		}
	}
}

@MainActor
public struct GhosttyConfigBuilder {
	public let loadDefaults: () -> Void
	public let loadFile: (String) -> Void
	public let finalize: () -> Void
	public let diagnosticsCount: () -> UInt32
	public let getDiagnostic: (UInt32) -> String

	public init(
		loadDefaults: @escaping () -> Void,
		loadFile: @escaping (String) -> Void,
		finalize: @escaping () -> Void,
		diagnosticsCount: @escaping () -> UInt32,
		getDiagnostic: @escaping (UInt32) -> String
	) {
		self.loadDefaults = loadDefaults
		self.loadFile = loadFile
		self.finalize = finalize
		self.diagnosticsCount = diagnosticsCount
		self.getDiagnostic = getDiagnostic
	}

	public struct Built {
		public let diagnostics: [ConfigDiagnostic]
	}

	public func build(managedPath: String, userPath: String?, perHostPath: String?) -> Built {
		loadDefaults()
		loadFile(managedPath)
		if let userPath { loadFile(userPath) }
		if let perHostPath { loadFile(perHostPath) }
		finalize()
		let diagnostics = ConfigDiagnostic.collect(rawCount: diagnosticsCount()) { i in
			getDiagnostic(i)
		}
		return Built(diagnostics: diagnostics)
	}
}
