import BackupArchive
import BackupService
import Foundation
import KeychainStore
import ManagedKeyStore
import SnippetSyncClient
import SSHCommandBuilder

/// Mobile counterpart of the desktop backup engine. Reuses the shared
/// payload schema and `BackupMergePlanner` (both store-agnostic); gather
/// and apply are reimplemented against the mobile surfaces — a host
/// array binding, the shared Keychain convention, and `ManagedKeyStore`.
///
/// Platform scope: hosts + credentials + snippets. macOS settings, path
/// bookmarks, and OpenSSH-format known_hosts have no mobile counterpart
/// store — the preview marks them as skipped rather than inventing one.
@MainActor
public enum MobileBackupService {

	// MARK: Export

	public static func makePayload(
		hosts: [SSHHost],
		snippets: [Snippet],
		includeSecrets: Bool,
		keychain: KeychainStore,
		now: Date = Date()
	) -> BackupPayload {
		let backupHosts = hosts.map { host -> BackupHost in
			let kind: String
			let hasPassphrase: Bool
			switch host.credential {
			case .password: kind = "password"; hasPassphrase = false
			case let .keyFile(_, hp): kind = "keyFile"; hasPassphrase = hp
			case .agent: kind = "agent"; hasPassphrase = false
			}
			var password: String?
			var passphrase: String?
			var privateKey: Data?
			if includeSecrets {
				password = try? keychain.get(
					account: MobileCredentialPlan.passwordAccount(host.id))
				passphrase = try? keychain.get(
					account: MobileCredentialPlan.keyPassphraseAccount(host.id))
				if case let .keyFile(path, _) = host.credential {
					privateKey = FileManager.default.contents(
						atPath: (path as NSString).expandingTildeInPath)
				}
			}
			return BackupHost(
				id: host.id, serverId: host.serverId, name: host.name,
				hostname: host.hostname, port: host.port, username: host.username,
				credentialKind: kind, hasPassphrase: hasPassphrase,
				createdAt: host.createdAt, updatedAt: host.updatedAt,
				jumpHostId: host.jumpHostId
					?? hosts.first { $0.serverId != nil && $0.serverId == host.jumpHostServerId }?.id,
				forwards: host.forwards.map { f in
					BackupPortForward(kind: f.kind.rawValue, bindAddress: f.bindAddress,
					                  bindPort: f.bindPort, remoteHost: f.remoteHost,
					                  remotePort: f.remotePort, required: f.required,
					                  label: f.label)
				},
				icon: host.icon,
				password: password, passphrase: passphrase, privateKey: privateKey
			)
		}
		let backupSnippets = snippets.map { s in
			BackupSnippet(id: s.id, name: s.name, content: s.content,
			              placeholders: s.placeholders,
			              createdAt: s.createdAt, updatedAt: s.updatedAt)
		}
		return BackupPayload(exportedAt: now, hosts: backupHosts,
		                     snippets: backupSnippets)
	}

	// MARK: Plan

	public static func plan(
		payload: BackupPayload,
		hosts: [SSHHost],
		snippets: [Snippet],
		keychain: KeychainStore
	) -> BackupMergePlan {
		BackupMergePlanner.plan(
			payload: payload,
			localHosts: hosts,
			needsCredentialSetup: { host in
				needsCredentialSetup(host, keychain: keychain)
			},
			localSnippets: snippets,
			localSettingsRevision: nil,
			localBookmarks: { _ in [] },
			localKnownHostsLines: []
		)
	}

	/// Mirror of the desktop `SessionStore.needsCredentialSetup` using the
	/// shared Keychain account convention.
	static func needsCredentialSetup(_ host: SSHHost, keychain: KeychainStore) -> Bool {
		switch host.credential {
		case .agent:
			return false
		case .password:
			return (try? keychain.get(
				account: MobileCredentialPlan.passwordAccount(host.id))) == nil
		case let .keyFile(keyPath, hasPassphrase):
			if !FileManager.default.fileExists(
				atPath: (keyPath as NSString).expandingTildeInPath) { return true }
			if hasPassphrase {
				return (try? keychain.get(
					account: MobileCredentialPlan.keyPassphraseAccount(host.id))) == nil
			}
			return false
		}
	}

	// MARK: Apply

	public struct ApplyResult {
		public var hosts: [SSHHost]
		public var snippets: [Snippet]
		public var summary: BackupImportSummary
	}

