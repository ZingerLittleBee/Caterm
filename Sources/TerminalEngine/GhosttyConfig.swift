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
		let cfg = try GhosttyConfigLoader.make(
			catermConfigPath: catermConfigPath,
			perHostConfigPath: nil
		)
		self.raw = cfg
	}

	public static func diagnostics(
		catermConfigPath: String? = ConfigStore.defaultPath.path,
		perHostConfigPath: String? = nil
	) -> [ConfigDiagnostic] {
		GhosttyConfigLoader.diagnostics(
			catermConfigPath: catermConfigPath,
			perHostConfigPath: perHostConfigPath
		)
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
	case stringAllocationFailed

	public var description: String {
		switch self {
		case .initFailed: return "ghostty_init failed"
		case .configCreateFailed: return "ghostty_config_new returned nil"
		case .appCreateFailed: return "ghostty_app_new returned nil"
		case .surfaceCreateFailed: return "ghostty_surface_new returned nil"
		case .stringAllocationFailed: return "failed to allocate surface config string"
		}
	}
}

@MainActor
enum GhosttyConfigLoader {
	static func make(
		catermConfigPath: String?,
		perHostConfigPath: String?
	) throws -> ghostty_config_t {
		guard let cfg = ghostty_config_new() else {
			throw GhosttyError.configCreateFailed
		}
		loadFiles(
			into: cfg,
			catermConfigPath: catermConfigPath,
			perHostConfigPath: perHostConfigPath
		)
		return cfg
	}

	static func diagnostics(
		catermConfigPath: String? = ConfigStore.defaultPath.path,
		perHostConfigPath: String? = nil
	) -> [ConfigDiagnostic] {
		do {
			let cfg = try make(
				catermConfigPath: catermConfigPath,
				perHostConfigPath: perHostConfigPath
			)
			defer { ghostty_config_free(cfg) }
			return ConfigDiagnostic.collect(from: cfg)
		} catch {
			return [ConfigDiagnostic(message: "Ghostty config reload failed: \(error)")]
		}
	}

	private static func loadFiles(
		into cfg: ghostty_config_t,
		catermConfigPath: String?,
		perHostConfigPath: String?
	) {
		ghostty_config_load_default_files(cfg)
		do {
			try ConfigStore.ensureManagedSnapshotExists()
		} catch {
			NSLog("[GhosttyConfig] managed config seed failed: \(error)")
		}
		loadFileIfPresent(ConfigStore.managedConfigPath.path, into: cfg)
		if let catermConfigPath {
			loadFileIfPresent(catermConfigPath, into: cfg)
		}
		if let perHostConfigPath {
			loadFileIfPresent(perHostConfigPath, into: cfg)
		}
		ghostty_config_finalize(cfg)
	}

	private static func loadFileIfPresent(_ path: String, into cfg: ghostty_config_t) {
		if FileManager.default.fileExists(atPath: path) {
			ghostty_config_load_file(cfg, path)
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
