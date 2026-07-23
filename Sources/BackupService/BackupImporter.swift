import BackupArchive
import CredentialIdentitySecurity
import CredentialIdentityStore
import Foundation
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder

/// What an apply actually did, for the post-import summary.
public struct BackupImportSummary: Equatable {
	public var credentialIdentitiesAdded = 0
	public var credentialIdentitiesUpdated = 0
	public var credentialIdentitiesMaterialOnly = 0
	public var credentialIdentitiesSkipped = 0
	public var hostsAdded = 0
	public var hostsUpdated = 0
	public var hostsCredentialsOnly = 0
	public var hostsSkipped = 0
	public var snippetsAdded = 0
	public var snippetsUpdated = 0
	public var snippetsSkipped = 0
	public var settingsApplied = false
	public var bookmarksAdded = 0
	public var knownHostsAppended = 0

	public init() {}
}

public enum BackupImportError: Error, Equatable {
	case invalidHostAutomation(hostID: UUID, reason: String)
	case invalidCredentialIdentity(identityID: UUID, reason: String)
	case unresolvedCredentialIdentity(hostID: UUID, identityID: UUID)
	case credentialIdentityStoresUnavailable
}

extension BackupImportError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .invalidHostAutomation(let hostID, let reason):
			"Host \(hostID.uuidString) has invalid startup automation: \(reason)"
		case .invalidCredentialIdentity(let identityID, let reason):
			"Credential identity \(identityID.uuidString) is invalid: \(reason)"
		case .unresolvedCredentialIdentity(let hostID, let identityID):
			"Host \(hostID.uuidString) references unavailable credential identity \(identityID.uuidString)"
		case .credentialIdentityStoresUnavailable:
			"Credential identity stores are unavailable"
		}
	}
}

/// Applies a confirmed `BackupMergePlan`. All writes go through the same
/// store entry points user edits use, so sync invariants hold: added
/// hosts are local-new (foreign serverId stripped) and push naturally;
/// imported credentials set `credentialMaterialDirty` via the Plan C
/// entry point; snippets ride `upsert`; settings ride `save` (fresh
/// revision → settings sync pushes).
@MainActor
public enum BackupImporter {

