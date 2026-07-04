import BackupArchive
import Foundation
import SessionStore
import SnippetSyncClient
import SSHCommandBuilder

/// Dry-run result of matching an archive against local data. Shown to the
/// user for confirmation before `BackupImporter.apply` writes anything.
/// Merge semantics (CONTEXT.md "Merge"): match by UUID then server ID,
/// newer side wins per entity, local entities absent from the archive are
/// never deleted.
public struct BackupMergePlan: Equatable {
	public struct HostAction: Equatable, Identifiable {
		public enum Kind: Equatable {
			case add
			/// Local host matched and the archive copy is newer.
			case update
			/// Local copy is newer (metadata untouched), but it has no
			/// usable credential and the archive brings one.
			case credentialsOnly
			case skipLocalNewer
		}
		public let kind: Kind
		public let archiveHost: BackupHost
		/// Matched local host (nil for `.add`).
		public let localHostId: UUID?
		/// Whether applying this action writes credential material.
		public let appliesSecrets: Bool

		public var id: UUID { archiveHost.id }
	}

	public struct SnippetAction: Equatable, Identifiable {
		public enum Kind: Equatable { case add, update, skipLocalNewer }
		public let kind: Kind
		public let archiveSnippet: BackupSnippet

		public var id: UUID { archiveSnippet.id }
	}

	public enum SettingsAction: Equatable {
		/// Archive carries no settings.
		case none
		case apply
		case skipLocalNewer
	}

	public struct BookmarkAction: Equatable, Identifiable {
		public enum Kind: Equatable {
			case add
			/// Same path already bookmarked on the matched host.
			case skipExisting
			/// The bookmark's host isn't part of the archive/local mapping.
			case skipNoHost
		}
		public let kind: Kind
		public let archiveBookmark: BackupBookmark
		public let localHostId: UUID?

		public var id: UUID { archiveBookmark.id }
	}

	public var hosts: [HostAction]
	public var snippets: [SnippetAction]
	public var settings: SettingsAction
	public var bookmarks: [BookmarkAction]
	/// known_hosts lines present in the archive but not locally.
	public var knownHostsToAppend: [String]
	/// Archive host id → the local host id it lands on (matched local id,
	/// or the archive id itself for `.add`). Drives jump-chain and
	/// settings-override remapping in apply.
	public var hostIdMapping: [UUID: UUID]

	public var isEmpty: Bool {
		hosts.allSatisfy { $0.kind == .skipLocalNewer }
			&& snippets.allSatisfy { $0.kind == .skipLocalNewer }
			&& (settings == .none || settings == .skipLocalNewer)
			&& bookmarks.allSatisfy { $0.kind != .add }
			&& knownHostsToAppend.isEmpty
	}
}

@MainActor
public enum BackupMergePlanner {

	/// Compute the merge plan. Pure with respect to persistent state —
	/// reads only.
	public static func plan(
		payload: BackupPayload,
		localHosts: [SSHHost],
		needsCredentialSetup: (SSHHost) -> Bool,
		localSnippets: [Snippet],
		localSettingsRevision: String?,
		localBookmarks: (UUID) -> [RemoteBookmark],
		localKnownHostsLines: [String]
	) -> BackupMergePlan {
		var mapping: [UUID: UUID] = [:]
		var hostActions: [BackupMergePlan.HostAction] = []

		for archiveHost in payload.hosts {
			let local = match(archiveHost, in: localHosts)
			let hasSecrets = archiveHost.password != nil
				|| archiveHost.passphrase != nil
				|| archiveHost.privateKey != nil

			guard let local else {
				mapping[archiveHost.id] = archiveHost.id
				hostActions.append(.init(kind: .add, archiveHost: archiveHost,
				                         localHostId: nil, appliesSecrets: hasSecrets))
				continue
			}
			mapping[archiveHost.id] = local.id
			if archiveHost.updatedAt > local.updatedAt {
				hostActions.append(.init(kind: .update, archiveHost: archiveHost,
				                         localHostId: local.id, appliesSecrets: hasSecrets))
			} else if hasSecrets, needsCredentialSetup(local) {
				// Local metadata wins, but it can't connect and the archive
				// brings the missing credential — the main "manual sync"
				// use case when iCloud credential sync is off.
				hostActions.append(.init(kind: .credentialsOnly, archiveHost: archiveHost,
				                         localHostId: local.id, appliesSecrets: true))
			} else {
				hostActions.append(.init(kind: .skipLocalNewer, archiveHost: archiveHost,
				                         localHostId: local.id, appliesSecrets: false))
			}
		}

		let snippetActions: [BackupMergePlan.SnippetAction] = payload.snippets.map { s in
			guard let local = localSnippets.first(where: { $0.id == s.id }) else {
				return .init(kind: .add, archiveSnippet: s)
			}
			return .init(kind: s.updatedAt > local.updatedAt ? .update : .skipLocalNewer,
			             archiveSnippet: s)
		}

		let settingsAction: BackupMergePlan.SettingsAction
		if let archiveSettings = payload.settings {
			// Same sortable-revision LWW the settings sync channel uses.
			settingsAction = archiveSettings.revision > (localSettingsRevision ?? "")
				? .apply : .skipLocalNewer
		} else {
			settingsAction = .none
		}

		let bookmarkActions: [BackupMergePlan.BookmarkAction] = payload.bookmarks.map { b in
			guard let localHostId = mapping[b.hostId] else {
				return .init(kind: .skipNoHost, archiveBookmark: b, localHostId: nil)
			}
			let existingPaths = Set(localBookmarks(localHostId).map {
				normalizeRemotePath($0.path)
			})
			let kind: BackupMergePlan.BookmarkAction.Kind =
				existingPaths.contains(normalizeRemotePath(b.path)) ? .skipExisting : .add
			return .init(kind: kind, archiveBookmark: b, localHostId: localHostId)
		}

		let existingLines = Set(localKnownHostsLines.map {
			$0.trimmingCharacters(in: .whitespaces)
		})
		let newLines = payload.knownHosts
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty && !existingLines.contains($0) }

		return BackupMergePlan(
			hosts: hostActions,
			snippets: snippetActions,
			settings: settingsAction,
			bookmarks: bookmarkActions,
			knownHostsToAppend: newLines,
			hostIdMapping: mapping
		)
	}

	/// Identity matching: UUID first (same-device round trip), then
	/// serverId (devices that share a CloudKit zone regenerate local UUIDs
	/// per device — serverId is the cross-device key). No endpoint
	/// heuristics: two entries with the same hostname are allowed to be
	/// distinct hosts; the preview makes duplicates visible instead.
	private static func match(_ archiveHost: BackupHost, in locals: [SSHHost]) -> SSHHost? {
		if let byId = locals.first(where: { $0.id == archiveHost.id }) { return byId }
		if let sid = archiveHost.serverId {
			return locals.first { $0.serverId == sid }
		}
		return nil
	}
}
