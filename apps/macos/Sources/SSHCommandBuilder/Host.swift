import Foundation

public struct Host: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var credential: CredentialSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22,
                username: String, credential: CredentialSource,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.credential = credential
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum CredentialSource: Codable, Hashable {
    case password
    case keyFile(keyPath: String, hasPassphrase: Bool)
    case agent
}
