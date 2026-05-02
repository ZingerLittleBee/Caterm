import Foundation

public enum CredentialSyncState: Codable, Equatable, Sendable {
    case disabled
    case enabled
    case pausedByRemote(seenTombstoneRevision: Int64)
    case waitingForKey(observedKeyID: String?)

    private enum Tag: String, Codable {
        case disabled, enabled, pausedByRemote, waitingForKey
    }
    private enum CodingKeys: String, CodingKey {
        case tag, seenTombstoneRevision, observedKeyID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .tag)
        switch tag {
        case .disabled:        self = .disabled
        case .enabled:         self = .enabled
        case .pausedByRemote:  self = .pausedByRemote(seenTombstoneRevision: try c.decode(Int64.self, forKey: .seenTombstoneRevision))
        case .waitingForKey:   self = .waitingForKey(observedKeyID: try c.decodeIfPresent(String.self, forKey: .observedKeyID))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled: try c.encode(Tag.disabled, forKey: .tag)
        case .enabled:  try c.encode(Tag.enabled, forKey: .tag)
        case .pausedByRemote(let r):
            try c.encode(Tag.pausedByRemote, forKey: .tag)
            try c.encode(r, forKey: .seenTombstoneRevision)
        case .waitingForKey(let id):
            try c.encode(Tag.waitingForKey, forKey: .tag)
            try c.encodeIfPresent(id, forKey: .observedKeyID)
        }
    }
}

public struct DeletionProgress: Codable, Equatable, Sendable {
    public var pendingLocalHostIds: [UUID]
    public init(pendingLocalHostIds: [UUID]) { self.pendingLocalHostIds = pendingLocalHostIds }
}

public struct CorruptCredentialKey: Codable, Hashable, Sendable {
    public let hostId: UUID
    public let revision: Int64
    public init(hostId: UUID, revision: Int64) {
        self.hostId = hostId
        self.revision = revision
    }
}

public struct CredentialSyncPreferences: Codable, Equatable, @unchecked Sendable {
    public var state: CredentialSyncState
    public var lastAppliedRevision: [UUID: Int64]
    public var credentialsNeedFullScan: Bool
    public var deleteCredentialsFromCloudInProgress: DeletionProgress?
    public var corruptCredentials: Set<CorruptCredentialKey>

    private static let storageKey = "catermCredentialSyncPreferences"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let loaded = try? JSONDecoder().decode(StoredShape.self, from: data) {
            self.state = loaded.state
            self.lastAppliedRevision = loaded.lastAppliedRevisionAsUUID
            self.credentialsNeedFullScan = loaded.credentialsNeedFullScan
            self.deleteCredentialsFromCloudInProgress = loaded.deleteCredentialsFromCloudInProgress
            self.corruptCredentials = loaded.corruptCredentials
        } else {
            self.state = .disabled
            self.lastAppliedRevision = [:]
            self.credentialsNeedFullScan = false
            self.deleteCredentialsFromCloudInProgress = nil
            self.corruptCredentials = []
        }
    }

    public func save() {
        let stored = StoredShape(
            state: state,
            lastAppliedRevision: lastAppliedRevision,
            credentialsNeedFullScan: credentialsNeedFullScan,
            deleteCredentialsFromCloudInProgress: deleteCredentialsFromCloudInProgress,
            corruptCredentials: corruptCredentials
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // StoredShape uses [String: Int64] for lastAppliedRevision to ensure stable
    // JSON roundtrip — Swift's JSONEncoder encodes non-String-keyed dictionaries
    // as alternating [key, value, ...] arrays, which JSONDecoder cannot decode
    // back into a dictionary.
    private struct StoredShape: Codable {
        var state: CredentialSyncState
        var lastAppliedRevision: [String: Int64]
        var credentialsNeedFullScan: Bool
        var deleteCredentialsFromCloudInProgress: DeletionProgress?
        var corruptCredentials: Set<CorruptCredentialKey>

        init(
            state: CredentialSyncState,
            lastAppliedRevision: [UUID: Int64],
            credentialsNeedFullScan: Bool,
            deleteCredentialsFromCloudInProgress: DeletionProgress?,
            corruptCredentials: Set<CorruptCredentialKey>
        ) {
            self.state = state
            self.lastAppliedRevision = Dictionary(
                uniqueKeysWithValues: lastAppliedRevision.map { ($0.key.uuidString, $0.value) }
            )
            self.credentialsNeedFullScan = credentialsNeedFullScan
            self.deleteCredentialsFromCloudInProgress = deleteCredentialsFromCloudInProgress
            self.corruptCredentials = corruptCredentials
        }

        var lastAppliedRevisionAsUUID: [UUID: Int64] {
            Dictionary(
                uniqueKeysWithValues: lastAppliedRevision.compactMap { k, v in
                    UUID(uuidString: k).map { ($0, v) }
                }
            )
        }
    }

    // Codable conformance for the public type itself.
    private enum CodingKeys: String, CodingKey {
        case state, lastAppliedRevision, credentialsNeedFullScan
        case deleteCredentialsFromCloudInProgress, corruptCredentials
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.defaults = .standard
        self.state = try c.decode(CredentialSyncState.self, forKey: .state)
        let stringKeyed = try c.decode([String: Int64].self, forKey: .lastAppliedRevision)
        self.lastAppliedRevision = Dictionary(
            uniqueKeysWithValues: stringKeyed.compactMap { k, v in
                UUID(uuidString: k).map { ($0, v) }
            }
        )
        self.credentialsNeedFullScan = try c.decode(Bool.self, forKey: .credentialsNeedFullScan)
        self.deleteCredentialsFromCloudInProgress = try c.decodeIfPresent(DeletionProgress.self, forKey: .deleteCredentialsFromCloudInProgress)
        self.corruptCredentials = try c.decode(Set<CorruptCredentialKey>.self, forKey: .corruptCredentials)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        let stringKeyed = Dictionary(
            uniqueKeysWithValues: lastAppliedRevision.map { ($0.key.uuidString, $0.value) }
        )
        try c.encode(stringKeyed, forKey: .lastAppliedRevision)
        try c.encode(credentialsNeedFullScan, forKey: .credentialsNeedFullScan)
        try c.encodeIfPresent(deleteCredentialsFromCloudInProgress, forKey: .deleteCredentialsFromCloudInProgress)
        try c.encode(corruptCredentials, forKey: .corruptCredentials)
    }

    public static func == (lhs: CredentialSyncPreferences, rhs: CredentialSyncPreferences) -> Bool {
        lhs.state == rhs.state &&
        lhs.lastAppliedRevision == rhs.lastAppliedRevision &&
        lhs.credentialsNeedFullScan == rhs.credentialsNeedFullScan &&
        lhs.deleteCredentialsFromCloudInProgress == rhs.deleteCredentialsFromCloudInProgress &&
        lhs.corruptCredentials == rhs.corruptCredentials
    }
}
