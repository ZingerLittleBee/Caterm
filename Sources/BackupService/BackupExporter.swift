import BackupArchive
import Foundation
import KeychainStore
import ManagedKeyStore
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder

public enum BackupExportError: Error {
	/// A Keychain read failed for a reason other than "item not found"
	/// (e.g. keychain locked). The export aborts rather than silently
	/// producing an archive with missing secrets.
	case keychainUnavailable(hostName: String, underlying: String)
}

/// Gathers user configuration from the live stores into a `BackupPayload`.
/// Read-only — exporting never mutates any store. Sync bookkeeping and
/// runtime state (tabs, transfers, change tokens) are deliberately not
/// collected (see BackupPayload).
@MainActor
public enum BackupExporter {

	public static func makePayload(
		includeSecrets: Bool,
		appVersion: String? = nil,
		sessionStore: SessionStore,
		managedKeys: ManagedKeyStore,
		snippets: [Snippet],
		settings: CatermSettings?,
		bookmarks: (UUID) -> [RemoteBookmark],
		now: Date = Date()
	) throws -> BackupPayload {
		let hosts = try sessionStore.hosts.map { host in
			try backupHost(host, includeSecrets: includeSecrets,
			               sessionStore: sessionStore, managedKeys: managedKeys)
		}

		let backupSnippets = snippets.map { s in
			BackupSnippet(id: s.id, name: s.name, content: s.content,
			              placeholders: s.placeholders,
			              createdAt: s.createdAt, updatedAt: s.updatedAt)
		}

		let backupSettings = settings.map { s in
			BackupSettings(
				revision: s.revision,
				global: s.global,
				hostOverrides: Dictionary(uniqueKeysWithValues:
					s.hostOverrides.map { ($0.key.rawValue, $0.value) })
			)
		}

		let backupBookmarks = sessionStore.hosts.flatMap { host in
			bookmarks(host.id).map { b in
				BackupBookmark(id: b.id, hostId: host.id, label: b.label,
				               path: b.path, createdAt: b.createdAt)
			}
		}

		return BackupPayload(
			exportedAt: now,
			appVersion: appVersion,
			hosts: hosts,
			snippets: backupSnippets,
			settings: backupSettings,
			bookmarks: backupBookmarks,
			knownHosts: knownHostsLines(path: sessionStore.knownHostsCaterm)
		)
	}

	// MARK: Hosts

	private static func backupHost(
		_ host: SSHHost,
		includeSecrets: Bool,
		sessionStore: SessionStore,
		managedKeys: ManagedKeyStore
	) throws -> BackupHost {
		let kind: String
		let hasPassphrase: Bool
		switch host.credential {
		case .password:
			kind = "password"; hasPassphrase = false
		case let .keyFile(_, hp):
			kind = "keyFile"; hasPassphrase = hp
		case .agent:
			kind = "agent"; hasPassphrase = false
		}

		var password: String?
		var passphrase: String?
		var privateKey: Data?
		if includeSecrets {
			password = try optionalSecret(
				account: "\(host.id.uuidString).password",
				keychain: sessionStore.keychain, hostName: host.name)
			passphrase = try optionalSecret(
				account: "\(host.id.uuidString).keyPassphrase",
				keychain: sessionStore.keychain, hostName: host.name)
			if case let .keyFile(path, _) = host.credential {
				// Managed copy first, on-disk path as a legacy fallback —
				// same resolution order the credential sync push uses.
				privateKey = (try? managedKeys.read(hostId: host.id))
					?? FileManager.default.contents(atPath: path)
			}
		}

		return BackupHost(
			id: host.id,
			serverId: host.serverId,
			name: host.name,
			hostname: host.hostname,
			port: host.port,
			username: host.username,
			credentialKind: kind,
			hasPassphrase: hasPassphrase,
			createdAt: host.createdAt,
			updatedAt: host.updatedAt,
			jumpHostId: resolvedJumpHostId(host, in: sessionStore.hosts),
			forwards: host.forwards.map { f in
				BackupPortForward(kind: f.kind.rawValue,
				                  bindAddress: f.bindAddress,
				                  bindPort: f.bindPort,
				                  remoteHost: f.remoteHost,
				                  remotePort: f.remotePort,
				                  required: f.required,
				                  label: f.label)
			},
			icon: host.icon,
			password: password,
			passphrase: passphrase,
			privateKey: privateKey
		)
	}

	/// The payload's jump reference is always the referenced host's payload
	/// `id`. Hosts that only carry a `jumpHostServerId` (pulled before the
	/// local backfill ran) resolve through it.
	private static func resolvedJumpHostId(_ host: SSHHost, in hosts: [SSHHost]) -> UUID? {
		if let id = host.jumpHostId { return id }
		guard let sid = host.jumpHostServerId else { return nil }
		return hosts.first { $0.serverId == sid }?.id
	}

	private static func optionalSecret(
		account: String, keychain: KeychainStore, hostName: String
	) throws -> String? {
		do {
			return try keychain.get(account: account)
		} catch KeychainError.notFound {
			return nil
		} catch {
			throw BackupExportError.keychainUnavailable(
				hostName: hostName, underlying: String(describing: error))
		}
	}

	private static func knownHostsLines(path: String) -> [String] {
		guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
		return text.split(separator: "\n", omittingEmptySubsequences: true)
			.map(String.init)
			.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
	}
}
