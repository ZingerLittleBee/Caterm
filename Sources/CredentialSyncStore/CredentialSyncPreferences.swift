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

/// `@unchecked Sendable`: the only non-`Sendable` stored property is the
/// `private let defaults: UserDefaults` reference. `UserDefaults` is
/// documented thread-safe, and it is immutable (`let`) here — every other
/// stored property is a value type. The unchecked conformance is therefore
/// sound; it cannot be `Sendable`-checked automatically only because
/// `UserDefaults` lacks the formal annotation.
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
    /// Bounded-retry strike counter for `decryptAndApply`, keyed by
    /// `(hostId, revision)`. MUST be durable: an in-memory-only counter
    /// resets every launch, so a permanently-undecryptable blob (e.g. the
    /// master key never arrived) would re-throw and abort the *entire*
    /// host-sync cycle on every relaunch, indefinitely — the 3-strike
    /// escape hatch (mark corrupt + advance revision) could never fire
    /// across restarts. Persisting it lets the bound survive cold start.
    public var decryptAttemptCounts: [CorruptCredentialKey: Int]

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
            self.decryptAttemptCounts = loaded.decryptAttemptCountsAsDict ?? [:]
        } else {
            self.state = .disabled
            self.lastAppliedRevision = [:]
            self.credentialsNeedFullScan = false
            self.deleteCredentialsFromCloudInProgress = nil
            self.corruptCredentials = []
            self.cloudCredentialsCleared = false
            self.hostsWithCloudPayload = []
            self.decryptAttemptCounts = [:]
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
            hostsWithCloudPayload: hostsWithCloudPayload,
            decryptAttemptCounts: decryptAttemptCounts
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // StoredShape uses [String: Int64] for lastAppliedRevision to ensure stable
    // JSON roundtrip — Swift's JSONEncoder encodes non-String-keyed dictionaries
    // as alternating [key, value, ...] arrays, which JSONDecoder cannot decode
    // back into a dictionary.
    // A `[CorruptCredentialKey: Int]` would JSON-encode as a flat
    // alternating array (CorruptCredentialKey is not a String key), which
    // doesn't round-trip reliably — store explicit entries instead, same
    // strategy as `lastAppliedRevision`/`hostsWithCloudPayload`.
    private struct StoredDecryptAttempt: Codable {
        var hostId: String
        var revision: Int64
        var count: Int
    }

    private struct StoredShape: Codable {
        var state: CredentialSyncState
        var lastAppliedRevision: [String: Int64]
        var credentialsNeedFullScan: Bool
        var deleteCredentialsFromCloudInProgress: DeletionProgress?
        var corruptCredentials: Set<CorruptCredentialKey>
        // Optional so a blob written by an older app version (no key)
        // still decodes; absent → empty (counter restarts, acceptable —
        // worst case one extra retry round before the bound re-trips).
        var decryptAttemptCounts: [StoredDecryptAttempt]?
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
            hostsWithCloudPayload: Set<UUID>,
            decryptAttemptCounts: [CorruptCredentialKey: Int]
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
            self.decryptAttemptCounts = decryptAttemptCounts.map {
                StoredDecryptAttempt(
                    hostId: $0.key.hostId.uuidString,
                    revision: $0.key.revision,
                    count: $0.value
                )
            }
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

        var decryptAttemptCountsAsDict: [CorruptCredentialKey: Int]? {
            decryptAttemptCounts.map {
                Dictionary(
                    uniqueKeysWithValues: $0.compactMap { entry in
                        UUID(uuidString: entry.hostId).map {
                            (CorruptCredentialKey(hostId: $0, revision: entry.revision), entry.count)
                        }
                    }
                )
            }
        }
    }

    // Codable conformance for the public type itself.
    private enum CodingKeys: String, CodingKey {
        case state, lastAppliedRevision, credentialsNeedFullScan
        case deleteCredentialsFromCloudInProgress, corruptCredentials
        case cloudCredentialsCleared
        case hostsWithCloudPayload
        case decryptAttemptCounts
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
        let attempts = try c.decodeIfPresent([StoredDecryptAttempt].self, forKey: .decryptAttemptCounts) ?? []
        self.decryptAttemptCounts = Dictionary(
            uniqueKeysWithValues: attempts.compactMap { entry in
                UUID(uuidString: entry.hostId).map {
                    (CorruptCredentialKey(hostId: $0, revision: entry.revision), entry.count)
                }
            }
        )
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
        try c.encode(
            decryptAttemptCounts.map {
                StoredDecryptAttempt(
                    hostId: $0.key.hostId.uuidString,
                    revision: $0.key.revision,
                    count: $0.value
                )
            },
            forKey: .decryptAttemptCounts
        )
    }

    public static func == (lhs: CredentialSyncPreferences, rhs: CredentialSyncPreferences) -> Bool {
        lhs.state == rhs.state &&
        lhs.lastAppliedRevision == rhs.lastAppliedRevision &&
        lhs.credentialsNeedFullScan == rhs.credentialsNeedFullScan &&
        lhs.deleteCredentialsFromCloudInProgress == rhs.deleteCredentialsFromCloudInProgress &&
        lhs.corruptCredentials == rhs.corruptCredentials &&
        lhs.cloudCredentialsCleared == rhs.cloudCredentialsCleared &&
        lhs.hostsWithCloudPayload == rhs.hostsWithCloudPayload &&
        lhs.decryptAttemptCounts == rhs.decryptAttemptCounts
    }
}