	public static func apply(
		plan: BackupMergePlan,
		sessionStore: SessionStore,
		snippetStore: SnippetStore?,
		settingsStore: SettingsStore?,
		archiveSettings: BackupSettings?,
		bookmarkStore: RemoteBookmarkStore?,
		credentialIdentityStore: CredentialIdentityStore? = nil,
		credentialIdentityMaterialStore: CredentialIdentityMaterialStore? = nil
	) async throws -> BackupImportSummary {
		try validateHostAutomation(in: plan.hosts)
		try validateCredentialIdentities(
			in: plan,
			store: credentialIdentityStore
		)
		var summary = BackupImportSummary()

		// Credential identities land before hosts so assignments never
		// point at metadata that has not been persisted yet.
		if !plan.credentialIdentities.isEmpty {
			guard let credentialIdentityStore,
			      let credentialIdentityMaterialStore else {
				throw BackupImportError.credentialIdentityStoresUnavailable
			}
			try await credentialIdentityStore.withTransaction {
				for action in plan.credentialIdentities {
					switch action.kind {
					case .add:
						try await applyCredentialIdentity(
							action,
							store: credentialIdentityStore,
							materialStore:
								credentialIdentityMaterialStore
						)
						summary.credentialIdentitiesAdded += 1
					case .update:
						try await applyCredentialIdentity(
							action,
							store: credentialIdentityStore,
							materialStore:
								credentialIdentityMaterialStore
						)
						summary.credentialIdentitiesUpdated += 1
					case .materialOnly:
						try await applyCredentialIdentityMaterialOnly(
							action,
							store: credentialIdentityStore,
							materialStore:
								credentialIdentityMaterialStore
						)
						summary.credentialIdentitiesMaterialOnly += 1
					case .skipLocalNewer:
						summary.credentialIdentitiesSkipped += 1
					}
				}
			}
		}

		// Pass 1 — host metadata (adds first so jump targets exist).
		for action in plan.hosts {
			switch action.kind {
			case .add:
				try sessionStore.addHost(try hostForAdd(
					action.archiveHost,
					identityMapping: plan.credentialIdentityIdMapping
				))
				summary.hostsAdded += 1
			case .update:
				guard var local = sessionStore.hosts.first(where: { $0.id == action.localHostId })
				else { continue }
				let a = action.archiveHost
				local.name = a.name
				local.hostname = a.hostname
				local.port = a.port
				local.username = a.username
				local.forwards = a.forwards.map(portForward(from:))
				local.icon = a.icon
				local.organization = HostOrganization(
					groupPath: a.groupPath ?? [], tags: a.tags ?? []
				)
				if let automation = a.automation {
					local.automation = try hostAutomation(
						from: automation,
						hostID: a.id
					)
				}
				if let reference = a.credentialIdentity {
					local.credentialIdentity = try hostIdentityReference(
						from: reference,
						hostID: a.id,
						identityMapping:
							plan.credentialIdentityIdMapping
					)
				}
				try sessionStore.updateHost(local)
				summary.hostsUpdated += 1
			case .credentialsOnly:
				summary.hostsCredentialsOnly += 1
			case .skipLocalNewer:
				summary.hostsSkipped += 1
			}
		}

		// Pass 2 — jump chains, now that every target has a local identity.
		for action in plan.hosts where action.kind == .add || action.kind == .update {
			guard let archiveJump = action.archiveHost.jumpHostId,
			      let localTargetId = plan.hostIdMapping[archiveJump],
			      var local = sessionStore.hosts.first(where: {
			      	$0.id == plan.hostIdMapping[action.archiveHost.id]
			      }),
			      local.jumpHostId != localTargetId
			else { continue }
			local.jumpHostId = localTargetId
			local.jumpHostServerId = sessionStore.hosts
				.first { $0.id == localTargetId }?.serverId
			try sessionStore.updateHost(local)
		}

		// Pass 3 — credential material through the Plan C entry point.
		for action in plan.hosts where action.appliesSecrets {
			guard let localId = plan.hostIdMapping[action.archiveHost.id] else { continue }
			try await applyCredentials(action.archiveHost, to: localId,
			                           sessionStore: sessionStore)
		}

		// Snippets.
		if let snippetStore {
			for action in plan.snippets {
				let a = action.archiveSnippet
				switch action.kind {
				case .add:
					try snippetStore.upsert(Snippet(
						id: a.id, name: a.name, content: a.content,
						placeholders: a.placeholders,
						createdAt: a.createdAt, updatedAt: a.updatedAt
					))
					summary.snippetsAdded += 1
				case .update:
					guard var local = snippetStore.snippets.first(where: { $0.id == a.id })
					else { continue }
					local.name = a.name
					local.content = a.content
					local.placeholders = a.placeholders
					try snippetStore.upsert(local)
					summary.snippetsUpdated += 1
				case .skipLocalNewer:
					summary.snippetsSkipped += 1
				}
			}
		}

		// Settings — whole-store LWW like the sync channel, except
		// hostOverrides are unioned (imports never delete local state) and
		// remapped onto local host identities. Saved as a local edit
		// (fresh revision) so settings sync propagates it.
		if plan.settings == .apply, let settingsStore, let archiveSettings {
			var next = settingsStore.settings
			next.global = archiveSettings.global
			for (archiveKey, partial) in archiveSettings.hostOverrides {
				let localKey = UUID(uuidString: archiveKey)
					.flatMap { plan.hostIdMapping[$0] }?.uuidString ?? archiveKey
				next.hostOverrides[HostId(localKey)] = partial
			}
			try settingsStore.save(next)
			summary.settingsApplied = true
		}

		// Bookmarks.
		if let bookmarkStore {
			for action in plan.bookmarks where action.kind == .add {
				guard let hostId = action.localHostId else { continue }
				let b = action.archiveBookmark
				if bookmarkStore.add(
					RemoteBookmark(id: b.id, label: b.label, path: b.path,
					               createdAt: b.createdAt),
					for: hostId
				) {
					summary.bookmarksAdded += 1
				}
			}
		}

		// known_hosts — dedup-append, never rewrite existing lines.
		if !plan.knownHostsToAppend.isEmpty {
			try appendKnownHosts(plan.knownHostsToAppend,
			                     path: sessionStore.knownHostsCaterm)
			summary.knownHostsAppended = plan.knownHostsToAppend.count
		}

		return summary
	}

