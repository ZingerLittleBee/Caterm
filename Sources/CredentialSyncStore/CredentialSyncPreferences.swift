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
    /// Set true when the destructive sub-pipeline finishes pushing every
    /// host's tombstone (cloud now has no payloads). Reset to false on the
    /// next successful credential payload push from this device. Drives the
    /// post-deletion UI: hides the "Delete from iCloud" button and changes
    /// the status row copy so the user isn't told "5 hosts synced" when
    /// every cloud blob is a tombstone.
    public var cloudCredentialsCleared: Bool
    /// Local hosts whose cloud blob is, from this device's last-known view,
    /// a `.payload` (not a `.tombstone`). Push payload → insert; push or
    /// observe tombstone → remove. The status row's "N hosts synced" count
    /// derives from this set rather than `lastAppliedRevision > 0`, since
    /// the latter incorrectly counts hosts whose blob was tombstoned (the
    /// revision is bumped past 0 by the tombstone push too).
    public var hostsWithCloudPayload: Set<UUID>

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
            self.cloudCredentialsCleared = loaded.cloudCredentialsCleared ?? false
            self.hostsWithCloudPayload = loaded.hostsWithCloudPayloadAsUUID ?? []
        } else {
            self.state = .disabled
            self.lastAppliedRevision = [:]
            self.credentialsNeedFullScan = false
            self.deleteCredentialsFromCloudInProgress = nil
            self.corruptCredentials = []
            self.cloudCredentialsCleared = false
            self.hostsWithCloudPayload = []
        }
    }

    public func save() {
        let stored = StoredShape(
            state: state,
            lastAppliedRevision: lastAppliedRevision,
            credentialsNeedFullScan: credentialsNeedFullScan,
            deleteCredentialsFromCloudInProgress: deleteCredentialsFromCloudInProgress,
            corruptCredentials: corruptCredentials,
            cloudCredentialsCleared: cloudCredentialsCleared,
            hostsWithCloudPayload: hostsWithCloudPayload
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
        // Optional so a UserDefaults blob written by an older app version
        // (no `cloudCredentialsCleared` key) still decodes successfully on
        // upgrade. Treated as `false` when absent.
        var cloudCredentialsCleared: Bool?
        // Stored as [String] (UUID strings) for stable JSON round-trip.
        // Optional so legacy blobs without this key still decode — they
        // upgrade with an empty set; the next push or pull repopulates.
        var hostsWithCloudPayload: [String]?

        init(
            state: CredentialSyncState,
            lastAppliedRevision: [UUID: Int64],
            credentialsNeedFullScan: Bool,
            deleteCredentialsFromCloudInProgress: DeletionProgress?,
            corruptCredentials: Set<CorruptCredentialKey>,
            cloudCredentialsCleared: Bool,
            hostsWithCloudPayload: Set<UUID>
        ) {
            self.state = state
            self.lastAppliedRevision = Dictionary(
                uniqueKeysWithValues: lastAppliedRevision.map { ($0.key.uuidString, $0.value) }
            )
            self.credentialsNeedFullScan = credentialsNeedFullScan
            self.deleteCredentialsFromCloudInProgress = deleteCredentialsFromCloudInProgress
            self.corruptCredentials = corruptCredentials
            self.cloudCredentialsCleared = cloudCredentialsCleared
            self.hostsWithCloudPayload = hostsWithCloudPayload.map(\.uuidString)
        }

        var lastAppliedRevisionAsUUID: [UUID: Int64] {
            Dictionary(
                uniqueKeysWithValues: lastAppliedRevision.compactMap { k, v in
                    UUID(uuidString: k).map { ($0, v) }
                }
            )
        }

        var hostsWithCloudPayloadAsUUID: Set<UUID>? {
            hostsWithCloudPayload.map { Set($0.compactMap(UUID.init(uuidString:))) }
        }
    }

    // Codable conformance for the public type itself.
    private enum CodingKeys: String, CodingKey {
        case state, lastAppliedRevision, credentialsNeedFullScan
        case deleteCredentialsFromCloudInProgress, corruptCredentials
        case cloudCredentialsCleared
        case hostsWithCloudPayload
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
        self.cloudCredentialsCleared = try c.decodeIfPresent(Bool.self, forKey: .cloudCredentialsCleared) ?? false
        let payloadStrings = try c.decodeIfPresent([String].self, forKey: .hostsWithCloudPayload)
        self.hostsWithCloudPayload = Set((payloadStrings ?? []).compactMap(UUID.init(uuidString:)))
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
        try c.encode(cloudCredentialsCleared, forKey: .cloudCredentialsCleared)
        try c.encode(hostsWithCloudPayload.map(\.uuidString), forKey: .hostsWithCloudPayload)
    }

    public static func == (lhs: CredentialSyncPreferences, rhs: CredentialSyncPreferences) -> Bool {
        lhs.state == rhs.state &&
        lhs.lastAppliedRevision == rhs.lastAppliedRevision &&
        lhs.credentialsNeedFullScan == rhs.credentialsNeedFullScan &&
        lhs.deleteCredentialsFromCloudInProgress == rhs.deleteCredentialsFromCloudInProgress &&
        lhs.corruptCredentials == rhs.corruptCredentials &&
        lhs.cloudCredentialsCleared == rhs.cloudCredentialsCleared &&
        lhs.hostsWithCloudPayload == rhs.hostsWithCloudPayload
    }
}
