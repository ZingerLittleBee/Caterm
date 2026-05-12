import Foundation

/// Disambiguating alias for callers who also import modules that expose
/// `Foundation.NSHost` (e.g. anything pulling in AppKit/SwiftUI/Combine).
/// Use `SSHHost` from those contexts; `Host` remains the canonical name
/// inside this module and existing tests.
public typealias SSHHost = Host

public struct Host: Codable, Identifiable, Hashable {
	public let id: UUID
	public var serverId: String?
	public var name: String
	public var hostname: String
	public var port: Int
	public var username: String
	public var credential: CredentialSource
	public var createdAt: Date
	public var updatedAt: Date
	/// Plan C — set true when local credential material has changed and a
	/// `.updateRemoteCredentials` push has not yet succeeded; cleared by
	/// HostSyncStore on push success. Persisted in hosts.json.
	public var credentialMaterialDirty: Bool
	/// CloudKit-stable reference to another saved host that should be used
	/// as the jump host. Stored as `serverId` (not the local `id`) because
	/// local UUIDs are regenerated on each device's pull. Nil = no chain.
	public var jumpHostServerId: String?
	/// Per-host port forwards. Empty for hosts that don't tunnel anything.
	/// Encoded as a regular array; legacy hosts.json files predating this
	/// field decode to `[]`.
	public var forwards: [PortForward]

	public init(id: UUID = UUID(), serverId: String? = nil,
	            name: String, hostname: String, port: Int = 22,
	            username: String, credential: CredentialSource,
	            createdAt: Date = Date(), updatedAt: Date = Date(),
	            credentialMaterialDirty: Bool = false,
	            jumpHostServerId: String? = nil,
	            forwards: [PortForward] = []) {
		self.id = id
		self.serverId = serverId
		self.name = name
		self.hostname = hostname
		self.port = port
		self.username = username
		self.credential = credential
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.credentialMaterialDirty = credentialMaterialDirty
		self.jumpHostServerId = jumpHostServerId
		self.forwards = forwards
	}

	// Explicit decoder so legacy hosts.json (no `credentialMaterialDirty`
	// or `jumpHostServerId` key) decodes successfully. Synthesized
	// init(from:) would require the keys and would fail every Plan A/B-written
	// hosts.json.
	private enum CodingKeys: String, CodingKey {
		case id, serverId, name, hostname, port, username, credential
		case createdAt, updatedAt, credentialMaterialDirty
		case jumpHostServerId
		case forwards
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
		name = try c.decode(String.self, forKey: .name)
		hostname = try c.decode(String.self, forKey: .hostname)
		port = try c.decode(Int.self, forKey: .port)
		username = try c.decode(String.self, forKey: .username)
		credential = try c.decode(CredentialSource.self, forKey: .credential)
		createdAt = try c.decode(Date.self, forKey: .createdAt)
		updatedAt = try c.decode(Date.self, forKey: .updatedAt)
		credentialMaterialDirty = try c.decodeIfPresent(Bool.self, forKey: .credentialMaterialDirty) ?? false
		jumpHostServerId = try c.decodeIfPresent(String.self, forKey: .jumpHostServerId)
		forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
	}
	// Synthesized encode(to:) is fine — it writes all keys.
}

public enum CredentialSource: Codable, Hashable {
	case password
	case keyFile(keyPath: String, hasPassphrase: Bool)
	case agent
}
