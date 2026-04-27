import Foundation
import GhosttyKit

/// Owns a `ghostty_config_t` handle. Loads the user's default config files and
/// finalizes them. The handle is freed in `deinit`.
///
/// Phase 1 wraps libghostty's defaults verbatim — no programmatic overrides.
/// (Font / theme / palette config UI lands in later tasks.)
@MainActor
public final class GhosttyConfig {
	public let raw: ghostty_config_t

	public init() throws {
		guard let cfg = ghostty_config_new() else {
			throw GhosttyError.configCreateFailed
		}
		ghostty_config_load_default_files(cfg)
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
