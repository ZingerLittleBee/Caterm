import Foundation

public enum SSHConfigQuoteError: Error, Equatable {
	/// Value contains a newline (\n), carriage return (\r), or NUL.
	/// ssh_config is line-oriented; embedded line terminators would
	/// inject new directives. We reject rather than escape.
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
			if scalar == "\n" || scalar == "\r" || scalar == "\u{0}" {
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
