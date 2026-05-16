import Foundation

public enum ShellQuote {
    /// Wrap an arbitrary string in POSIX-safe single quotes. Inside single
    /// quotes, every byte is literal except `'` itself, which terminates the
    /// quoted region. Replace embedded `'` with `'\''` (close, escape, reopen).
    public static func posix(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
