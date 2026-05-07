import Foundation

/// One row of `sshHost.list`. Mirrors `packages/api/src/routers/ssh-host.ts`
/// (the metadata-only projection — no password/privateKey/keyPassphrase columns).
public struct RemoteHost: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authType: String        // "password" | "key" — Swift v1.1 ignores
    public let createdAt: Date
    public let updatedAt: Date
    public let jumpHostServerId: String?

    public init(id: String, name: String, hostname: String, port: Int,
                username: String, authType: String, createdAt: Date, updatedAt: Date,
                jumpHostServerId: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = authType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.jumpHostServerId = jumpHostServerId
    }
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

    public init(name: String, hostname: String, port: Int, username: String,
                jumpHostServerId: String? = nil) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = "key"
        self.jumpHostServerId = jumpHostServerId
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

    public init(id: String, name: String? = nil, hostname: String? = nil,
                port: Int? = nil, username: String? = nil,
                jumpHostServerId: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        // Always pass authType="key" placeholder when updating to keep the
        // server row consistent with how we created it.
        self.authType = "key"
        self.jumpHostServerId = jumpHostServerId
    }
}

public struct RemoteHostCreateOutput: Codable, Equatable {
    public let id: String
    public init(id: String) { self.id = id }
}
