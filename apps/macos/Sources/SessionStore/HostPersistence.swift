import Foundation
import SSHCommandBuilder

/// File-based JSON persistence for the user's saved SSH hosts.
///
/// Hosts live in `~/Library/Application Support/Caterm/hosts.json` (path passed
/// in by SessionStore). Secrets are NEVER stored here — they go to Keychain via
/// `SessionStore.setHostSecret`. The JSON file is chmod 0600 to keep nosy
/// processes out of the host metadata.
public enum HostPersistence {
	public static func load(from url: URL) throws -> [SSHHost] {
		guard FileManager.default.fileExists(atPath: url.path) else { return [] }
		let data = try Data(contentsOf: url)
		return try JSONDecoder().decode([SSHHost].self, from: data)
	}

	public static func save(_ hosts: [SSHHost], to url: URL) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let data = try encoder.encode(hosts)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try data.write(to: url)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: url.path
		)
	}
}
