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
///
/// `@unchecked Sendable` is honest here: every access to the mutable
/// `writes`/`cleanups` storage is serialized by `lock`, so the type is
/// safe to share across the `SSHConfigSink: Sendable` boundary even when
/// tests drive it from multiple tasks.
public final class InMemorySSHConfigSink: SSHConfigSink, @unchecked Sendable {
	private let lock = NSLock()
	private var _writes: [(URL, String)] = []
	private var _cleanups: [URL] = []
	public var writes: [(URL, String)] { lock.withLock { _writes } }
	public var cleanups: [URL] { lock.withLock { _cleanups } }
	public init() {}
	public func write(_ config: String) throws -> URL {
		lock.withLock {
			let url = URL(string: "tmpfs:///\(_writes.count)")!
			_writes.append((url, config))
			return url
		}
	}
	public func cleanup(_ url: URL) { lock.withLock { _cleanups.append(url) } }
}
