import BackupArchive
import Foundation
import SessionStore
import SettingsStore
import SnippetStore
import SnippetSyncClient
import SSHCommandBuilder

/// What an apply actually did, for the post-import summary.
public struct BackupImportSummary: Equatable {
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
		bookmarkStore: RemoteBookmarkStore?
	) async throws -> BackupImportSummary {
		var summary = BackupImportSummary()

		// Pass 1 — host metadata (adds first so jump targets exist).
		for action in plan.hosts {
			switch action.kind {
			case .add:
				try sessionStore.addHost(hostForAdd(action.archiveHost))
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
	private static func hostForAdd(_ a: BackupHost) -> SSHHost {
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
			icon: a.icon
		)
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
