import Foundation
import SSHCommandBuilder

/// One row of `sshHost.list`. Mirrors `packages/api/src/routers/ssh-host.ts`
/// (the metadata-only projection — no password/privateKey/keyPassphrase columns).
public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authType: String        // "password" | "key" — Swift v1.1 ignores
    public let createdAt: Date
    public let updatedAt: Date
    public let jumpHostServerId: String?
    public let forwards: [PortForward]
    /// User-chosen SF Symbol name. Synced metadata (device-visible only;
    /// nil = use the credential-derived default icon). Legacy payloads with
    /// no `icon` key decode to nil.
    public let icon: String?

    public init(id: String, name: String, hostname: String, port: Int,
                username: String, authType: String, createdAt: Date, updatedAt: Date,
                jumpHostServerId: String? = nil,
                forwards: [PortForward] = [],
                icon: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = authType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.jumpHostServerId = jumpHostServerId
        self.forwards = forwards
        self.icon = icon
    }

    // Explicit decoder so legacy server payloads (no `forwards` column —
    // e.g. self-hosted servers that haven't migrated yet) decode successfully.
    // Synthesized init(from:) would treat `forwards` as required and crash
    // every pull from a current production server (spec §7.1.x forward-compat).
    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, authType
        case createdAt, updatedAt, jumpHostServerId, forwards, icon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authType = try c.decode(String.self, forKey: .authType)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        jumpHostServerId = try c.decodeIfPresent(String.self, forKey: .jumpHostServerId)
        forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }
    // Synthesized encode(to:) is fine — it writes all keys.
}

/// Payload for `sshHost.create`. Per spec §7.1.2, Swift v1.1 always sends
/// `authType = "key"` as a constant placeholder and never sends credential
/// columns.
public struct RemoteHostCreateInput: Codable {
    public let name: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authType: String
    public let jumpHostServerId: String?
    public let forwards: [PortForward]
    public let icon: String?

    public init(name: String, hostname: String, port: Int, username: String,
                jumpHostServerId: String? = nil,
                forwards: [PortForward] = [],
                icon: String? = nil) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = "key"
        self.jumpHostServerId = jumpHostServerId
        self.forwards = forwards
        self.icon = icon
    }
}

/// Payload for `sshHost.update`. id required, other fields optional. Same
/// credential discipline: never include password/privateKey/keyPassphrase.
public struct RemoteHostUpdateInput: Codable {
    public let id: String
    public let name: String?
    public let hostname: String?
    public let port: Int?
    public let username: String?
    public let authType: String?
    public let jumpHostServerId: String?
    public let forwards: [PortForward]?
    public let icon: String?

    public init(id: String, name: String? = nil, hostname: String? = nil,
                port: Int? = nil, username: String? = nil,
                jumpHostServerId: String? = nil,
                forwards: [PortForward]? = nil,
                icon: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        // Always pass authType="key" placeholder when updating to keep the
        // server row consistent with how we created it.
        self.authType = "key"
        self.jumpHostServerId = jumpHostServerId
        self.forwards = forwards
        self.icon = icon
    }
}

public struct RemoteHostCreateOutput: Codable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}
