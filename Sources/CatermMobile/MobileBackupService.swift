import BackupArchive
import BackupService
import Foundation
import KeychainStore
import ManagedKeyStore
import SnippetSyncClient
import SSHCommandBuilder
import SwiftUI

@MainActor
struct MobileBackupImportAction {
	let apply: @MainActor (
		_ plan: BackupMergePlan,
		_ hosts: [SSHHost],
		_ snippets: [Snippet]
	) async throws -> MobileBackupService.ApplyResult
}

private struct MobileBackupImportActionKey: EnvironmentKey {
	static let defaultValue: MobileBackupImportAction? = nil
}

extension EnvironmentValues {
	var mobileBackupImportAction: MobileBackupImportAction? {
		get { self[MobileBackupImportActionKey.self] }
		set { self[MobileBackupImportActionKey.self] = newValue }
	}
}

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
	public enum ApplyError: Error {
		case staleAccount
		case rollbackFailed(originalError: any Error, rollbackErrors: [any Error])
	}

	private enum StoredSecret {
		case missing
		case value(String)
	}

	private struct CredentialSnapshot {
		let password: StoredSecret
		let passphrase: StoredSecret
		let privateKey: Data?
	}

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
				groupPath: host.organization.groupPath,
				tags: host.organization.tags,
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
		keychain: any MobileCredentialStoring,
		managedKeys: ManagedKeyStore,
		now: Date = Date(),
		transactionIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
		commit: @escaping @MainActor @Sendable (ApplyResult) async throws -> Void = { _ in }
	) async throws -> ApplyResult {
		var result = ApplyResult(hosts: hosts, snippets: snippets,
		                         summary: BackupImportSummary())
		let credentialHostIDs = Set<UUID>(plan.hosts.compactMap { action in
			guard action.appliesSecrets else { return nil }
			return plan.hostIdMapping[action.archiveHost.id]
		})
		let snapshots = try captureCredentialSnapshots(
			hostIDs: credentialHostIDs,
			keychain: keychain,
			managedKeys: managedKeys
		)

		do {
			guard transactionIsCurrent() else { throw ApplyError.staleAccount }

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
					forwards: a.forwards.map(portForward(from:)), icon: a.icon,
					organization: HostOrganization(
						groupPath: a.groupPath ?? [], tags: a.tags ?? []
					)
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
				result.hosts[idx].organization = HostOrganization(
					groupPath: a.groupPath ?? [], tags: a.tags ?? []
				)
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
				let mappedHostID = plan.hostIdMapping[action.archiveHost.id]
				guard let archiveJump = action.archiveHost.jumpHostId,
				      let localTargetId = plan.hostIdMapping[archiveJump],
				      let idx = result.hosts.firstIndex(where: { $0.id == mappedHostID })
				else { continue }
				result.hosts[idx].jumpHostId = localTargetId
				result.hosts[idx].jumpHostServerId = result.hosts
					.first { $0.id == localTargetId }?.serverId
			}

			// Pass 3 — credential material.
			for action in plan.hosts where action.appliesSecrets {
				guard transactionIsCurrent() else { throw ApplyError.staleAccount }
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
					guard transactionIsCurrent() else { throw ApplyError.staleAccount }
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

			guard transactionIsCurrent() else { throw ApplyError.staleAccount }
			try await commit(result)
			guard transactionIsCurrent() else { throw ApplyError.staleAccount }
			return result
		} catch {
			try await rollbackCredentials(
				snapshots,
				keychain: keychain,
				managedKeys: managedKeys,
				originalError: error
			)
		}
	}

	private static func captureCredentialSnapshots(
		hostIDs: Set<UUID>,
		keychain: any MobileCredentialStoring,
		managedKeys: ManagedKeyStore
	) throws -> [UUID: CredentialSnapshot] {
		try Dictionary(uniqueKeysWithValues: hostIDs.map { hostID in
			let password = try captureSecret(
				account: MobileCredentialPlan.passwordAccount(hostID),
				keychain: keychain
			)
			let passphrase = try captureSecret(
				account: MobileCredentialPlan.keyPassphraseAccount(hostID),
				keychain: keychain
			)
			return (hostID, CredentialSnapshot(
				password: password,
				passphrase: passphrase,
				privateKey: try managedKeys.read(hostId: hostID)
			))
		})
	}

	private static func captureSecret(
		account: String,
		keychain: any MobileCredentialStoring
	) throws -> StoredSecret {
		do {
			return .value(try keychain.get(
				account: account,
				interaction: .userInitiated
			))
		} catch KeychainError.notFound {
			return .missing
		}
	}

	private static func rollbackCredentials(
		_ snapshots: [UUID: CredentialSnapshot],
		keychain: any MobileCredentialStoring,
		managedKeys: ManagedKeyStore,
		originalError: any Error
	) async throws -> Never {
		var rollbackErrors: [any Error] = []
		for (hostID, snapshot) in snapshots {
			do {
				try restoreSecret(
					snapshot.password,
					account: MobileCredentialPlan.passwordAccount(hostID),
					keychain: keychain
				)
			} catch {
				rollbackErrors.append(error)
			}
			do {
				try restoreSecret(
					snapshot.passphrase,
					account: MobileCredentialPlan.keyPassphraseAccount(hostID),
					keychain: keychain
				)
			} catch {
				rollbackErrors.append(error)
			}
			do {
				if let privateKey = snapshot.privateKey {
					_ = try await managedKeys.write(hostId: hostID, bytes: privateKey)
				} else {
					try await managedKeys.delete(hostId: hostID)
				}
			} catch {
				rollbackErrors.append(error)
			}
		}
		guard rollbackErrors.isEmpty else {
			throw ApplyError.rollbackFailed(
				originalError: originalError,
				rollbackErrors: rollbackErrors
			)
		}
		throw originalError
	}

	private static func restoreSecret(
		_ snapshot: StoredSecret,
		account: String,
		keychain: any MobileCredentialStoring
	) throws {
		switch snapshot {
		case .missing:
			do {
				try keychain.delete(account: account)
			} catch KeychainError.notFound {}
		case .value(let value):
			try keychain.set(account: account, secret: value)
		}
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

@MainActor
final class MobileBackupImportCoordinator {
	private let hostStore: MobileHostStore
	private let keychain: any MobileCredentialStoring
	private let managedKeys: ManagedKeyStore
	private let beforeCommit: @MainActor @Sendable () async -> Void

	init(
		hostStore: MobileHostStore,
		keychain: any MobileCredentialStoring = KeychainStore(
			service: MobileCredentialWriter.defaultService,
			accessGroup: nil
		),
		managedKeys: ManagedKeyStore? = nil,
		beforeCommit: @escaping @MainActor @Sendable () async -> Void = {}
	) {
		self.hostStore = hostStore
		self.keychain = keychain
		self.managedKeys = managedKeys ?? hostStore.managedKeyStore
		self.beforeCommit = beforeCommit
	}

	func apply(
		plan: BackupMergePlan,
		hosts _: [SSHHost],
		snippets: [Snippet]
	) async throws -> MobileBackupService.ApplyResult {
		let accountContext = try await hostStore.beginExclusiveAccountOperation()
		defer { hostStore.endAccountOperation() }
		let credentialHostIDs = Set<UUID>(plan.hosts.compactMap { action in
			guard action.appliesSecrets else { return nil }
			return plan.hostIdMapping[action.archiveHost.id]
		})
		try hostStore.registerCredentialCleanup(
			hostIDs: credentialHostIDs,
			accountContext: accountContext
		)

		do {
			let result = try await MobileBackupService.apply(
				plan: plan,
				hosts: hostStore.hosts,
				snippets: snippets,
				keychain: keychain,
				managedKeys: managedKeys,
				transactionIsCurrent: {
					self.hostStore.isCurrent(accountContext)
				},
				commit: { result in
					await self.beforeCommit()
					try await self.hostStore.replaceAll(
						result.hosts,
						accountContext: accountContext
					)
				}
			)
			try hostStore.unregisterCredentialCleanup(
				hostIDs: credentialHostIDs,
				accountContext: accountContext
			)
			return result
		} catch {
			if hostStore.isCurrent(accountContext),
				!Self.isRollbackFailure(error) {
				try? hostStore.unregisterCredentialCleanup(
					hostIDs: credentialHostIDs,
					accountContext: accountContext
				)
			}
			throw error
		}
	}

	private static func isRollbackFailure(_ error: any Error) -> Bool {
		guard let applyError = error as? MobileBackupService.ApplyError else {
			return false
		}
		if case .rollbackFailed = applyError { return true }
		return false
	}
}
