import Foundation
import os
import SSHCommandBuilder

/// Real `SSHConfigSink` implementation. Writes per-session config files
/// under `~/Library/Caches/Caterm/ssh-configs/`, mode 0600. SessionStore
/// owns one instance and passes it to `SSHCommandBuilder.build(...)`.
public final class CatermSSHConfigSink: SSHConfigSink {
	private let log = Logger(subsystem: "com.caterm.session",
	                         category: "SSHConfigSink")
	private let directory: URL

	public init() {
		let caches = FileManager.default.urls(for: .cachesDirectory,
		                                      in: .userDomainMask)[0]
		self.directory = caches
			.appendingPathComponent("Caterm", isDirectory: true)
			.appendingPathComponent("ssh-configs", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true,
			attributes: [.posixPermissions: NSNumber(value: 0o700)])
	}

	public func write(_ config: String) throws -> URL {
		let url = directory.appendingPathComponent("\(UUID().uuidString).conf")
		try config.data(using: .utf8)!.write(to: url, options: .atomic)
		try FileManager.default.setAttributes(
			[.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
		return url
	}

	public func cleanup(_ url: URL) {
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			log.error("ssh-config cleanup failed: \(error.localizedDescription)")
		}
	}
}
