import Foundation
import GhosttyKit

public struct ConfigDiagnostic: Equatable {
	public let message: String

	public init(message: String) {
		self.message = message
	}

	public static func parse(_ raw: ghostty_diagnostic_s) -> ConfigDiagnostic {
		let msg = raw.message.flatMap { String(cString: $0) } ?? ""
		return ConfigDiagnostic(message: msg)
	}

	public static func collect(
		rawCount: UInt32,
		fetch: (UInt32) -> String?
	) -> [ConfigDiagnostic] {
		var out: [ConfigDiagnostic] = []
		for i in 0..<rawCount {
			if let m = fetch(i) {
				out.append(ConfigDiagnostic(message: m))
			}
		}
		return out
	}

	public static func collect(from cfg: ghostty_config_t) -> [ConfigDiagnostic] {
		let count = ghostty_config_diagnostics_count(cfg)
		var out: [ConfigDiagnostic] = []
		for i in 0..<count {
			let raw = ghostty_config_get_diagnostic(cfg, i)
			out.append(parse(raw))
		}
		return out
	}
}
