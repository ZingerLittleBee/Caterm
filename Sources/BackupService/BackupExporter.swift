import BackupArchive
import Foundation
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder

public enum BackupExportError: Error {
	/// A credential-material read failed. The export aborts rather than
	/// silently producing an archive with missing secrets.
	case credentialMaterialUnavailable(hostName: String, underlying: String)
}

/// Gathers user configuration from the live stores into a `BackupPayload`.
/// Read-only — exporting never mutates any store. Sync bookkeeping and
/// runtime state (tabs, transfers, change tokens) are deliberately not
/// collected (see BackupPayload).
@MainActor
public enum BackupExporter {
	private struct HostSnapshotChanged: Error {}

	public static func makePayload(
		includeSecrets: Bool,
		appVersion: String? = nil,
		sessionStore: SessionStore,
		snippets: [Snippet],
		settings: CatermSettings?,
		bookmarks: (UUID) -> [RemoteBookmark],
		now: Date = Date()
	) async throws -> BackupPayload {
		while true {
			try Task.checkCancellation()
			let barrier = includeSecrets
				? try await sessionStore.credentialMaterialStore.beginReadBarrier()
				: nil
			let payload: BackupPayload
			do {
				try Task.checkCancellation()
				let hostSnapshot = sessionStore.hosts
				let bookmarkSnapshot = hostSnapshot.flatMap { host in
					bookmarks(host.id).map { bookmark in
						BackupBookmark(
							id: bookmark.id,
							hostId: host.id,
							label: bookmark.label,
							path: bookmark.path,
							createdAt: bookmark.createdAt
						)
					}
				}
				let knownHostsSnapshot = knownHostsLines(
					path: sessionStore.knownHostsCaterm
				)
				var hosts: [BackupHost] = []
				for host in hostSnapshot {
					if let barrier {
						hosts.append(try await backupHost(
							host,
							under: barrier,
							allHosts: hostSnapshot,
							sessionStore: sessionStore
						))
					} else {
						hosts.append(makeBackupHost(
							host,
							material: nil,
							allHosts: hostSnapshot
						))
					}
				}
				guard sessionStore.hosts == hostSnapshot else {
					throw HostSnapshotChanged()
				}

				let backupSnippets = snippets.map { snippet in
					BackupSnippet(
						id: snippet.id,
						name: snippet.name,
						content: snippet.content,
						placeholders: snippet.placeholders,
						createdAt: snippet.createdAt,
						updatedAt: snippet.updatedAt
					)
				}

				let backupSettings = settings.map { settings in
					BackupSettings(
						revision: settings.revision,
						global: settings.global,
						hostOverrides: Dictionary(uniqueKeysWithValues:
							settings.hostOverrides.map {
								($0.key.rawValue, $0.value)
							})
					)
				}

				payload = BackupPayload(
					exportedAt: now,
					appVersion: appVersion,
					hosts: hosts,
					snippets: backupSnippets,
					settings: backupSettings,
					bookmarks: bookmarkSnapshot,
					knownHosts: knownHostsSnapshot
				)
			} catch is HostSnapshotChanged {
				if let barrier {
					await sessionStore.credentialMaterialStore
						.finishReadBarrier(barrier)
				}
				continue
			} catch {
				if let barrier {
					await sessionStore.credentialMaterialStore
						.finishReadBarrier(barrier)
				}
				throw error
			}
			if let barrier {
				await sessionStore.credentialMaterialStore
					.finishReadBarrier(barrier)
			}
			return payload
		}
	}

	// MARK: Hosts

	private static func backupHost(
		_ host: SSHHost,
		under barrier: CredentialMaterialReadBarrier,
		allHosts: [SSHHost],
		sessionStore: SessionStore
	) async throws -> BackupHost {
		try Task.checkCancellation()
		let snapshot: StoredCredentialMaterialSnapshot
		do {
			snapshot = try await sessionStore.credentialMaterialStore.snapshot(
				for: host.id,
				under: barrier
			)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			throw BackupExportError.credentialMaterialUnavailable(
				hostName: host.name,
				underlying: String(describing: error)
			)
		}
		try Task.checkCancellation()
		guard sessionStore.hosts.first(where: { $0.id == host.id }) == host else {
			throw HostSnapshotChanged()
		}
		return makeBackupHost(
			host,
			material: snapshot,
			allHosts: allHosts
		)
	}

	private static func makeBackupHost(
		_ host: SSHHost,
		material: StoredCredentialMaterialSnapshot?,
		allHosts: [SSHHost]
	) -> BackupHost {
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
		if let material {
			password = material.password.flatMap {
				String(data: $0, encoding: .utf8)
			}
			passphrase = material.passphrase.flatMap {
				String(data: $0, encoding: .utf8)
			}
			if case let .keyFile(path, _) = host.credential {
				// Managed copy first, on-disk path as a legacy fallback —
				// same resolution order the credential sync push uses.
				privateKey = material.managedPrivateKey
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
			jumpHostId: resolvedJumpHostId(host, in: allHosts),
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
			groupPath: host.organization.groupPath,
			tags: host.organization.tags,
			automation: BackupHostAutomation(
				isEnabled: host.automation.isEnabled,
				startupSnippetID: host.automation.startupSnippetID,
				environment: host.automation.environment.map {
					BackupHostEnvironmentVariable(
						id: $0.id,
						name: $0.name,
						value: $0.value
					)
				},
				reviewPolicy: host.automation.reviewPolicy.rawValue,
				reconnectPolicy: host.automation.reconnectPolicy.rawValue
			),
			password: password,
			passphrase: passphrase,
			privateKey: privateKey
		)
	}

	/// The payload's jump reference is always the referenced host's payload
	/// `id`. Hosts that only carry a `jumpHostServerId` (pulled before the
	/// local backfill ran) resolve through it.
	private static func resolvedJumpHostId(_ host: SSHHost, in hosts: [SSHHost]) -> UUID? {
		if let id = host.jumpHostId {
			return hosts.contains(where: { $0.id == id }) ? id : nil
		}
		guard let sid = host.jumpHostServerId else { return nil }
		return hosts.first { $0.serverId == sid }?.id
	}

	private static func knownHostsLines(path: String) -> [String] {
		guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
		return text.split(separator: "\n", omittingEmptySubsequences: true)
			.map(String.init)
			.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
	}
}