	// MARK: Hosts

	/// Build the local host for an `.add`. Archive UUID and timestamps are
	/// preserved (they ARE the entity's identity/history); the foreign
	/// `serverId` is stripped so the host is local-new to whatever iCloud
	/// account this device syncs with. Jump references land in pass 2.
	private static func hostForAdd(
		_ a: BackupHost,
		identityMapping: [UUID: UUID]
	) throws -> SSHHost {
		SSHHost(
			id: a.id,
			serverId: nil,
			name: a.name,
			hostname: a.hostname,
			port: a.port,
			username: a.username,
			credential: placeholderCredential(for: a),
			createdAt: a.createdAt,
			updatedAt: a.updatedAt,
			forwards: a.forwards.map(portForward(from:)),
			icon: a.icon,
			organization: HostOrganization(
				groupPath: a.groupPath ?? [], tags: a.tags ?? []
			),
			automation: try a.automation.map {
				try hostAutomation(from: $0, hostID: a.id)
			} ?? .disabled,
			credentialIdentity: try a.credentialIdentity.map {
				try hostIdentityReference(
					from: $0,
					hostID: a.id,
					identityMapping: identityMapping
				)
			}
		)
	}

	private static func hostIdentityReference(
		from backup: BackupHostCredentialIdentityReference,
		hostID: UUID,
		identityMapping: [UUID: UUID]
	) throws -> HostCredentialIdentityReference {
		guard let identityID = identityMapping[backup.identityID] else {
			throw BackupImportError.unresolvedCredentialIdentity(
				hostID: hostID,
				identityID: backup.identityID
			)
		}
		guard let migrationState =
			HostCredentialIdentityReference.MigrationState(
				rawValue: backup.migrationState
			) else {
			throw BackupImportError.invalidCredentialIdentity(
				identityID: backup.identityID,
				reason: "unknown migration state \(backup.migrationState)"
			)
		}
		return HostCredentialIdentityReference(
			identityID: identityID,
			migrationState: migrationState
		)
	}

	private static func hostAutomation(
		from backup: BackupHostAutomation,
		hostID: UUID
	) throws -> HostAutomation {
		guard let reviewPolicy = HostAutomationReviewPolicy(
			rawValue: backup.reviewPolicy
		) else {
			throw BackupImportError.invalidHostAutomation(
				hostID: hostID,
				reason: "unknown review policy \(backup.reviewPolicy)"
			)
		}
		guard let reconnectPolicy = HostAutomationReconnectPolicy(
			rawValue: backup.reconnectPolicy
		) else {
			throw BackupImportError.invalidHostAutomation(
				hostID: hostID,
				reason: "unknown reconnect policy \(backup.reconnectPolicy)"
			)
		}
		let automation = HostAutomation(
			isEnabled: backup.isEnabled,
			startupSnippetID: backup.startupSnippetID,
			environment: backup.environment.map {
				HostEnvironmentVariable(
					id: $0.id,
					name: $0.name,
					value: $0.value
				)
			},
			reviewPolicy: reviewPolicy,
			reconnectPolicy: reconnectPolicy
		)
		do {
			return try automation.validated()
		} catch {
			throw BackupImportError.invalidHostAutomation(
				hostID: hostID,
				reason: (error as? LocalizedError)?.errorDescription
					?? String(describing: error)
			)
		}
	}

