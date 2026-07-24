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
		let temporaryURL = url.deletingLastPathComponent()
			.appendingPathComponent(
				".\(url.lastPathComponent).\(UUID().uuidString).tmp"
			)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		do {
			try data.write(to: temporaryURL)
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o600],
				ofItemAtPath: temporaryURL.path
			)
			if FileManager.default.fileExists(atPath: url.path) {
				_ = try FileManager.default.replaceItemAt(
					url,
					withItemAt: temporaryURL,
					backupItemName: nil,
					options: .usingNewMetadataOnly
				)
			} else {
				try FileManager.default.moveItem(at: temporaryURL, to: url)
			}
		} catch {
			try? FileManager.default.removeItem(at: temporaryURL)
			throw error
		}
	}
}
