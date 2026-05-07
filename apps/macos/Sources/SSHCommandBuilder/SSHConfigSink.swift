import Foundation

public protocol SSHConfigSink: Sendable {
	/// Writes `config` to a file with mode 0600 and returns the URL.
	/// The caller passes the URL back to `cleanup(_:)` when done.
	func write(_ config: String) throws -> URL

	/// Removes the previously-written config file. No-op if it's
	/// already gone. Errors are swallowed (logged) — best-effort.
	func cleanup(_ url: URL)
}

/// Test fake. Captures the most recently written config in memory and
/// hands back a `tmpfs://N` URL. Never touches the filesystem.
public final class InMemorySSHConfigSink: SSHConfigSink, @unchecked Sendable {
	public private(set) var writes: [(URL, String)] = []
	public private(set) var cleanups: [URL] = []
	public init() {}
	public func write(_ config: String) throws -> URL {
		let url = URL(string: "tmpfs://\(writes.count)")!
		writes.append((url, config))
		return url
	}
	public func cleanup(_ url: URL) { cleanups.append(url) }
}