	private static func validateHostAutomation(
		in actions: [BackupMergePlan.HostAction]
	) throws {
		for action in actions
		where action.kind == .add || action.kind == .update {
			guard let automation = action.archiveHost.automation else {
				continue
			}
			_ = try hostAutomation(
				from: automation,
				hostID: action.archiveHost.id
			)
		}
	}

	private static func validateCredentialIdentities(
		in plan: BackupMergePlan,
		store: CredentialIdentityStore?
	) throws {
		if !plan.credentialIdentities.isEmpty, store == nil {
			throw BackupImportError.credentialIdentityStoresUnavailable
		}
		for action in plan.credentialIdentities
		where action.kind == .add || action.kind == .update {
			_ = try identity(
				from: action.archiveIdentity,
				id: action.localIdentityID ?? action.archiveIdentity.id,
				materialID: action.localIdentityID.flatMap {
					store?.identity(id: $0)?.source.materialID
				} ?? CredentialMaterialID(
					rawValue: action.archiveIdentity.materialId
				)
			)
		}
		for action in plan.hosts
		where action.kind == .add || action.kind == .update {
			guard let reference = action.archiveHost.credentialIdentity else {
				continue
			}
			_ = try hostIdentityReference(
				from: reference,
				hostID: action.archiveHost.id,
				identityMapping: plan.credentialIdentityIdMapping
			)
		}
	}

	private static func applyCredentialIdentity(
		_ action: BackupMergePlan.CredentialIdentityAction,
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore
	) async throws {
		let archive = action.archiveIdentity
		let localID = action.localIdentityID ?? archive.id
		let previous = store.identity(id: localID)
		let materialID = previous?.source.materialID
			?? CredentialMaterialID(rawValue: archive.materialId)
		let candidate = try identity(
			from: archive,
			id: localID,
			materialID: materialID
		)
		let previousMaterial: CredentialIdentityMaterial?
		if let previous {
			previousMaterial = try await materialStore.snapshot(for: previous)
		} else {
			previousMaterial = nil
		}
		do {
			if action.appliesSecrets {
				try await materialStore.replaceMaterial(
					for: candidate,
					with: material(from: archive)
				)
			} else if let previous,
			          !sameSourceFamily(
			           previous.source,
			           candidate.source
			          ) {
				try await materialStore.delete(identity: previous)
			}
			try await store.upsert(candidate)
		} catch {
			let operationError = error
			if let previous, let previousMaterial {
				do {
					try await materialStore.replaceMaterial(
						for: previous,
						with: previousMaterial
					)
				} catch {
					throw CredentialIdentityRollbackError(
						operation: operationError,
						rollback: error
					)
				}
			} else if previous == nil {
				do {
					try await materialStore.delete(identity: candidate)
				} catch {
					throw CredentialIdentityRollbackError(
						operation: operationError,
						rollback: error
					)
				}
			}
			throw operationError
		}
	}

	private static func applyCredentialIdentityMaterialOnly(
		_ action: BackupMergePlan.CredentialIdentityAction,
		store: CredentialIdentityStore,
		materialStore: CredentialIdentityMaterialStore
	) async throws {
		guard let localID = action.localIdentityID,
		      let local = store.identity(id: localID) else {
			throw BackupImportError.invalidCredentialIdentity(
				identityID: action.archiveIdentity.id,
				reason: "matched local identity is missing"
			)
		}
		try await materialStore.replaceMaterial(
			for: local,
			with: material(from: action.archiveIdentity)
		)
	}