	/// Same merge semantics as the desktop importer (add strips foreign
	/// serverId; update = metadata; credentialsOnly fills secrets; jump
	/// chains rewritten to local identities; nothing is ever deleted).
	/// Returns new arrays — the caller assigns them to the persisting
	/// bindings.
	public static func apply(
		plan: BackupMergePlan,
		hosts: [SSHHost],
		snippets: [Snippet],
		keychain: KeychainStore,
		managedKeys: ManagedKeyStore,
		now: Date = Date()
	) async throws -> ApplyResult {
		var result = ApplyResult(hosts: hosts, snippets: snippets,
		                         summary: BackupImportSummary())

		// Pass 1 — host metadata.
		for action in plan.hosts {
			let a = action.archiveHost
			switch action.kind {
			case .add:
				result.hosts.append(SSHHost(
					id: a.id, serverId: nil, name: a.name, hostname: a.hostname,
					port: a.port, username: a.username,
					credential: placeholderCredential(for: a),
					createdAt: a.createdAt, updatedAt: a.updatedAt,
					forwards: a.forwards.map(portForward(from:)), icon: a.icon
				))
				result.summary.hostsAdded += 1
			case .update:
				guard let idx = result.hosts.firstIndex(where: { $0.id == action.localHostId })
				else { continue }
				result.hosts[idx].name = a.name
				result.hosts[idx].hostname = a.hostname
				result.hosts[idx].port = a.port
				result.hosts[idx].username = a.username
				result.hosts[idx].forwards = a.forwards.map(portForward(from:))
				result.hosts[idx].icon = a.icon
				result.hosts[idx].updatedAt = now
				result.summary.hostsUpdated += 1
			case .credentialsOnly:
				result.summary.hostsCredentialsOnly += 1
			case .skipLocalNewer:
				result.summary.hostsSkipped += 1
			}
		}

		// Pass 2 — jump chains onto local identities.
		for action in plan.hosts where action.kind == .add || action.kind == .update {
			guard let archiveJump = action.archiveHost.jumpHostId,
			      let localTargetId = plan.hostIdMapping[archiveJump],
			      let idx = result.hosts.firstIndex(where: {
			      	$0.id == plan.hostIdMapping[action.archiveHost.id]
			      })
			else { continue }
			result.hosts[idx].jumpHostId = localTargetId
			result.hosts[idx].jumpHostServerId = result.hosts
				.first { $0.id == localTargetId }?.serverId
		}

		// Pass 3 — credential material.
		for action in plan.hosts where action.appliesSecrets {
			let a = action.archiveHost
			guard let localId = plan.hostIdMapping[a.id],
			      let idx = result.hosts.firstIndex(where: { $0.id == localId })
			else { continue }
			if let pw = a.password {
				try keychain.set(
					account: MobileCredentialPlan.passwordAccount(localId), secret: pw)
			}
			if let pp = a.passphrase {
				try keychain.set(
					account: MobileCredentialPlan.keyPassphraseAccount(localId), secret: pp)
			}
			if let keyBytes = a.privateKey {
				let target = try await managedKeys.write(hostId: localId, bytes: keyBytes)
				result.hosts[idx].credential = .keyFile(
					keyPath: target.path, hasPassphrase: a.passphrase != nil)
			} else if a.credentialKind == "password" {
				result.hosts[idx].credential = .password
			}
		}

		// Snippets.
		for action in plan.snippets {
			let a = action.archiveSnippet
			switch action.kind {
			case .add:
				result.snippets.append(Snippet(
					id: a.id, name: a.name, content: a.content,
					placeholders: a.placeholders,
					createdAt: a.createdAt, updatedAt: a.updatedAt
				))
				result.summary.snippetsAdded += 1
			case .update:
				guard let idx = result.snippets.firstIndex(where: { $0.id == a.id })
				else { continue }
				result.snippets[idx].name = a.name
				result.snippets[idx].content = a.content
				result.snippets[idx].placeholders = a.placeholders
				result.snippets[idx].updatedAt = now
				result.summary.snippetsUpdated += 1
			case .skipLocalNewer:
				result.summary.snippetsSkipped += 1
			}
		}

		return result
	}

	private static func placeholderCredential(for a: BackupHost) -> CredentialSource {
		switch a.credentialKind {
		case "keyFile": return .keyFile(keyPath: "", hasPassphrase: a.hasPassphrase)
		default: return .password
		}
	}

	private static func portForward(from f: BackupPortForward) -> PortForward {
		PortForward(
			kind: PortForward.Kind(rawValue: f.kind) ?? .local,
			bindAddress: f.bindAddress,
			bindPort: f.bindPort,
			remoteHost: f.remoteHost,
			remotePort: f.remotePort,
			required: f.required,
			label: f.label
		)
	}
}
