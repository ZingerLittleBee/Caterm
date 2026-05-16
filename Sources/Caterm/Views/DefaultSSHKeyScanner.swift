import Foundation

/// Discovers candidate SSH private keys in the user's `~/.ssh` directory.
///
/// Used to offer "keys you already have" in the auth picker so the user can
/// pick one explicitly. Discovery alone never uploads anything — see
/// `SyncPreferences.autoUploadDefaultKeysEnabled` for the opt-in that gates
/// auto-uploading a discovered key, and only after it has produced a
/// successful connection.
enum DefaultSSHKeyScanner {
	struct DiscoveredKey: Identifiable, Hashable {
		let path: String
		var id: String { path }
		var displayName: String { (path as NSString).lastPathComponent }
	}

	/// Filenames in `~/.ssh` that are definitely not private keys.
	private static let excludedNames: Set<String> = [
		"known_hosts", "known_hosts.old", "config", "authorized_keys",
		"environment", "agent.sock", ".DS_Store",
	]

	private static let excludedSuffixes = [
		".pub", ".crt", ".cer", ".csr", ".sock", "-cert.pub",
	]

	static var defaultDirectory: URL {
		URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
	}

	/// Returns discovered private keys, sorted with the conventional default
	/// key names first (ed25519 → rsa → ecdsa), then alphabetically.
	static func scan(directory: URL = defaultDirectory) -> [DiscoveredKey] {
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.isRegularFileKey],
			options: [.skipsHiddenFiles]
		) else { return [] }

		var keys: [DiscoveredKey] = []
		for url in entries {
			let name = url.lastPathComponent
			if excludedNames.contains(name) { continue }
			if excludedSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
			let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
				.isRegularFile ?? false
			guard isRegular else { continue }
			if looksLikePrivateKey(url) {
				keys.append(DiscoveredKey(path: url.path))
			}
		}

		let priority: (String) -> Int = { name in
			if name.contains("ed25519") { return 0 }
			if name.contains("rsa") { return 1 }
			if name.contains("ecdsa") { return 2 }
			return 3
		}
		return keys.sorted {
			let lp = priority($0.displayName), rp = priority($1.displayName)
			if lp != rp { return lp < rp }
			return $0.displayName < $1.displayName
		}
	}

	/// Cheap header sniff: read the first chunk and look for a PEM/OpenSSH
	/// private-key banner. Avoids slurping large unrelated files.
	private static func looksLikePrivateKey(_ url: URL) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		let head = (try? handle.read(upToCount: 120)) ?? Data()
		guard let text = String(data: head, encoding: .utf8) else { return false }
		return text.contains("PRIVATE KEY-----")
			|| text.contains("BEGIN OPENSSH PRIVATE KEY")
	}
}