	private static func identity(
		from backup: BackupCredentialIdentity,
		id: UUID,
		materialID: CredentialMaterialID
	) throws -> CredentialIdentity {
		let source: CredentialIdentitySource
		switch backup.kind {
		case "password":
			source = .password(materialID: materialID)
		case "managedKey":
			source = .managedKey(
				materialID: materialID,
				hasPassphrase: backup.hasPassphrase
			)
		case "sshCertificate":
			guard let certificate = backup.publicCertificate else {
				throw BackupImportError.invalidCredentialIdentity(
					identityID: backup.id,
					reason: "SSH certificate is missing its public half"
				)
			}
			source = .sshCertificate(
				materialID: materialID,
				publicCertificate: certificate,
				hasPassphrase: backup.hasPassphrase
			)
		case "secureEnclaveP256":
			guard let publicKey = backup.publicKey,
			      let originDeviceID = backup.originDeviceId else {
				throw BackupImportError.invalidCredentialIdentity(
					identityID: backup.id,
					reason: "Secure Enclave public metadata is incomplete"
				)
			}
			source = .secureEnclaveP256(
				materialID: materialID,
				publicKey: publicKey,
				originDeviceID: originDeviceID
			)
		default:
			throw BackupImportError.invalidCredentialIdentity(
				identityID: backup.id,
				reason: "unknown source \(backup.kind)"
			)
		}
		do {
			return try CredentialIdentity(
				id: id,
				serverID: nil,
				name: backup.name,
				username: backup.username,
				source: source,
				createdAt: backup.createdAt,
				updatedAt: backup.updatedAt
			).validated()
		} catch let error as BackupImportError {
			throw error
		} catch {
			throw BackupImportError.invalidCredentialIdentity(
				identityID: backup.id,
				reason: String(describing: error)
			)
		}
	}

	private static func material(
		from backup: BackupCredentialIdentity
	) -> CredentialIdentityMaterial {
		CredentialIdentityMaterial(
			password: backup.password,
			passphrase: backup.passphrase,
			privateKey: backup.privateKey
		)
	}

	private static func sameSourceFamily(
		_ lhs: CredentialIdentitySource,
		_ rhs: CredentialIdentitySource
	) -> Bool {
		switch (lhs, rhs) {
		case (.password, .password),
		     (.managedKey, .managedKey),
		     (.sshCertificate, .sshCertificate),
		     (.secureEnclaveP256, .secureEnclaveP256):
			true
		default:
			false
		}
	}

	/// Credential shape before (or without) secret material. A keyFile
	/// host imported without its key gets an empty path — unreadable, so
	/// `needsCredentialSetup` guides the user on first connect. Legacy
	/// "agent" hosts surface as `.password` (agent auth was removed in
	/// v1.7).
	private static func placeholderCredential(for a: BackupHost) -> CredentialSource {
		switch a.credentialKind {
		case "keyFile": return .keyFile(keyPath: "", hasPassphrase: a.hasPassphrase)
		default: return .password
		}
	}

	private static func applyCredentials(
		_ a: BackupHost, to localId: UUID,
		sessionStore: SessionStore
	) async throws {
		let source: CredentialSource
		if a.privateKey != nil {
			source = .keyFile(keyPath: "", hasPassphrase: a.passphrase != nil)
		} else if a.credentialKind == "keyFile" {
			// Passphrase-only material for a key that didn't travel: keep
			// whatever key reference the local host already has.
			guard let local = sessionStore.hosts.first(where: { $0.id == localId }),
			      case .keyFile = local.credential else { return }
			source = local.credential
		} else {
			source = .password
		}
		try await sessionStore.setHostCredentialMaterial(
			secrets: HostSecrets(
				password: a.password.map { Data($0.utf8) },
				passphrase: a.passphrase.map { Data($0.utf8) },
				privateKeyBytes: a.privateKey
			),
			credentialSource: source,
			for: localId
		)
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

	// MARK: known_hosts

	private static func appendKnownHosts(_ lines: [String], path: String) throws {
		let url = URL(fileURLWithPath: path)
		var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
		if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
		text += lines.joined(separator: "\n") + "\n"
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try text.write(to: url, atomically: true, encoding: .utf8)
	}
}
