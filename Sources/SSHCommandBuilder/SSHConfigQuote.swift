import Foundation

public enum SSHConfigQuoteError: Error, Equatable {
	/// Value contains a C0 control byte (0x00–0x1F) other than tab.
	/// ssh_config is byte-oriented and has no escape syntax for these;
	/// rejection prevents directive injection (newline/carriage return)
	/// and smuggling of invisible bytes (form-feed, vertical-tab, etc.).
	case controlCharacter
}

/// Encodes a value for safe inclusion as the right-hand side of an
/// ssh_config option line. ssh_config quoting is **not** shell quoting;
/// see the OpenSSH `ssh_config(5)` man page for the rules.
public enum SSHConfigQuote {
	public static func encode(_ value: String) throws -> String {
		// Reject control characters that would break the line-oriented
		// parser or could be smuggled in via UI fields.
		for scalar in value.unicodeScalars {
			// Reject all C0 control bytes (0x00–0x1F) except tab.
			// ssh_config has no escape syntax for them; embedding any
			// would either inject a directive (\n, \r) or smuggle an
			// invisible byte through the parser into DNS / libc.
			if scalar.value < 0x20 && scalar != "\t" {
				throw SSHConfigQuoteError.controlCharacter
			}
		}
		// If the value needs no quoting (plain word), emit it verbatim.
		let needsQuoting = value.isEmpty
			|| value.contains(" ") || value.contains("\t")
			|| value.contains("\"") || value.contains("\\")
		if !needsQuoting {
			return value
		}
		// Wrap in double quotes; escape backslash and double-quote.
		var escaped = ""
		for ch in value {
			if ch == "\\" {
				escaped.append("\\\\")
			} else if ch == "\"" {
				escaped.append("\\\"")
			} else {
				escaped.append(ch)
			}
		}
		return "\"\(escaped)\""
	}
}
