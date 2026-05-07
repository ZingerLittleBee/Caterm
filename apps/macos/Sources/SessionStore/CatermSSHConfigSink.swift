import Darwin
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
		// Errors are deferred to write(_:) via verifyDirectoryOrThrow().
		// withIntermediateDirectories: true only sets permissions on NEW
		// directories; pre-existing intermediates keep their original mode,
		// which is why we verify ownership and permissions before writing.
		try? FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true,
			attributes: [.posixPermissions: NSNumber(value: 0o700)])
	}

	// MARK: - SSHConfigSink

	public func write(_ config: String) throws -> URL {
		try verifyDirectoryOrThrow()
		let url = directory.appendingPathComponent("\(UUID().uuidString).conf")
		let path = url.path
		// Create the file at 0600 before writing any content so there is
		// never a window where credential-bearing data is world-readable.
		guard FileManager.default.createFile(
			atPath: path, contents: nil,
			attributes: [.posixPermissions: NSNumber(value: 0o600)]
		) else {
			throw CocoaError(.fileWriteUnknown)
		}
		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		// Data(config.utf8) is the non-failing UTF-8 form; avoids force-unwrap.
		try handle.write(contentsOf: Data(config.utf8))
		return url
	}

	public func cleanup(_ url: URL) {
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			log.error("ssh-config cleanup failed: \(error.localizedDescription)")
		}
	}

	// MARK: - Private

	/// Verifies that `directory` is a real directory (not a symlink) owned by
	/// the current uid with no group/other permission bits set (mode ≤ 0700).
	/// Throws before any credential-bearing file is written.
	private func verifyDirectoryOrThrow() throws {
		let path = directory.path
		let attrs = try FileManager.default.attributesOfItem(atPath: path)
		let type = attrs[.type] as? FileAttributeType
		guard type == .typeDirectory else {
			throw CocoaError(.fileWriteFileExists)
		}
		if let owner = attrs[.ownerAccountID] as? NSNumber {
			guard owner.uint32Value == getuid() else {
				throw CocoaError(.fileWriteNoPermission)
			}
		}
		if let perms = attrs[.posixPermissions] as? NSNumber {
			// Must be ≤ 0o700 (no group/other bits).
			guard perms.intValue & 0o077 == 0 else {
				throw CocoaError(.fileWriteNoPermission)
			}
		}
	}
}
