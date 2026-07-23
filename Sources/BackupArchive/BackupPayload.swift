import Foundation
import SettingsStore

/// Plaintext content of a backup archive. Deliberately a standalone DTO
/// schema — NOT the live model types — so archives written today stay
/// decodable forever regardless of how the app models evolve. Versioned
/// by `contentVersion`, independent of the envelope's `formatVersion`
/// (ADR 0002).
///
/// Sync bookkeeping (change tokens, outbox state, revision counters) is
/// deliberately absent: it is device-local state, meaningless — and
/// harmful — on another machine. `serverId` IS carried, but only as a
/// cross-device identity hint for import matching; imports never write a
/// foreign serverId into local state.
public struct BackupPayload: Codable, Equatable {
	public static let contentVersion = 1

	public var contentVersion: Int
	public var exportedAt: Date
	/// Marketing version of the exporting app, for diagnostics only.
	public var appVersion: String?
	public var hosts: [BackupHost]
	public var snippets: [BackupSnippet]
	public var settings: BackupSettings?
	public var bookmarks: [BackupBookmark]
	/// Lines of the Caterm-managed known_hosts file (server fingerprints —
	/// carrying them over preserves established trust on the new device).
	public var knownHosts: [String]

	public init(
		contentVersion: Int = BackupPayload.contentVersion,
		exportedAt: Date,
		appVersion: String? = nil,
		hosts: [BackupHost] = [],
		snippets: [BackupSnippet] = [],
		settings: BackupSettings? = nil,
		bookmarks: [BackupBookmark] = [],
		knownHosts: [String] = []
	) {
		self.contentVersion = contentVersion
		self.exportedAt = exportedAt
		self.appVersion = appVersion
		self.hosts = hosts
		self.snippets = snippets
		self.settings = settings
		self.bookmarks = bookmarks
		self.knownHosts = knownHosts
	}

	/// Canonical payload encoding (ISO-8601 dates, sorted keys).
	public func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(self)
	}

	public static func decode(_ data: Data) throws -> BackupPayload {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let payload: BackupPayload
		do {
			payload = try decoder.decode(BackupPayload.self, from: data)
		} catch {
			throw BackupArchiveError.corruptArchive(reason: "unreadable payload")
		}
		guard payload.contentVersion <= contentVersion else {
			throw BackupArchiveError.unsupportedFormatVersion(payload.contentVersion)
		}
		return payload
	}
}

/// One saved host, flattened: metadata plus (optionally) its credential
/// material. Secret fields are nil when the user exported without
/// secrets.
public struct BackupHost: Codable, Equatable {
	public var id: UUID
	/// Cross-device identity hint (see BackupPayload doc).
	public var serverId: String?
	public var name: String
	public var hostname: String
	public var port: Int
	public var username: String
	/// "password" | "keyFile" | "agent" (legacy).
	public var credentialKind: String
	public var hasPassphrase: Bool
	public var createdAt: Date
	public var updatedAt: Date
	/// Reference to another host in THIS payload's `hosts` array (by its
	/// `id`). Rewritten to local UUIDs at import time.
	public var jumpHostId: UUID?
	public var forwards: [BackupPortForward]
	public var icon: String?
	/// Optional for backward compatibility with content-version 1 archives.
	public var groupPath: [String]?
	public var tags: [String]?
	/// Optional for backward compatibility with content-version 1 archives.
	public var automation: BackupHostAutomation?

	// Secret material (present only when exported with secrets).
	public var password: String?
	public var passphrase: String?
	/// Private-key bytes from managed key storage.
	public var privateKey: Data?

	public init(
		id: UUID, serverId: String?, name: String, hostname: String,
		port: Int, username: String, credentialKind: String,
		hasPassphrase: Bool, createdAt: Date, updatedAt: Date,
		jumpHostId: UUID?, forwards: [BackupPortForward], icon: String?,
		groupPath: [String]? = nil, tags: [String]? = nil,
		automation: BackupHostAutomation? = nil,
		password: String? = nil, passphrase: String? = nil,
		privateKey: Data? = nil
	) {
		self.id = id
		self.serverId = serverId
		self.name = name
		self.hostname = hostname
		self.port = port
		self.username = username
		self.credentialKind = credentialKind
		self.hasPassphrase = hasPassphrase
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.jumpHostId = jumpHostId
		self.forwards = forwards
		self.icon = icon
		self.groupPath = groupPath
		self.tags = tags
		self.automation = automation
		self.password = password
		self.passphrase = passphrase
		self.privateKey = privateKey
	}
}

public struct BackupHostAutomation: Codable, Equatable {
	public var isEnabled: Bool
	public var startupSnippetID: UUID?
	public var environment: [BackupHostEnvironmentVariable]
	public var reviewPolicy: String
	public var reconnectPolicy: String

	public init(
		isEnabled: Bool,
		startupSnippetID: UUID? = nil,
		environment: [BackupHostEnvironmentVariable] = [],
		reviewPolicy: String,
		reconnectPolicy: String
	) {
		self.isEnabled = isEnabled
		self.startupSnippetID = startupSnippetID
		self.environment = environment
		self.reviewPolicy = reviewPolicy
		self.reconnectPolicy = reconnectPolicy
	}
}

public struct BackupHostEnvironmentVariable: Codable, Equatable {
	public var id: UUID
	public var name: String
	public var value: String

	public init(id: UUID, name: String, value: String) {
		self.id = id
		self.name = name
		self.value = value
	}
}

public struct BackupPortForward: Codable, Equatable {
	/// "local" | "remote" | "dynamic".
	public var kind: String
	public var bindAddress: String?
	public var bindPort: Int
	public var remoteHost: String?
	public var remotePort: Int?
	public var required: Bool
	public var label: String?

	public init(kind: String, bindAddress: String? = nil, bindPort: Int,
	            remoteHost: String?, remotePort: Int?, required: Bool,
	            label: String? = nil) {
		self.kind = kind
		self.bindAddress = bindAddress
		self.bindPort = bindPort
		self.remoteHost = remoteHost
		self.remotePort = remotePort
		self.required = required
		self.label = label
	}
}

public struct BackupSnippet: Codable, Equatable {
	public var id: UUID
	public var name: String
	public var content: String
	public var placeholders: [String]?
	public var createdAt: Date
	public var updatedAt: Date

	public init(id: UUID, name: String, content: String,
	            placeholders: [String]?, createdAt: Date, updatedAt: Date) {
		self.id = id
		self.name = name
		self.content = content
		self.placeholders = placeholders
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}
}

/// Whole-store settings snapshot. Imported with revision-based LWW —
/// the same policy the settings sync channel uses — never field-merged.
public struct BackupSettings: Codable, Equatable {
	/// Sortable revision (see SettingsStore.makeRevision) driving LWW.
	public var revision: String
	public var global: PartialSettings
	/// Keyed by the exporting device's host UUID string; remapped to
	/// local host IDs at import time.
	public var hostOverrides: [String: PartialSettings]

	public init(revision: String, global: PartialSettings,
	            hostOverrides: [String: PartialSettings]) {
		self.revision = revision
		self.global = global
		self.hostOverrides = hostOverrides
	}
}

public struct BackupBookmark: Codable, Equatable {
	public var id: UUID
	/// Host reference by the payload's host `id`; remapped at import.
	public var hostId: UUID
	public var label: String
	public var path: String
	public var createdAt: Date

	public init(id: UUID, hostId: UUID, label: String, path: String, createdAt: Date) {
		self.id = id
		self.hostId = hostId
		self.label = label
		self.path = path
		self.createdAt = createdAt
	}
}
