# Plan C — CloudKit Keychain Sync (SSH Credentials)

**Date:** 2026-05-02
**Status:** Design approved (post-review revision), awaiting implementation plan
**Predecessors:**
- [Plan A — CloudKit Host Sync](../plans/2026-05-02-cloudkit-host-sync.md) (complete, commit `40fef64`)
- [Plan B — CloudKit Push Subscriptions](2026-05-02-cloudkit-push-subscriptions-design.md) (complete, commit `ca5b312`)

## Goal

Sync SSH credentials (passwords, key passphrases, private key file content) end-to-end encrypted across the user's iCloud-signed-in Macs so that adding a host on Mac A makes it immediately usable on Mac B without re-entering secrets or pre-staging the key file. **"Apple cannot decrypt" must hold by default — without depending on the user enabling Advanced Data Protection.**

## Non-goals

- `known_hosts` (server fingerprint) sync — SSH's trust-on-first-use is already correct; cross-device fingerprint propagation creates phantom MITM warnings when machines see different network paths.
- Continuous file-watching of the user's source key file (e.g., `~/.ssh/id_rsa`) — credential bytes are captured at host add/edit time. To pick up an out-of-band rotation, the user re-imports via the host edit form.
- Writing private keys into `~/.ssh/` — Caterm's managed keys live under `~/Library/Application Support/Caterm/keys/` to avoid colliding with user-owned ssh state.
- Cross-iCloud-account migration / standalone credential export / credential backup features.
- Per-host opt-in for credential sync. v1 is a single per-device toggle plus an account-level destructive action; per-host granularity may be added later if real users ask for it.
- Master-key rotation. The schema reserves `credentialKeyID` and `credentialCryptoVersion` for future rotation but v1 has exactly one master key per account.
- A "make this Mac authoritative" UI on every state transition. The "push local over cloud" action is mentioned as a future explicit affordance but is not on the v1 critical path; v1 ships with toggle ON defaulting to pull-from-cloud.

## Why

Plan A synced host metadata only (intentionally). New devices receive hosts but trigger `CredentialSetupView` on first connect — the user must re-enter every password and re-pick every key file. For password-auth hosts that's annoying; for key-auth hosts it's worse: if the new Mac doesn't already have the right private key file at the same path, the host can't connect at all. "Seamless" requires the key bytes to travel.

## Architecture: application-layer envelope encryption

`CKRecord.encryptedValues` was rejected (despite Plan C's earlier draft using it): Apple's iCloud data security overview is explicit that CloudKit encrypted fields are end-to-end encrypted **only when Advanced Data Protection is enabled**. Under Standard Data Protection (the default for >95% of users), Apple holds the field-encryption keys and can decrypt. SSH private keys are sensitive enough that the spec must promise unconditional E2E.

**Plan C therefore performs encryption in the app, not on the CKRecord.**

```
┌──────────────────────────┐                   ┌──────────────────────────┐
│ Mac A — caterm           │                   │ Mac B — caterm           │
│                          │                   │                          │
│  Local Keychain          │                   │  Local Keychain          │
│  ManagedKeyStore         │                   │  ManagedKeyStore         │
│   ↓ encrypt with         │                   │   ↑ decrypt with         │
│  AES.GCM(masterKey, AAD) │                   │  AES.GCM(masterKey, AAD) │
│   ↓                      │                   │   ↑                      │
│  CKRecord ciphertext ────┼───── CloudKit ────┼──→ CKRecord ciphertext   │
│                          │   (no key access) │                          │
│  iCloud Keychain ────────┼─────  E2E by ─────┼──→ iCloud Keychain       │
│  master key (synced)     │     default       │  master key (synced)     │
└──────────────────────────┘                   └──────────────────────────┘
```

**Master key**: a 32-byte symmetric key, generated on first opt-in, stored as a `kSecAttrSynchronizable=true` generic password Keychain item. iCloud Keychain syncs it end-to-end across the user's trusted devices using its own key escrow — Apple **cannot** access these items, regardless of ADP state. (Apple's iCloud Keychain has been E2E since 2014.)

**Ciphertext**: each credential field is sealed with AES-GCM and stored as a regular `Data` field on the existing `Host` CKRecord. Apple sees only opaque bytes.

**Single sync path**: iCloud Keychain stores **one** wrapping key (~40 bytes including metadata). All credential payloads flow through CloudKit. This is not the "two parallel sync paths" complexity that earlier draft worried about — it's classic envelope encryption: a key-store plus a data-store, separated by responsibility.

## Cryptography

| Element | Choice |
|---------|--------|
| Symmetric algorithm | AES-256-GCM via `CryptoKit.AES.GCM` |
| Master key | 32 bytes random (`SymmetricKey(size: .bits256)`) |
| Master key persistence | `kSecClassGenericPassword`, `kSecAttrSynchronizable=true`, `kSecAttrAccessible=kSecAttrAccessibleWhenUnlocked` (Apple's only constraint on synchronizable items is that they must NOT use any `*ThisDeviceOnly` accessibility class; `WhenUnlocked` is permitted and preferred — it scopes master-key access to an unlocked device, which matches every code path that needs it) |
| Master key service / account | service `com.caterm.cloudkit-sync.masterKey`, account `<credentialKeyID UUID>` |
| Ciphertext format | `AES.GCM.SealedBox.combined` (12-byte nonce ‖ ciphertext ‖ 16-byte tag) |
| Per-message nonce | random per-encrypt (handled by `CryptoKit.AES.GCM.seal`) |
| AAD (authenticated additional data, **not** encrypted but bound) | UTF-8 of `"\(serverId)|\(fieldKind)|\(credentialBlobRevision)|\(schemaVersion)"` where `serverId` is the CKRecord's `recordName` (the only host identifier that's stable across devices), `fieldKind ∈ {"password", "passphrase", "privateKey"}`, and `schemaVersion = 1` for v1 |
| Algorithm versioning | `credentialCryptoVersion: Int64` field on the CKRecord. v1 = 1. Future bumps for KDF / cipher migration. |

**AAD binding rationale**: prevents replay of one host's ciphertext as another host's, swapping `password` ciphertext into the `privateKey` slot, and replaying old revisions over newer ones. Any of those mismatches → `AES.GCM.open` throws → handled per §Failure modes.

**Why `serverId`, not local `host.id`**: `SessionStore.addRemoteHost` (`SessionStore.swift:298`) allocates a fresh local `UUID()` for every host pulled from the server, so Mac A and Mac B hold different `host.id` for the same logical host. `host.serverId` (set from the CKRecord's `recordName`) is the only cross-device-stable identifier. Encrypting with local UUID would guarantee Mac B's `AES.GCM.open` fails with AAD mismatch — exactly the bug review #1 caught.

**Push gating consequence**: a host without a `serverId` (i.e., never reached the server yet) cannot have its credentials pushed — there's no stable AAD to bind. The mechanism is in §Push rules: HostSyncStore queues `.updateRemoteCredentials` after the reconciler's `.createRemote / .updateRemote / …` ops on every cycle, but the credential op's executor checks `host.serverId` at runtime. If `.createRemote` succeeded earlier in the same cycle, `serverId` is now populated and the credential push proceeds; if `.createRemote` failed or wasn't emitted, the executor no-ops without throwing and the dirty bit survives for next cycle. This produces the natural "create record, then add credential payload" ordering automatically without a special "wait for serverId" branch.

**No KDF / no per-host subkey** for v1: a single master key encrypts all credentials. The AAD provides the per-message domain separation. Future versions can introduce per-record subkeys via HKDF if needed, gated by `credentialCryptoVersion`.

## Data model

### `Host` CKRecord — new fields

```
passwordCiphertext       : Data?     // AES.GCM SealedBox.combined; nil if no payload
passphraseCiphertext     : Data?
privateKeyCiphertext     : Data?
credentialBlobState      : String    // "none" | "payload" | "tombstone"
credentialBlobRevision   : Int64     // monotonic; default 0
credentialKeyID          : String?   // UUID of master key that sealed these (nil when state == "none")
credentialCryptoVersion  : Int64     // 1 in v1
metadataUpdatedAt        : Date?     // app-controlled metadata change timestamp (replaces decode-time use of CKRecord.modificationDate)
```

Schema is forward-compatible: old (Plan A/B) clients ignore unknown fields; absent fields decode to nil / "" / 0.

### Why `metadataUpdatedAt` is a separate field (review #1)

Plan A's `CKRecordHostMapping.decode` maps `updatedAt = rec.modificationDate ?? .distantPast` (`CKRecordHostMapping.swift:39`). `CKRecord.modificationDate` is a server-controlled timestamp that Apple bumps on **every** save of the record — including credential-only saves via `applyCredentialBlob`. Without a separate field, a credential rotation on Mac A would be observed by Mac B as a metadata change (newer `updatedAt`), causing the reconciler to emit a spurious `.updateLocal` op and corrupting LWW behavior on concurrent metadata + credential edits.

Plan C therefore introduces an **app-controlled** `metadataUpdatedAt: Date` field:
- `applyMetadata(into existing: CKRecord, from host: SSHHost)` writes `existing["metadataUpdatedAt"] = host.updatedAt as CKRecordValue` along with the other metadata fields.
- `applyCredentialBlob(into existing: CKRecord, blob:)` **never** touches this field (already guaranteed by the partial-encoder split — credential encoder physically cannot reach metadata fields).
- `decode(record:)` reads `updatedAt = rec["metadataUpdatedAt"] as? Date ?? rec.modificationDate ?? rec.creationDate ?? .distantPast`. **The fallback chain is `metadataUpdatedAt → modificationDate → creationDate`** (review #1''' / fourth pass). Falling back to `creationDate` alone, as the previous draft did, is unsafe: a Plan A record created at `t0` and edited at `t2` would decode as `updatedAt = t0`, and a stale local copy at `t1 < t2` would erroneously beat the cloud's `t2` in LWW. `modificationDate` is Plan A's actual LWW clock, so reading it as the fallback preserves Plan A's pre-existing semantics for any record that hasn't been touched by a Plan C `applyCredentialBlob` save yet (see §Seed-before-credential-save below for why this fallback can never read a `modificationDate` that's been contaminated by credential-only writes).
- `makeRecord(input:)` initializes `metadataUpdatedAt = Date()` — the create itself is the first metadata write.
- Schema-deploy adds `metadataUpdatedAt: Date(Indexed: false)` to the production CKRecord schema (Plan E pre-ship task).

### Seed-before-credential-save (legacy migration, review #1''' / fourth pass)

The `applyCredentialBlob` save bumps server-side `modificationDate`. If a Plan C client did a credential-only save on a legacy Plan A record before that record's `metadataUpdatedAt` was populated, the decoder's fallback would later read a `modificationDate` that no longer reflects the metadata clock — exactly the contamination Plan C set out to prevent. To eliminate that window, the `.updateRemoteCredentials` executor adopts a one-time-per-record seed step:

```
on .updateRemoteCredentials(localHostId):
    let host = sessionStore.host(by: localHostId)
    guard let serverId = host.serverId else { return /* no-op per executor-time check */ }

    let existing = try await client.fetchRecord(serverId, in: zoneID)

    // Seed metadataUpdatedAt for legacy records BEFORE the credential-only
    // save bumps modificationDate. After this seed save, the field reflects
    // the pre-Plan-C metadata clock and is safe to read on every device.
    if existing["metadataUpdatedAt"] == nil {
        let seed = (existing.modificationDate ?? existing.creationDate ?? Date.distantPast)
        existing["metadataUpdatedAt"] = seed as CKRecordValue
    }

    // Same save also applies the credential blob — single CKRecord save
    // so the seed and the first credential write are atomic on the server.
    applyCredentialBlob(into: existing, blob: encryptedBlob(for: host))
    try await client.save(existing)

    await sessionStore.clearCredentialMaterialDirty(localHostId)
```

Records also get `metadataUpdatedAt` written via the metadata path: any Plan C client whose `.updateRemote` op runs against a legacy record will execute `applyMetadata`, which sets `metadataUpdatedAt = host.updatedAt`. Across the fleet, every record migrates the moment any Plan C client either edits its metadata or first pushes credentials for it. Records that are never touched by any Plan C client retain the `modificationDate → creationDate` fallback in decode and continue to behave per Plan A semantics indefinitely.

### Decode-time invariant

For any record visible to a Plan C decoder, the value read as `updatedAt` is exactly one of:
1. `metadataUpdatedAt` populated by Plan C's `makeRecord`, `applyMetadata`, or the seed step above. **This is always uncontaminated** by credential-only saves because:
   - `makeRecord` only runs at create time.
   - `applyMetadata` writes it deliberately to the new metadata clock.
   - The seed step writes the pre-Plan-C `modificationDate` (sampled before the credential-only save's modificationDate bump applies on the server — the seed assignment is part of the same client-side CKRecord modification that gets sent in one save).
2. Fallback `modificationDate` for records never touched by any Plan C save. **Uncontaminated** by definition: no Plan C client has done a credential-only save on this record yet, so `modificationDate` still reflects the last metadata-content change exactly as Plan A intended.
3. Fallback `creationDate` if the record somehow has no `modificationDate` (CloudKit ought to set it on every save, but the optional API leaves us defensive).

### Field semantics

| `credentialBlobState` | `credentialBlobRevision` | Ciphertext fields | Meaning |
|----------------------|--------------------------|-------------------|---------|
| absent or `"none"` | 0 (initial) or any | all nil | **No credential payload.** Either: never had sync touch this record (Plan A baseline), or this host's `CredentialSource` is `.agent` (no syncable secret), or the user's source key file was missing at push time and password/passphrase are also absent. |
| `"payload"` | > 0 | at least one non-nil | Credential ciphertext is authoritative as of `credentialBlobRevision`. Decrypt with master key matching `credentialKeyID`. |
| `"tombstone"` | > 0 | all nil (enforced by writer) | Credential sync was explicitly **deleted from iCloud** by some device. Other devices observing this transition to `pausedByRemote`. |

Crucially, `state="none"` is **distinct from** `state="tombstone"`. The earlier spec draft conflated "all ciphertext nil" with tombstone, which would have falsely tombstoned every `.agent` host. The explicit state field eliminates that ambiguity.

### `CredentialSource` enum — unchanged at type level

```swift
enum CredentialSource {
    case password
    case keyFile(keyPath: String, hasPassphrase: Bool)
    case agent
}
```

The enum still describes "what kind of credential this host uses". `keyPath` remains "where to find the key file on **this** Mac". hosts.json on Mac A and Mac B can legally have different `keyPath` values for the same host.

### `CredentialSource` is mutated by pull (this is new)

`SessionStore.addRemoteHost(_:)` defaults incoming hosts to `.password` (`SessionStore.swift:298`). Before Plan C nothing else mutated `host.credential` for synced hosts. Plan C adds: when the pull side decrypts a `Host` record and the decrypted payload contains private key bytes, the receiving Mac **must** flip its local `host.credential` from `.password` to `.keyFile(managedPath, hasPassphrase: blob.hasPassphrase)`. A new `SessionStore.applyRemoteCredential(blob:for:)` API does this atomically with the Keychain + ManagedKeyStore writes (its mechanics are detailed under §Pull rules and §Credential-mutation entry point). The pre-Plan-C internal helper `setCredentialOnly(_:for:)` is folded into the new entry-point API; it does not remain a public surface in v1 of Plan C.

### KeychainStore — unchanged

Continues to use service `com.caterm.host`, accounts `<hostId>.<kind>`, access group `caterm.shared`, accessibility `kSecAttrAccessibleWhenUnlocked`, **`kSecAttrSynchronizable=false`**. iCloud Keychain stores only the master key, not the credentials themselves.

### `ManagedKeyStore` — new module

`apps/macos/Sources/ManagedKeyStore/ManagedKeyStore.swift`.

```swift
public actor ManagedKeyStore {
    public init(rootURL: URL = .applicationSupport.appending("Caterm/keys"))

    /// Atomically writes bytes to keys/<hostId>; returns the URL.
    /// Implementation: write to `<rootURL>/.tmp.<hostId>.<rand>`, fsync,
    /// `rename(tmp, target)`. POSIX `rename(2)` is atomic and replaces an
    /// existing target — no separate delete-before-write is required.
    /// A mid-write crash leaves either the old file or the new file intact
    /// (never a half-written file at `target`). Concurrent calls to
    /// `write` for the same hostId are serialized by the actor.
    public func write(hostId: UUID, bytes: Data) throws -> URL

    public func read(hostId: UUID) -> Data?
    public func delete(hostId: UUID)                 // idempotent
    public func path(hostId: UUID) -> URL            // computed; file may not exist
}
```

**Filesystem hardening (mandatory):**
- Root directory created with mode `0o700`.
- Each file written with mode `0o600`.
- Atomic write: `O_CREAT | O_EXCL | O_WRONLY` to a tmp path inside the root, fsync, `rename(tmp, target)`. Atomic replace of an existing target is intended (review #4) — pull-side apply must be able to deliver successive remote private-key updates for the same host without an extra delete step.
- **Reject** any path that resolves (after `realpath`) outside `rootURL`. Reject paths containing `..` or symlinks. The tmp path generation never accepts user-provided strings — `<rand>` is `UInt64` from `SystemRandomNumberGenerator`. The `rename` target is computed from `hostId.uuidString` only.
- **Reject** writes larger than `1_000_000` bytes (1 MB). Plain CKRecord `Data` fields are limited to ~1 MB by CloudKit; larger payloads would fail server-side anyway. ed25519 keys are ~400 bytes; even RSA-4096 PEM is ~3.3 KB, so this cap is generous.
- File ownership: current user. Caterm runs unsandboxed in its dev configuration (Plan A's status); when sandbox is enabled later (Plan E), the path remains valid because Application Support is inside the app's container.

### `KeychainSyncMasterKeyStore` — new module

`apps/macos/Sources/CredentialSync/KeychainSyncMasterKeyStore.swift`. Wraps the synchronizable Keychain item with explicit "is iCloud Keychain reachable?" semantics.

```swift
public actor KeychainSyncMasterKeyStore {
    public func loadAny() async -> (keyID: String, key: SymmetricKey)?
    public func load(keyID: String) async -> SymmetricKey?
    public func generate() async throws -> (keyID: String, key: SymmetricKey)
    /// Writes synchronizable=true. Sync to peer devices is iCloud Keychain's job.
    public func remove(keyID: String) async                    // best-effort
}
```

### Per-device sync state — `CredentialSyncPreferences`

Stored in `SyncPreferences`. Four states:

```swift
enum CredentialSyncState {
    case disabled                                     // toggle off; default
    case enabled                                      // toggle on AND master key locally available
    case pausedByRemote(seenTombstoneRevision: Int64) // received tombstone push from peer
    case waitingForKey(observedKeyID: String?)        // toggle on but master key not in local Keychain yet
}
```

Plus the following persisted fields (also in `SyncPreferences` JSON):
- `lastAppliedRevision: [UUID: Int64]` — per-host high-water mark for incoming.
- `credentialsNeedFullScan: Bool` — set true on every transition into `.enabled`. Consumed by `HostSyncStore` at the start of the next sync cycle, which forces that cycle to use `.forceFull` regardless of `preferredHostSyncMode`'s default. Cleared after the forceFull pass commits its checkpoint successfully. **Must persist across crashes / restarts**: if the user toggles ON and quits before the next sync, the flag stays on disk so the next launch's first sync still picks it up. (See §Toggle ON full-snapshot fix for why this is necessary — review #2.)
- `deleteCredentialsFromCloudInProgress: DeletionProgress?` — durable record of an in-flight destructive "Delete from iCloud" action (review #2''' / fourth pass). Non-nil while the operation is mid-flight. Suppresses the dirty scan and credential push pipeline entirely until cleared. Crash-resumable: see §Destructive deletion flow.

```swift
struct DeletionProgress: Codable {
    /// Local host IDs whose tombstone push has not yet succeeded for
    /// this destructive action. Decreases monotonically as each
    /// tombstone push lands and lastAppliedRevision is updated.
    /// Empty array → operation complete; HostSyncStore clears the
    /// outer Optional to nil and resumes normal pipeline.
    var pendingLocalHostIds: [UUID]
}
```

### Per-host dirty bit — new field on `SSHHost`

```swift
public struct Host: Codable, Identifiable, Hashable {
    // … existing fields (id, serverId, name, hostname, port, username, credential, createdAt, updatedAt) …
    public var credentialMaterialDirty: Bool = false  // NEW (Plan C)

    // Backward-compatible decode (review #3): a synthesized Codable would
    // require the new key to be present and would fail to decode any
    // hosts.json written by a Plan A/B build. We therefore replace the
    // synthesized init with an explicit one that uses decodeIfPresent for
    // the new field; existing fields are decoded normally.
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
        credentialMaterialDirty =
            try c.decodeIfPresent(Bool.self, forKey: .credentialMaterialDirty) ?? false
    }
    // The synthesized encode(to:) is fine — it writes the new field, which
    // older binaries silently ignore on decode (Foundation JSONDecoder
    // already skips unknown keys for non-strict containers).
}
```

Persisted into `hosts.json` via the existing `HostPersistence` codec. Set to `true` whenever the user mutates credential material locally (password / passphrase / private-key bytes change); cleared by `HostSyncStore` after a successful `.updateRemoteCredentials` push for that host. The dirty bit is **the** durable source of "this host has credential material that may need to be pushed" — it survives crashes, offline gaps, and the host's `serverId` not yet existing. (See §Credential-mutation entry point and §Sync flow integration for how it's read and cleared — review #1.)

**Forward compatibility into Plan A/B**: the `encode(to:)` (synthesized) writes the new key; older Plan A/B builds reading a hosts.json written by a Plan C build use their own synthesized `init(from:)` which would fail on extra keys via `KeyDecodingStrategy.useDefaultKeys`. In practice `JSONDecoder` skips keys not declared in `CodingKeys` of the target struct, so the older build silently ignores the field and round-trips it out via re-save. **However, downgrade is not a supported path** — once a user runs a Plan C build, downgrading to Plan A/B and saving over hosts.json would drop the dirty bit. This is acceptable because Plan C ships forward-only.

## State machine

```
                        toggle ON
              ┌──── (no payload in cloud, ────┐ generate master key
              │      no master key)           │ → enabled
              ▼                               │
    ╔════════════════╗                        │
    ║   disabled     ║◄───────────────────────┤
    ╚════════════════╝          toggle OFF    │
              ▲                               │
              │                               │
              │ toggle OFF                    │
              │                               │
              │                  toggle ON    │
              │            (cloud has payload │
              │             AND master key in │
              │             local iCloud kc)  │
              │              ┌────────────────┴──────────┐
              │              ▼                           │
              │   ╔═════════════════════╗                │
              │   ║ waitingForKey       ║                │
              │   ╚═════════════════════╝                │
              │              │                           │
              │              │ master key arrives        │
              │              │ via iCloud Keychain       │
              │              ▼                           │
              │   ╔═════════════════════╗                │
              ├───║   enabled           ║────────────────┤
              │   ╚═════════════════════╝                │
              │              │                           │
              │              │ peer ran the destructive  │
              │              │ "Delete from iCloud"      │
              │              │ → tombstone in cloud      │
              │              ▼                           │
              │   ╔═════════════════════╗                │
              └───║ pausedByRemote      ║                │
                  ╚═════════════════════╝────────────────┘
                              ▲       │ toggle ON re-enables;
                              │       ▼ defaults to pull cloud state
                              │
                              └── toggle OFF (no further side effects)
```

### Push rules

Triggered by HostSyncStore's per-cycle dirty scan over `sessionStore.hosts.credentialMaterialDirty`, populated by `SessionStore.setHostCredentialMaterial(...)` (the single credential-mutation entry point used by host form add / edit and `CredentialSetupView` save — see "Credential-mutation entry point"). The scan also runs on `Notification.catermHostCredentialMaterialChanged` for low-latency push of a just-edited credential without waiting for the next scheduled sync cycle.

**Single mechanism — queue-time vs executor-time predicates**:

| Phase | Predicate | What happens if false |
|-------|-----------|----------------------|
| Queue-time (cycle start, after reconciler ops are emitted) | `state == .enabled` AND `host.credentialMaterialDirty == true` | If `state != .enabled`: skip queue, dirty bit stays for the next state transition. |
| Executor-time (when the queued op actually runs) | `host.serverId != nil` | If still nil after reconciler ops ran (`.createRemote` failed or wasn't emitted): the op is a no-op success — does NOT clear the dirty bit, does NOT throw, does NOT block `commitHostCheckpoint`. Next cycle re-scans and re-queues. |

For a brand-new host with credentials, this resolves to: dirty scan queues `.updateRemoteCredentials(localHostId)` regardless of whether `serverId` is currently nil. The op is appended **after** the reconciler's `.createRemote / .updateRemote / …` ops. When `.createRemote` runs, it writes `serverId` back to the local host via Plan A's existing flow. By the time the queued `.updateRemoteCredentials` op runs later in the same op loop, `host.serverId` is populated and the executor-time check passes. If `.createRemote` itself failed for this host, `serverId` is still nil, the executor no-ops, and the dirty bit survives for next cycle.

There is no separate "push my Mac's credentials" UI action in v1; the dirty-bit-driven push is automatic the first time a user edits a host while `.enabled`.

Behavior in each state:

| State | Push behavior |
|-------|---------------|
| `.disabled` | No credential push. Metadata-only push continues per Plan A. |
| `.waitingForKey` | No credential push (cannot encrypt without master key). Metadata-only push continues. |
| `.pausedByRemote` | No credential push (peer cleared cloud; defer until user re-enables). Metadata-only push continues. |
| `.enabled` | On local credential edit: read Keychain + key file, encrypt each present field with AAD, build `(passwordCiphertext, passphraseCiphertext, privateKeyCiphertext, credentialBlobState="payload", credentialBlobRevision=max(remoteRev, localRev)+1, credentialKeyID, credentialCryptoVersion=1)`, push as part of the same CKRecord write that carries metadata. Atomic. |

### Pull rules

For each received Host record:

```
if remote.credentialBlobRevision <= local.lastAppliedRevision[hostId]:
    skip — stale message

else:  // remote is newer
    switch state:

    case .disabled:
        // ignore credential payload entirely. Do NOT advance
        // lastAppliedRevision.
        //
        // Two independent gates determine whether a credential payload
        // is applied:
        //   (a) CKServerChangeToken (the cycle-level checkpoint, owned
        //       by HostSyncStore.commitHostCheckpoint, advanced after
        //       the op loop succeeds at HostSyncStore.swift:375) —
        //       decides whether the SERVER will re-deliver this record
        //       on a future incremental fetch.
        //   (b) lastAppliedRevision[hostId] — decides whether THIS
        //       device's apply step actually applies the credential
        //       once the record has been fetched.
        //
        // While disabled the cycle still applies metadata for the
        // record and commits the checkpoint, so gate (a) advances
        // past this revision and incremental will NOT re-deliver it.
        // The only path that re-fetches this record after toggle ON
        // is the credentialsNeedFullScan-driven forceFull cycle (set
        // by every transition into .enabled — see §Sync flow
        // integration). forceFull bypasses (a) entirely. At apply
        // time, gate (b) is what tells the apply step "this revision
        // hasn't been applied yet on this device, do it now". If we
        // had advanced lastAppliedRevision while disabled, gate (b)
        // would skip the credential apply on the forceFull replay
        // and the user would silently lose the data.
        no-op

    case .pausedByRemote(let seenTombstoneRevision):
        // We already remember the tombstone revision in the
        // associated value of pausedByRemote; we do NOT also bump
        // lastAppliedRevision (same toggle-ON suppression bug as
        // .disabled). If the remote record's revision is past the
        // tombstone we've seen and state == "payload", that means
        // some peer has re-enabled and re-pushed — bump
        // seenTombstoneRevision so we don't replay an old tombstone
        // on toggle ON. Otherwise no-op.
        if remote.credentialBlobState == "payload" and remote.rev > seenTombstoneRevision:
            // someone re-enabled cloud after the tombstone; remember.
            state → .pausedByRemote(seenTombstoneRevision: remote.rev)

    case .waitingForKey(let observedKeyID):
        switch remote.credentialBlobState:

        case "payload":
            // remember the keyID we need; retry every sync until
            // iCloud Keychain delivers it. Do not advance
            // lastAppliedRevision.
            update observedKeyID := remote.credentialKeyID

        case "tombstone":
            // Cloud was wiped while we were waiting. There's no
            // longer a key to wait for — transition to paused like
            // an .enabled device would. Review #6a.
            state → .pausedByRemote(seenTombstoneRevision: remote.rev)

        case "none":
            // Host without payload (e.g., .agent). Nothing to apply,
            // nothing to wait for on this record. Stay in
            // waitingForKey for the *other* hosts.
            no-op

    case .enabled:
        switch remote.credentialBlobState:

        case "tombstone":
            state → .pausedByRemote(seenTombstoneRevision: remote.credentialBlobRevision)
            local.lastAppliedRevision[hostId] = remote.credentialBlobRevision
            do NOT touch local Keychain or ManagedKeyStore

        case "none":
            // Host without syncable credential (e.g., .agent). Just advance.
            local.lastAppliedRevision[hostId] = remote.credentialBlobRevision

        case "payload":
            masterKey := await KeychainSyncMasterKeyStore.load(remote.credentialKeyID)
            if masterKey == nil:
                state → .waitingForKey(observedKeyID: remote.credentialKeyID)
                // do NOT advance lastAppliedRevision
                THROW so HostSyncStore aborts the apply and skips
                commitHostCheckpoint — see §Hard invariant below.

            try decrypt:
                decryptedPassword     = AES.GCM.open(remote.passwordCiphertext, AAD)
                decryptedPassphrase   = AES.GCM.open(remote.passphraseCiphertext, AAD)
                decryptedPrivateKey   = AES.GCM.open(remote.privateKeyCiphertext, AAD)
            on AES.GCM.open failure (AAD mismatch / corruption):
                log; THROW so HostSyncStore aborts apply (do NOT advance
                lastAppliedRevision); the next sync re-fetches and may
                succeed if it was a transient bit flip, or surfaces the
                same error if it's persistent.

            apply atomically via SessionStore.applyRemoteCredential(blob:for:):
                if decryptedPrivateKey != nil:
                    bytes := decryptedPrivateKey
                    if bytes.count > 1_000_000: THROW
                    managedURL := ManagedKeyStore.write(hostId, bytes)
                    host.credential = .keyFile(
                        keyPath: managedURL.path,
                        hasPassphrase: decryptedPassphrase != nil
                    )
                else if decryptedPassword != nil:
                    host.credential = .password
                // else: leave existing host.credential alone (e.g. .agent)

                if decryptedPassword:
                    Keychain.set(account: "\(hostId).password", secret: decryptedPassword)
                if decryptedPassphrase:
                    Keychain.set(account: "\(hostId).keyPassphrase", secret: decryptedPassphrase)

                local.lastAppliedRevision[hostId] = remote.credentialBlobRevision
```

### Hard invariant: decrypt failure aborts the sync

Any failure in the `apply` path for credentials — `master key not found`, `AES.GCM.open` failure, `ManagedKeyStore.write` failure, `Keychain.set` failure — **must** propagate up through `HostSyncStore.apply()` and prevent `commitHostCheckpoint` from being called. Plan B's existing checkpoint commit semantics already do this for any thrown error. Plan C must not silently swallow per-host credential failures.

Why: Plan B advances `CKServerChangeToken` on `commitHostCheckpoint` only. If we silently advance `lastAppliedRevision` on a failed credential, the next incremental fetch won't return that record again (the change-token has moved past it), and the credential repair only happens on the 60-min `forceFull`. Acceptable for some failures, unacceptable for "iCloud Keychain hasn't yet sync'd the master key" which is the main expected case on a fresh device.

Bounded retry to avoid infinite-loop on permanently-corrupt records: after **3 consecutive sync attempts** that all fail on the same `(hostId, credentialBlobRevision)` pair, mark the record as "decrypt-permanently-failed" in a local `corruptCredentials: Set<(UUID, Int64)>` and advance `lastAppliedRevision` for that host past this revision. Surface in UI ("Couldn't decrypt credentials for host X — re-enter on this device or wait for the next change from another device").

### Toggle transitions

Per the split per #8 of the review: the per-device toggle is a non-destructive pause/resume; the destructive "Delete synced credentials from iCloud" is a separate explicit action.

**Every transition that lands in `.enabled` (from `.disabled`, from `.waitingForKey` on master-key arrival, from `.pausedByRemote → toggle OFF → toggle ON`) MUST also set `credentialsNeedFullScan = true` and persist `CredentialSyncPreferences`.** This is the only way HostSyncStore knows to issue `.forceFull` on its next cycle and rediscover records whose `state="payload"` was previously ignored under `.disabled` (whose checkpoint has already advanced past them per `HostSyncStore.swift:375` — review #2). The flag is cleared by HostSyncStore after the forceFull cycle's checkpoint commits.

| Action | Behavior |
|--------|----------|
| Toggle OFF (per-device, default) → `.enabled` | If iCloud Keychain isn't reachable (probe via `KeychainSyncMasterKeyStore.loadAny()` failure to find existing key + system-level "iCloud Keychain enabled" check) → block transition with UI: "Enable iCloud Keychain in System Settings → Apple ID → iCloud → Passwords & Keychain". Otherwise: if a master key already exists in cloud → state → `.waitingForKey` (set `credentialsNeedFullScan = true` regardless — the forceFull is what tells us the cloud has payload, and on master-key arrival it gets reconsumed); if no master key anywhere AND no `state="payload"` records exist → generate fresh master key, state → `.enabled`, `credentialsNeedFullScan = true`. Either way, **set `credentialsNeedFullScan = true`** and persist. **Do not auto-push local credentials over cloud.** |
| `.enabled` / `.waitingForKey` / `.pausedByRemote` → toggle OFF | State → `.disabled`. Stop pushing, stop applying incoming credentials. Cloud ciphertext untouched. Local Keychain and ManagedKeyStore untouched. `credentialsNeedFullScan` not changed (it would be set the next time we re-enable). |
| `.waitingForKey` → master key arrives via iCloud Keychain | State → `.enabled`. Set `credentialsNeedFullScan = true` (the prior `.waitingForKey` may also have set it; idempotent). Re-run sync on next trigger. |
| `.pausedByRemote` → toggle OFF then ON | Same path as `.disabled` → toggle ON: forced forceFull + dirty-bit-driven push of any locally-edited credentials accumulated during pause. If cloud is empty (all tombstones / `state="none"`), nothing applies locally, but the device is now active and any subsequent local edit will push automatically via the dirty bit. |
| Destructive button: "Delete synced credentials from iCloud..." | Confirmation modal text per §Destructive deletion flow. On confirm, the durable resumable flow described there runs. Local state on this Mac stays `.enabled`; local Keychain + ManagedKeyStore + master key (in iCloud Keychain) all untouched. Other Macs (which haven't bumped their `lastAppliedRevision` for these hosts) receive the tombstones and transition to `.pausedByRemote`. |

**Concurrent destructive action + ongoing edits**: while the destructive modal is open, the device should not accept credential edits (UI-level disable). Once tombstones are pushed, any concurrent edit from another device wins the LWW race per CloudKit's `serverRecordChanged` semantics.

### Conflict resolution

CloudKit's actual mechanism is `recordChangeTag` + `ifServerRecordUnchanged` save policy. Server returns `CKError.serverRecordChanged` (currently mapped to HTTP 409 by `CloudKitErrorMapping`) on stale writes. Plan A's existing behavior — and Plan C's — is "next sync trigger pulls latest record state, encoder re-encodes from current local Keychain, push retries naturally". There is no in-process refetch/merge/retry loop in v1; that would belong to a Plan A/B hardening exercise outside Plan C's scope.

For credentials specifically: race outcome is "last successful server-side write wins". Mac A and Mac B push different credentials in close succession → server accepts the first → second sees `serverRecordChanged` → on next sync, second pulls fresh state and re-encrypts current local; server now has the chronologically-second credential. The user observes "the device that pushed last wins", same as Plan A metadata.

### Destructive deletion flow (durable + crash-resumable, review #2''' / fourth pass)

The user clicks "Delete synced credentials from iCloud..." and confirms. The flow must survive crashes, app quits, network failures, and partial completion without losing the user's delete intent and without leaving the credential pipeline in a state where subsequent local edits could re-populate cloud.

**Confirmation modal text**: "This removes credentials from iCloud for ALL your devices. Each device keeps its local credentials. To re-enable sync afterward, enable the toggle on a device of your choice. Are you sure?"

**On confirm, in this exact order:**

1. **Persist intent atomically** (single `SyncPreferences.save`):
   - `deleteCredentialsFromCloudInProgress = DeletionProgress(pendingLocalHostIds: <localHostIds of every host with a non-nil serverId, regardless of credentialBlobState>)`. Hosts without `serverId` have nothing to tombstone.
   - **Clear `credentialMaterialDirty = false` for every host on this Mac, persist hosts.json** (review #4 second-pass — closes the same window: a pre-existing dirty bit must not survive past the intent persistence to be picked up later).
2. **HostSyncStore observes** `deleteCredentialsFromCloudInProgress != nil` and switches behavior at every cycle start:
   - The dirty scan and `.updateRemoteCredentials` queueing are suppressed entirely. (`credentialsNeedFullScan` and Plan A metadata sync continue as normal — this gate is credential-push-only.)
   - HostSyncStore runs a **destructive sub-pipeline** for each `localHostId` in `pendingLocalHostIds`:
     a. Read host; if `serverId == nil` (e.g., user deleted the host locally between steps), skip and remove from `pendingLocalHostIds`.
     b. Fetch existing CKRecord by `serverId`.
     c. Compute `tombRev = max(rec["credentialBlobRevision"] as? Int64 ?? 0, lastAppliedRevision[localHostId] ?? 0) + 1`.
     d. Apply tombstone: `state="tombstone", credentialBlobRevision=tombRev, all ciphertext fields nil, credentialKeyID=nil`.  Run the §Seed-before-credential-save step too (a tombstone is a credential-only save, so legacy records still need `metadataUpdatedAt` seeded).
     e. Save.
     f. **On success, atomically persist** (single `SyncPreferences.save`): `lastAppliedRevision[localHostId] = tombRev` (review #6b — prevents self-pausing on own tombstone) **and** remove `localHostId` from `pendingLocalHostIds`.
     g. On `serverRecordChanged`: re-fetch and retry within the same sub-pipeline pass (a tombstone race is harmless — whoever wins, the next pass either confirms tombstone or, if the loser was a peer payload push, re-tombstones it). On other failures: leave `localHostId` in `pendingLocalHostIds`, exit the sub-pipeline (next sync cycle resumes).
   - When `pendingLocalHostIds.isEmpty`, atomically clear `deleteCredentialsFromCloudInProgress = nil` and persist. Normal credential-push pipeline resumes on the next cycle.
3. **Local state on this Mac stays `.enabled`** throughout. After completion, the user can resume cloud sync by editing any host (`setHostCredentialMaterial` flips `credentialMaterialDirty = true` per the normal entry point). Master key in iCloud Keychain is left untouched (cheap to keep for re-enable). Local Keychain + ManagedKeyStore are untouched (user keeps local credentials).

**Crash / restart semantics**:
- If we crash between step 1 and step 2, restart finds `deleteCredentialsFromCloudInProgress` populated and dirty bits cleared. Step 2's sub-pipeline runs fresh on next sync cycle.
- If we crash mid-sub-pipeline (between two host tombstones), restart's sub-pipeline picks up the remaining `pendingLocalHostIds` and finishes them. Already-tombstoned hosts are no longer in the list.
- If we crash between sub-pipeline empty and clearing the outer flag, the next cycle finds an empty list, clears the flag, resumes normal pipeline. Idempotent.
- If the user toggles OFF mid-deletion, `state → .disabled` but the destructive sub-pipeline still runs to completion (finishing what they started); only the suppression of normal credential push remains in effect. After the destructive flow finishes, `.disabled` behaves normally (no credential pushes).

**UI during in-progress deletion**:
- Destructive button replaced by a non-clickable "Deleting credentials from iCloud... (N/M complete)" status until `pendingLocalHostIds` empties.
- Per-device toggle remains operable (toggle OFF allowed, see above).
- Host add/edit form remains operable; secret writes still go to local Keychain + ManagedKeyStore via `setHostCredentialMaterial`, but the dirty bit is cleared again at end-of-call as long as `deleteCredentialsFromCloudInProgress != nil` (so any edits during the deletion window do not re-populate cloud the moment the deletion finishes — explicit behavior, documented to the user via the modal text "Each device keeps its local credentials").

## Sync flow integration

`HostSyncReconciler` produces the existing 5-op `SyncOperation` set unchanged: `.createRemote / .createLocal / .updateRemote / .updateLocal / .deleteLocal`. **`.updateRemoteCredentials(localHostId)` is NOT a reconciler output** — it is queued by `HostSyncStore` from the dirty-bit scan described in §Credential-mutation entry point and §Push rules, **after** the reconciler's ops are appended to the cycle's queue. The reconciler stays Plan A's metadata-only diff engine; credential push is a side channel triggered by user mutation, not by remote-vs-local diff. The existing `.updateRemote` op stays strictly metadata-only via the `applyMetadata` partial encoder; the dirty-scan-emitted `.updateRemoteCredentials` op uses `applyCredentialBlob`. The two op kinds touch disjoint CKRecord field sets so they can co-exist on the same record in the same cycle without conflict (review #5).

### Credential-mutation entry point (single API for all UI paths)

Review #5 caught that `setCredentialOnly` only covers the `CredentialSetupView` flow. The primary host add / edit path in `HostListSidebar.swift:71` calls `addHost` / `updateHost` and then `persistSecret` (Keychain write) — `setCredentialOnly` is never invoked. Hooking `.updateRemoteCredentials` to `setCredentialOnly` would silently miss the most common credential-mutation path.

Reviews #1 and #3 caught two further problems with carrying secrets inside the SyncOperation enum or having `SessionStore` decide push policy:
- A brand-new host has no `serverId` until `.createRemote` lands. If the entry-point API checks `host.serverId != nil` synchronously and only-then emits an op, the credential push is silently dropped on add. There is no replay mechanism for "after createRemote assigns the serverId, push the deferred credentials".
- `Package.swift:51-54` defines a one-way dependency `HostSyncStore → SessionStore`. If `SessionStore.setHostCredentialMaterial` reads `CredentialSyncState` and emits `SyncOperation.updateRemoteCredentials`, both types must live in `HostSyncStore` (or above), and `SessionStore` would have to import `HostSyncStore` — a circular dependency.

**Fix**: split responsibility. SessionStore owns the durable dirty bit and posts a notification; HostSyncStore observes both the bit and the notification and is the only side that knows about `CredentialSyncState` and `SyncOperation`.

```swift
// SessionStore — knows nothing about CredentialSyncState or SyncOperation.
public func setHostCredentialMaterial(
    secrets: HostSecrets,            // password? passphrase? privateKeyBytes?
    credentialSource: CredentialSource,
    for hostId: UUID
) throws
```

Atomic ordering inside the method (no SyncOperation references; no CredentialSyncState reads):
1. Keychain writes for `secrets.password` / `secrets.passphrase` if present. Keychain failure throws; nothing else has changed yet.
2. `ManagedKeyStore.write(hostId, bytes)` if `secrets.privateKeyBytes != nil` (atomic-replace per Fix #4). Failure throws; Keychain writes from step 1 are not rolled back, but they're consistent with the prior `host.credential` and harmless until the next user edit overwrites them — the next sync attempt will retry the ManagedKeyStore part because the dirty bit (step 4) is still set.
3. In-memory: update `host.credential = credentialSource`, set `host.credentialMaterialDirty = true`.
4. `HostPersistence.save(hosts, to: hostsURL)` — atomic disk write. Both the credential change and the dirty bit are persisted in the same file; a crash between Keychain write and `HostPersistence.save` is recoverable because the dirty bit's absence at restart matches the absence of any work to do.
5. After `HostPersistence.save` returns, post `Notification.Name.catermHostCredentialMaterialChanged` with `userInfo: ["hostId": hostId]`.

Push policy lives in `HostSyncStore`:

- HostSyncStore subscribes to `.catermHostCredentialMaterialChanged` at construction time.
- On notification, **and** at the start of every sync cycle (so crash-recovered dirty bits are picked up regardless of whether the notification was delivered), HostSyncStore scans `sessionStore.hosts` for `credentialMaterialDirty == true`. The decision uses the queue-time / executor-time split from §Push rules:
  - **Queue-time** (when this scan runs): if `state == .enabled`, append `.updateRemoteCredentials(localHostId)` to the cycle's op queue **after** any `.createRemote / .updateRemote / .createLocal / .updateLocal / .deleteLocal` ops produced by the reconciler. Do this **regardless of `serverId`** — the executor-time check below handles the new-host case. If `state != .enabled` (`.disabled` / `.pausedByRemote` / `.waitingForKey`), skip the queue; the dirty bit stays on disk and is re-evaluated on the next state transition into `.enabled`.
  - **Executor-time** (when the queued op runs, possibly minutes later or after `.createRemote` populated `serverId`): re-read the host from `sessionStore.hosts` by `localHostId`. If `host.serverId == nil` (e.g., `.createRemote` failed earlier in the same cycle), the op succeeds as a no-op — does not throw, does not clear the dirty bit, does not block `commitHostCheckpoint`. Otherwise: fetch the existing CKRecord; if its `metadataUpdatedAt` is nil, seed it from `rec.modificationDate ?? rec.creationDate` in the same client-side mutation (per §Seed-before-credential-save); open Keychain + ManagedKeyStore live; build the encrypted blob with AAD `"\(serverId)|\(fieldKind)|\(rev)|\(schemaVersion)"`; call `client.applyCredentialBlob(into: existingRecord, blob:)`; save; on success call `sessionStore.clearCredentialMaterialDirty(localHostId)`. CloudKit-side failure (other than `serverRecordChanged`) throws and leaves the dirty bit set for retry on the next cycle.

This single mechanism replaces the earlier draft's two-branch description ("`.enabled` AND serverId != nil" vs "`.enabled` AND serverId == nil") that confused queue-time policy with executor-time policy (review #2). There is one queue-time predicate (state == `.enabled`) and one executor-time predicate (`serverId != nil`); they are evaluated in different phases of the same cycle.

`SessionStore.clearCredentialMaterialDirty(hostId:)` is a tiny new SessionStore API: in-memory clear + `HostPersistence.save`. Idempotent.

Call sites updated:

- `HostListSidebar.swift:71` (add path): after `store.addHost(host)`, replace `persistSecret(host, secret)` with `store.setHostCredentialMaterial(secrets: ..., credentialSource: host.credential, for: host.id)`.
- `HostListSidebar.swift:83` (edit path): same substitution after `store.updateHost(updated)`.
- `CredentialSetupView` callback (`HostListSidebar.swift:95-103`): the existing two-step `setHostSecret` + `setCredentialOnly` collapses into one `setHostCredentialMaterial` call. The original "Keychain first; if it throws, no SessionStore mutation has happened" invariant is preserved by step ordering above.

**Layering guarantee**: SessionStore imports nothing new; it does not reference `CredentialSyncState`, `SyncOperation`, or any HostSyncStore type. The notification carries only `hostId: UUID` (a SessionStore-native type). HostSyncStore continues to depend on SessionStore one-way per `Package.swift:51-54`. No circular dependency.

`CKRecordHostMapping` — split into three explicit encoders so that **metadata-only writes never touch credential fields and credential-only writes never touch metadata fields** (review #3 — without this split, a routine rename/port edit would clobber every other device's encrypted payload):

- `makeRecord(input:) -> CKRecord` — used by `.createRemote` only. Initializes a fresh CKRecord with metadata fields (`name`, `hostname`, `port`, `username`, `authType`, **`metadataUpdatedAt = Date()`**) and explicitly initializes credential fields to "no payload yet": `credentialBlobState = "none"`, `credentialBlobRevision = 0`, `passwordCiphertext = passphraseCiphertext = privateKeyCiphertext = credentialKeyID = nil`, `credentialCryptoVersion = 1`. This is the only path that writes credential fields without a real payload.

- `applyMetadata(into existing: CKRecord, from host: SSHHost)` — used by `.updateRemote`. **Mutates only the metadata fields** (`name`, `hostname`, `port`, `username`, **`metadataUpdatedAt = host.updatedAt`**) on the caller-supplied existing CKRecord. **Never reads or writes credential fields.** The reconciler must pass a CKRecord that was just fetched from the server (Plan A's existing `.updateRemote` already operates on fetched-then-modified records, so this matches current behavior); credential fields on that fetched record stay at whatever value the server holds. **Server-side `modificationDate` will be bumped by the save itself, but the decoder no longer reads it as `updatedAt`** — see "Why `metadataUpdatedAt` is a separate field" above.

- `applyCredentialBlob(into existing: CKRecord, blob: CredentialBlob)` — used by `.updateRemoteCredentials`. **Mutates only the credential fields** (`passwordCiphertext`, `passphraseCiphertext`, `privateKeyCiphertext`, `credentialBlobState`, `credentialBlobRevision`, `credentialKeyID`, `credentialCryptoVersion`). **Never reads or writes metadata fields, including `metadataUpdatedAt`.** Server-side `modificationDate` is bumped by the save (unavoidable per Apple's CloudKit semantics), but because the decoder reads `metadataUpdatedAt` instead, credential rotations on Mac A produce no metadata-update signal on Mac B.

- `decode(record:) -> RemoteHost` — unchanged shape: returns metadata plus optional `credentialBlob: CredentialBlob?` carrying ciphertext + revision + keyID + state + cryptoVersion. `state == "none"` decodes to `credentialBlob = nil` for the consumer's convenience.

This split makes a hard guarantee at the type level: there is no API that can both update metadata and clobber credentials in the same call. The `.updateRemote` reconciler op physically cannot reach the credential fields.

`HostSyncStore`:
- The `apply()` step is extended with credential application via `SessionStore.applyRemoteCredential` per §Pull rules.
- The push side: at the start of every sync cycle (and on `catermHostCredentialMaterialChanged` notification arrival), HostSyncStore scans `sessionStore.hosts` for `credentialMaterialDirty == true` and queues `.updateRemoteCredentials(hostId)` per the per-host predicate in §Credential-mutation entry point. Queued credential ops always run **after** the reconciler-emitted ops in the same cycle so that brand-new hosts have their `.createRemote` complete (and `serverId` written back) before their `.updateRemoteCredentials` executes.
- The `.updateRemoteCredentials` op executor reads Keychain + ManagedKeyStore live at push time, encrypts under AAD using `host.serverId`, calls `client.applyCredentialBlob(into: existingRecord, blob:)` for a partial CKRecord update, and on success calls `SessionStore.clearCredentialMaterialDirty(hostId:)`. Failure leaves the dirty bit set; the next cycle retries.
- **Toggle ON full-snapshot pass (review #2)**: `HostSyncStore` reads `CredentialSyncPreferences.credentialsNeedFullScan` at the **start** of every sync cycle. If `true`, that cycle is forced to use `.forceFull` regardless of `client.preferredHostSyncMode()`'s default, ensuring records that were ignored under `.disabled` (and whose checkpoint advanced past them per `HostSyncStore.swift:375`) are re-fetched and re-applied with credentials. After the cycle's `commitHostCheckpoint` succeeds, the flag is cleared. If the cycle throws before checkpoint, the flag stays so the next cycle retries.
- Existing sync triggers (per-launch, push-driven, 60-min forceFull) all carry the credential plumbing for free.

## Lifecycle hooks

| Event | Local Keychain | ManagedKeyStore | Master key (synchronizable) | `lastAppliedRevision` |
|-------|---------------|-----------------|----------------------------|----------------------|
| Pull decrypt success | `set(account, secret)` | `write(hostId, bytes)` for privateKey | unchanged | advance for hostId |
| User edits host (form submit) | `setHostCredentialMaterial` writes Keychain + sets `host.credentialMaterialDirty = true` + posts `catermHostCredentialMaterialChanged`. HostSyncStore observes; if state == `.enabled`, queues `.updateRemoteCredentials(localHostId)` after the reconciler ops regardless of `serverId`. Op executor checks `serverId` at runtime — no-op if still nil (review #2). | `setHostCredentialMaterial` writes via atomic `rename(2)` if private-key bytes present | unchanged | unchanged |
| Host deleted (local or remote) | `deleteAll(prefix: hostId)` | `delete(hostId)` | unchanged | drop `lastAppliedRevision[hostId]` |
| Toggle ON → OFF (per-device) | unchanged | unchanged | unchanged | unchanged |
| Any transition INTO `.enabled` (`.disabled` → toggle ON; `.waitingForKey` → master-key arrives; `.pausedByRemote` → toggle OFF then ON) | unchanged | unchanged | look up; generate iff cloud is empty | unchanged. Also: **set `credentialsNeedFullScan = true`** so the next sync cycle is forced to `.forceFull` (review #2). |
| Destructive: "Delete synced credentials from iCloud..." (confirmed) on **deleting** Mac | unchanged (user keeps local secrets) | unchanged | **unchanged** (not removed; cheap to keep for re-enable) | per the durable resumable §Destructive deletion flow: on confirm, atomically persist `deleteCredentialsFromCloudInProgress` + clear `credentialMaterialDirty` for every host. As each host tombstone push lands, atomically `lastAppliedRevision[hostId] := tombRev` (review #6b) **and** remove that host id from `pendingLocalHostIds`. Outer flag cleared when list is empty. Crash-resumable. |
| Receiving tombstone push on a **peer** Mac | unchanged | unchanged | unchanged | for each tombstoned host: `lastAppliedRevision[hostId]` stays where it was; the state machine transition (`.enabled` → `.pausedByRemote(seenTombstoneRevision: rev)` and `.waitingForKey` → `.pausedByRemote(...)` per Fix #6a) is what records the observation, not the high-water mark |
| iCloud account change (Plan B `AccountIdentityTracker`) | unchanged (Keychain is device-local) | wipe entire keys directory | the synchronizable item is part of the OLD iCloud account; the new account starts from scratch | clear all `lastAppliedRevision`; state → `.disabled` |
| User resets iCloud Keychain in System Settings | unchanged | **unchanged** (review #7 correction: local managed keys remain valid local credentials) | item is gone; on next sync attempt, `loadAny` returns nil → state → `.waitingForKey` or surfaces "Master key lost" recovery UI | unchanged |
| Plan B's encrypted-data-reset zone signal (`encryptedDataResetZoneIDs`) | unchanged | **unchanged** under β (no longer the credential-failure path) | unchanged | reset for the affected zone |

## UI changes

### Sync settings tab — three new elements

1. **Per-device toggle** "Sync SSH credentials on this Mac" (default OFF).
   - Disabled with explainer when iCloud Keychain isn't enabled: "Enable iCloud Keychain in System Settings to use credential sync".
   - When `.enabled`: status line "N hosts synced; encrypted with a key only your devices can read".
   - When `.waitingForKey`: status line "Waiting for iCloud Keychain to deliver the encryption key from another device..." with a retry button.
   - When `.pausedByRemote`: status line "Credential sync was disabled across your devices. Toggle off then on to re-pull from iCloud — currently empty after the deletion."

2. **Destructive button** "Delete synced credentials from iCloud..."
   - Visible only when `state == .enabled` and `credentialBlobState == "payload"` for at least one host.
   - Confirmation modal text per §Toggle transitions.

3. **Decrypt-permanently-failed surface** (rare): list of hosts where `corruptCredentials` is non-empty, with "Re-enter credential locally" action that opens `CredentialSetupView`.

### Host edit form

No visible change. Toggle is global; per-host badges would muddy the mental model.

### `CredentialSetupView` trigger conditions

Plan A's "local Keychain miss → connect attempt" trigger is unchanged. Plan C adds:
- Sync state `.disabled` / `.pausedByRemote` / `.waitingForKey` and local Keychain miss → fall back to `CredentialSetupView` as before.
- `.enabled` but the most recent decrypt for this host is in `corruptCredentials` → fall back to `CredentialSetupView`.

## Migration

- **Existing Plan A/B users on first launch with the Plan C build**: see new toggle (default OFF) + destructive button (initially hidden because no payload). Zero behavior change for all existing hosts.
- **CloudKit schema migration**:
  - **Development env**: lazy. New fields appear on records as Plan C clients write them.
  - **Production env**: **schema deploy required before Plan C first reaches production users.** This is part of Plan E ship readiness — explicitly listed in `cloudkit_migration_status.md` as a Plan E pre-ship task. Old Plan A/B clients reading new fields ignore them; new Plan C clients reading old records see absent fields decode to nil / "" / 0.
- **Old Plan A clients in production after Plan C ships**: still work for metadata. They will not encrypt or decrypt credentials. If a Plan C device pushes credentials, an old Plan A device fetching the record sees the metadata + ignores the cipher fields → behaves like Plan A.
- **First-time toggle ON**: per §Toggle transitions, sets `credentialsNeedFullScan = true` and defaults to pulling cloud state. Plan A users opting in for the first time on their first device will find cloud is empty → they remain in `.enabled` with no payload. To populate cloud, they edit any host: `setHostCredentialMaterial` flips `credentialMaterialDirty = true` and HostSyncStore queues `.updateRemoteCredentials` automatically on the next sync cycle. There is no separate "Push this Mac's credentials" action in v1 — the dirty-bit pipeline makes it superfluous.

## Failure modes (revised under β)

| Scenario | Behavior |
|----------|----------|
| iCloud Keychain not enabled on this device | `.disabled` → toggle ON refused with explainer + System Settings deeplink. Already-enabled devices that lose iCloud Keychain access (toggled off in System Settings later) → next sync attempt fails to load master key → state → `.waitingForKey`. |
| Master key not yet in local iCloud Keychain (fresh second device) | State `.waitingForKey`. Pull fetches CKRecord, sees `state="payload"`, can't decrypt, sets `observedKeyID = remote.credentialKeyID`. **Does not generate a new key** (which would orphan all existing payload). Retries on every sync trigger; iCloud Keychain typically delivers the key within seconds-to-minutes. |
| Master key collision (two fresh devices generate keys simultaneously before iCloud Keychain syncs) | Window is small (seconds). The "loser" device's first push uses its local key; CloudKit accepts. The "winner" device pulls, can't decrypt with its own key, transitions to `.waitingForKey` for the loser's `keyID`. Eventually iCloud Keychain delivers the loser's key (CKKS itself does LWW on synchronizable items). The winner now has both keys; `load(keyID)` finds the right one for incoming records. Net effect: short delay, then convergence. |
| User resets iCloud Keychain in System Settings | All synchronizable items wiped on this device. Master key gone. State → `.waitingForKey` with no `observedKeyID`. UI explains: "iCloud Keychain was reset. Existing cloud credentials cannot be decrypted. Use 'Delete synced credentials from iCloud' to clear and re-enable sync with a fresh key, or wait for another device to re-establish the key." Local Keychain + ManagedKeyStore untouched (review #7). |
| AAD mismatch / ciphertext corruption (`AES.GCM.open` throws) | Per-host failure. Logged. Up to 3 retries across sync passes; then the host enters `corruptCredentials` and falls back to `CredentialSetupView`. |
| `ManagedKeyStore.write` fails (disk full / sandbox / path traversal rejection) | Throws → aborts apply for this record → `commitHostCheckpoint` not called → next sync retries. UI surface only on persistent failure. |
| Local Keychain write fails | Same: throws, aborts apply, next sync retries. |
| Source key file missing on Mac A at edit time | Push the password / passphrase fields, leave `privateKeyCiphertext = nil`, set `credentialBlobState = "payload"`. Form-level non-blocking warning. Mac B decrypting receives no private key → flips to `.password` credential or, if no password either, leaves credential alone. Connection attempts on Mac B trigger `CredentialSetupView`. |
| `.agent` host edited while `.enabled` | Push `state = "none"`, `revision++`. All ciphertext fields nil. Other Macs see "no payload" and don't change local state. (This is precisely the case where the earlier draft would have falsely tombstoned the host.) |
| CloudKit `serverRecordChanged` (concurrent push race) | Mapped to HTTP 409 by `CloudKitErrorMapping`. Next sync trigger pulls the latest record state and the encoder re-encrypts current local Keychain; push retries naturally. Same as Plan A metadata conflicts. No new Plan C code needed. |
| Plan B's `encryptedDataResetZoneIDs` signal | Plan B's drain loop wipes the affected zone token. Plan C: re-fetch on next sync; encoded re-encryption from local Keychain re-populates ciphertext. Local managed keys are NOT cleared (review #7). |
| Network partition / offline | All push and pull buffer naturally per Plan A behavior. Toggle states and `lastAppliedRevision` persist across launches. |

## Testing

### Unit

- `KeychainSyncMasterKeyStoreTests`: generate, load, load-by-keyID, idempotent remove, synchronizable flag set.
- `ManagedKeyStoreTests`: write/read/delete/`chmod` enforcement; atomic write (mid-write crash leaves no half-file via tmp-then-rename); `path` computation when file absent; idempotent delete; root creation with 0700; symlink rejection (test fixture creates a symlink and verifies `write` rejects); path-traversal rejection; size-cap rejection.
- `EnvelopeCryptoTests`: AES.GCM seal/open round-trip; AAD mismatch detection; SealedBox.combined parsing; nonce uniqueness across N seals.
- `CredentialBlobMappingTests`: encode → CKRecord fields with all of `state / revision / keyID / cryptoVersion / ciphertexts`; decode → `CredentialBlob`. Round-trip with CKRecord fixture for each `state` value.
- `CredentialSyncStateMachineTests`: every transition in the §State machine diagram. Push and pull predicates per state. Tombstone arrival from `.enabled`, `.waitingForKey`, `.disabled`. `waitingForKey` exit on master-key arrival.
- `RevisionMonotonicTests`: stale-revision drop, tombstone-revision-induced state transition, encoder revision is `max(remote, local) + 1`.
- `HardInvariantTests`: any apply-side failure throws → `commitHostCheckpoint` not called (verified via mock token store assertion).
- `BoundedRetryTests`: 3 consecutive AAD mismatches on same `(hostId, rev)` → host added to `corruptCredentials` and `lastAppliedRevision` advanced past that rev.
- `DirtyBitPersistenceTests`: `setHostCredentialMaterial` sets `host.credentialMaterialDirty = true` and survives `HostPersistence` round-trip; `clearCredentialMaterialDirty` clears it; idempotent.
- `DirtyBitNotificationTests`: `setHostCredentialMaterial` posts `catermHostCredentialMaterialChanged` exactly once after `HostPersistence.save` returns; not before Keychain write completes; not on rollback paths.
- `BrandNewHostPushOrderingTests`: a host added with credentials in one cycle: `.createRemote` runs first, writes back `serverId`; `.updateRemoteCredentials` runs after in the same cycle and reads the just-written `serverId` for AAD; dirty bit cleared on success.
- `OfflineDirtyReplayTests`: with HostSyncStore offline, `setHostCredentialMaterial` is called; dirty bit persists across simulated relaunch; first cycle on next launch picks it up via the start-of-cycle scan and pushes.
- `NeedFullScanFlagTests`: every transition into `.enabled` (toggle from `.disabled`, master-key arrival from `.waitingForKey`, toggle ON from `.pausedByRemote`) sets `credentialsNeedFullScan = true` and persists; HostSyncStore's next cycle issues `.forceFull`; flag cleared after `commitHostCheckpoint`; flag preserved if cycle throws before checkpoint.
- `DisabledChecksumThenEnableTests`: device starts `.disabled`; remote pushes `state="payload"` rev=5; HostSyncStore advances checkpoint past it (Plan A metadata sync); user toggles ON → flag set → next cycle is forceFull → record re-fetched → credential applied → `lastAppliedRevision[hostId] = 5`.
- `LayeringTests` (compile-time): `SessionStore` source files do not reference `CredentialSyncState`, `SyncOperation`, or `HostSyncStore` symbols (verified by SwiftPM target boundary; `Package.swift` keeps `HostSyncStore depends on SessionStore` one-way).
- `MetadataUpdatedAtTests` (review #1''): a credential-only save via `applyCredentialBlob` does NOT change `metadataUpdatedAt` even though `CKRecord.modificationDate` is bumped server-side; `decode` reads `metadataUpdatedAt` as the `updatedAt` source; absent `metadataUpdatedAt` (legacy Plan A record) falls back to `creationDate`. Negative test: a metadata save via `applyMetadata` DOES update `metadataUpdatedAt`.
- `ExecutorTimeServerIdNoOpTests` (review #2''): queue `.updateRemoteCredentials` for a dirty local host with `serverId == nil`; executor runs and no-ops (no throw, dirty bit unchanged, no `applyCredentialBlob` call observed on the mock client). Adjacent test: same host gets `serverId` populated via simulated `.createRemote` running before the credential op in the same op queue → executor proceeds and pushes.
- `HostCodableBackcompatTests` (review #3''): a hosts.json fixture written by a Plan A binary (no `credentialMaterialDirty` key) decodes successfully via `init(from:)` with `credentialMaterialDirty == false` for every host. Round-trip a Plan C-written hosts.json through Plan C decode → `credentialMaterialDirty` round-trips intact.
- `DestructiveClearsDirtyTests` (review #4''): set `credentialMaterialDirty = true` on hosts H1, H2; click destructive button + confirm; verify (a) hosts.json now has dirty=false for all hosts (persisted before tombstone push begins); (b) tombstone push proceeds; (c) the next dirty scan emits no `.updateRemoteCredentials` ops; (d) cloud state is unambiguously tombstoned for H1 and H2 — no race re-populating it.
- `ReconcilerOpSetTests` (review #5''): exhaustive case coverage of `HostSyncReconciler.reconcileFullSnapshot` and `reconcileDelta` confirming the produced op set is `.createRemote / .createLocal / .updateRemote / .updateLocal / .deleteLocal` only — `.updateRemoteCredentials` is never returned by the reconciler. Companion test confirms `HostSyncStore`'s op queue contains `.updateRemoteCredentials` only when sourced from the dirty scan.
- `LegacyMetadataUpdatedAtFallbackTests` (review #1''' regression guard): CKRecord fixture with `creationDate=t0, modificationDate=t2, metadataUpdatedAt absent`. Verify (a) decode returns `updatedAt=t2` (not t0); (b) a local stale host with `updatedAt=t1 < t2` is correctly identified as stale by the reconciler — no `.updateRemote` op emitted that would overwrite cloud's t2 with t1.
- `SeedBeforeCredentialSaveTests` (review #1''' regression guard): a Plan A record without `metadataUpdatedAt` is the target of `.updateRemoteCredentials`. Verify the executor's CKRecord save contains BOTH the seeded `metadataUpdatedAt = rec.modificationDate` AND the credential blob, in a single save (single fake-client `save` call observed). Verify the saved CKRecord, when re-decoded, returns `updatedAt = original modificationDate` (the pre-credential-save value), unaffected by the bumped server-side modificationDate that this save would have produced.
- `MetadataPathSeedingTests`: a Plan A record without `metadataUpdatedAt` is the target of `.updateRemote` (metadata edit, no credentials involved). Verify `applyMetadata` writes `metadataUpdatedAt = host.updatedAt`, and subsequent decode returns that value. (Confirms metadata edits also migrate legacy records without going through credential push.)
- `DestructiveResumableTests` (review #2''' regression guard): begin destructive flow with `pendingLocalHostIds = [H1, H2, H3]`; simulate H1 tombstone success → atomic SyncPreferences.save observed (lastAppliedRevision[H1] set + H1 removed from pendingLocalHostIds in same write); then **simulate process crash before H2 tombstone**; "relaunch" (rebuild HostSyncStore from persisted SyncPreferences); verify (a) on next cycle the destructive sub-pipeline picks up H2 first (not H1, not idempotently re-tombstone), (b) `pendingLocalHostIds == [H2, H3]` initially, (c) after H2+H3 succeed, outer flag cleared, (d) normal dirty scan resumes only after the flag is nil.
- `DestructiveSuppressesDirtyScanTests` (review #2''' regression guard): set `deleteCredentialsFromCloudInProgress = DeletionProgress(pendingLocalHostIds: [H1])`; manually set `host.credentialMaterialDirty = true` on a different host H4 (or H1 itself). Run a sync cycle; verify zero `.updateRemoteCredentials` ops are queued / executed for H4 (or H1) for the duration the flag is non-nil. After H1 tombstone completes and flag clears, the next cycle's dirty scan picks H4 up normally.
- `DestructiveDirtyClearOnConfirmTests` (review #4 + #2''' interaction): hosts H1 and H2 both have `credentialMaterialDirty = true` from prior local edits; user clicks Delete + confirms. Verify the FIRST disk write completed by the confirm handler is the atomic `(deleteCredentialsFromCloudInProgress = DeletionProgress(...) + dirty cleared on H1, H2)` — not two separate writes that could leave the dirty bits intact if a crash occurred between them.
- `DestructiveEditDuringDeletionTests` (review #2''' regression guard): destructive flow in flight; user calls `setHostCredentialMaterial` for some host; verify the local Keychain + ManagedKeyStore + `host.credential` mutations land but the dirty bit is **cleared again at end of call** because `deleteCredentialsFromCloudInProgress != nil` (per §Destructive deletion flow UI section). Confirm cloud is not re-populated after the deletion completes.
- `DisabledLastAppliedNoOpTests` (review #3''' doc-bug regression guard): in `.disabled`, fetch a record with `state="payload"` rev=5; assert `lastAppliedRevision[hostId]` is unchanged. Then transition to `.enabled` (sets `credentialsNeedFullScan`); next cycle is forceFull; rev=5 record re-applied; `lastAppliedRevision[hostId] = 5` after success. Confirms the apply-time gate (lastAppliedRevision) is independent of the fetch-time gate (CKServerChangeToken).

### Integration (in-process `FakeCloudDatabase` + mock `KeychainSyncMasterKeyStore` with two Caterm instances representing Mac A / Mac B)

- Push-decrypt round-trip: Mac A enables sync (generates master key), Mac B has the same master key pre-installed in its mock; Mac A edits credentials; Mac B decrypts and writes Keychain + ManagedKeyStore; Mac B's `host.credential` flips from `.password` to `.keyFile(managedPath, ...)`.
- Toggle ON → OFF round-trip on per-device: Mac A toggles OFF; Mac A stops pushing/applying; Mac B continues normal sync with peers.
- Destructive action round-trip: Mac A clicks "Delete from iCloud" + confirms; Mac B receives tombstone; Mac B transitions to `.pausedByRemote`; Mac B's local Keychain and ManagedKeyStore untouched.
- Master-key-not-yet-arrived path: Mac B starts with empty mock master-key store; receives payload; transitions to `.waitingForKey`; pre-load master key into Mock; trigger sync; `.waitingForKey` → `.enabled` and decrypt succeeds.
- AAD-mismatch path: stub mapping intentionally reorders fieldKind in the AAD; verify `AES.GCM.open` throws and apply aborts.
- Hard invariant: inject a Keychain write failure during apply; verify `commitHostCheckpoint` is not invoked and the next sync re-fetches.
- Bounded retry: simulate 3 sync passes that all fail decrypt; verify host moves to `corruptCredentials` and the user-visible fallback path is offered.
- **Add-host-with-credentials end-to-end** (review #1' regression guard): on Mac A with `state == .enabled` and `serverId` not yet allocated, call the form's add path; verify within a single sync cycle: dirty bit set → cycle runs → `.createRemote` first writes server record → `serverId` written back to local host → `.updateRemoteCredentials` queued after → push succeeds → dirty bit cleared. Mac B's next cycle decrypts and applies. Crash / restart between dirty-set and cycle-run: relaunch's first cycle still picks up the bit and pushes.
- **Toggle-ON forceFull replay** (review #2' regression guard): Mac A pushes `state="payload"` rev=5 → Mac B is `.disabled` → Mac B's incremental sync advances checkpoint past rev=5 record → user toggles ON on Mac B → `credentialsNeedFullScan = true` persisted → next cycle is forceFull → rev=5 payload re-fetched and applied. Verify forceFull happens even if Mac B was offline at toggle time and the flag survived the offline gap.

### Manual (deferred to Plan E pre-ship smoke, jointly with Plan B Phase 2 Task 2.5)

- Single-Mac CloudKit Dashboard simulation: edit a Host record's metadata in Dashboard, fresh-launch this Mac, observe credential decryption + ManagedKeyStore materialization on disk + Keychain entry creation. (Editing ciphertext directly in Dashboard is infeasible — it requires the master key — so the manual test focuses on the metadata-edit path with credentials already encrypted by another Caterm instance.)
- Real two-Mac live silent push round-trip in production environment (Distribution profile + Production CloudKit env), validating the full chain end-to-end.
- iCloud Keychain delivery latency under realistic conditions (Wi-Fi vs cellular vs locked device).

## Open questions tracked into implementation plan

- Concrete `EnvelopeCryptoAdapter` shape for testability (CryptoKit operations need a thin wrapper for in-process fakes that can simulate AAD mismatches, master-key absence, and corrupted ciphertext).
- Persistence schema for `lastAppliedRevision` map and `corruptCredentials` set (probably JSON in `SyncPreferences`).
- Whether the future "Push this Mac's credentials" action lands in v1 or v2 — depends on whether the "first device opts in but cloud is empty" path is acceptable (users edit a host to seed) or needs a primary affordance.
- Sandbox path implications when Caterm later moves to App Sandbox (the `~/Library/Application Support/Caterm/keys/` path remains valid inside the sandbox container).
- UI affordance for `corruptCredentials`: per-host indicator vs aggregated banner. Defer to UI implementation.

## Decision history

- **Rejected**: `CKRecord.encryptedValues`. Apple's iCloud data security overview confirms CloudKit encrypted fields are E2E only when ADP is enabled. Plan C's security promise of "Apple cannot decrypt by default" demands application-layer envelope encryption with the master key in iCloud Keychain (which is E2E unconditionally).
- **Rejected**: per-host opt-in for credential sync. v1 ships with one global toggle plus the destructive button. Per-host granularity may be added later.
- **Rejected**: writing managed keys into `~/.ssh/`. Caterm-managed location is `~/Library/Application Support/Caterm/keys/` to avoid colliding with user-owned ssh state.
- **Rejected**: continuous file-watching of source key files. User triggers re-import via host edit form.
- **Rejected**: combined toggle that both pauses and tombstones cloud. Split into per-device pause toggle (non-destructive) + explicit "Delete synced credentials from iCloud..." button (destructive, with confirmation).
- **Rejected**: nil-payload as tombstone signal. Adopted explicit `credentialBlobState: String` to distinguish `.agent` hosts (state="none") from cleared cloud (state="tombstone").
- **Rejected** (review #1): AAD bound to `host.id.uuidString`. Local UUIDs differ across devices because `addRemoteHost` allocates fresh IDs; AAD must use `host.serverId` (CKRecord `recordName`).
- **Rejected** (review #2): advancing `lastAppliedRevision` in `.disabled` and `.pausedByRemote`. That high-water mark would later suppress the same-revision payload on toggle ON; the two states now no-op on the high-water mark.
- **Rejected** (review #3): a single `encode(host:credentialBlob:)` that overloads metadata-only and credential-carrying writes. Replaced by three explicit encoders (`makeRecord`, `applyMetadata`, `applyCredentialBlob`) so metadata pushes physically cannot clobber credential fields.
- **Rejected** (review #4): "reject if target exists" semantics for `ManagedKeyStore.write`. Successive remote private-key updates would block; replaced with POSIX `rename(2)` atomic replace.
- **Rejected** (review #5): hooking `.updateRemoteCredentials` to `setCredentialOnly`. Doesn't cover the primary host add/edit form path. Adopted single `SessionStore.setHostCredentialMaterial` API that all UI credential-mutation paths funnel through.
- **Rejected** (review #6a): silently staying in `.waitingForKey` on tombstone arrival. Now transitions to `.pausedByRemote` so a fresh device can never wait forever for a key that was just deleted.
- **Rejected** (review #6b): resetting deleting device's `lastAppliedRevision` to 0 after destructive action. The device would consume its own tombstone on subsequent pull and self-pause; now sets `lastApplied = pushedTombstoneRev`.
- **Rejected** (review #7): `kSecAttrAccessibleAfterFirstUnlock` for the master key. The actual Apple constraint is "no `*ThisDeviceOnly` accessibility for synchronizable items"; `kSecAttrAccessibleWhenUnlocked` is permitted and is the tighter, correct choice given that every code path needing the master key runs while the device is unlocked.
- **Rejected** (review #1' / second pass): SyncOperation carrying raw secrets and a sync-aware entry-point API. `serverId == nil` at add time would silently drop the credential push (no replay) and op-borne secrets aren't durable across crashes. Replaced with `host.credentialMaterialDirty` persisted in hosts.json, scanned by HostSyncStore at every sync cycle and on `catermHostCredentialMaterialChanged` notification — secrets are read from Keychain + ManagedKeyStore live at push time. Brand-new hosts: dirty bit survives until the cycle's `.createRemote` writes back `serverId`, then `.updateRemoteCredentials` runs in the same cycle.
- **Rejected** (review #2' / second pass): "incremental sync may re-receive disabled records" reasoning. `HostSyncStore.swift:375` advances the `CKServerChangeToken` checkpoint after the op loop succeeds even when records were ignored under `.disabled`. Adopted `credentialsNeedFullScan` flag on `CredentialSyncPreferences`: every transition into `.enabled` sets it; HostSyncStore consumes it on next cycle by forcing `.forceFull`; cleared after that cycle's checkpoint commits.
- **Rejected** (review #3' / second pass): SessionStore deciding `CredentialSyncState` and emitting `SyncOperation`. `Package.swift:51-54` defines `HostSyncStore → SessionStore` (one-way); the proposed shape required the reverse and would have created a circular dependency. SessionStore now writes only the dirty bit and posts a typed Notification; HostSyncStore is the sole holder of state-machine policy and sync ops.
- **Rejected** (review #4' / second pass): leftover wording that `setCredentialOnly` retains its existing public semantics for the `CredentialSetupView` flow. The public API does not survive into Plan C v1; the `CredentialSetupView` callback collapses into one `setHostCredentialMaterial` call.
- **Rejected** (review #1'' / third pass): using `CKRecord.modificationDate` as the metadata `updatedAt` source. Apple bumps `modificationDate` on every save including credential-only saves, so credential rotations would masquerade as metadata updates and corrupt LWW. Adopted app-controlled `metadataUpdatedAt: Date?` field, written only by `applyMetadata` and `makeRecord`, read by `decode` with fallback to `creationDate` for legacy Plan A records.
- **Rejected** (review #2'' / third pass): two-branch queue policy ("`.enabled` AND serverId != nil" vs "`.enabled` AND serverId == nil"). Adopted single mechanism with queue-time predicate (`state == .enabled`) and executor-time predicate (`serverId != nil`). The credential op no-ops at execute time if `serverId` is still nil, leaving the dirty bit for next cycle. Mechanism handles brand-new hosts naturally without a "wait for serverId" branch.
- **Rejected** (review #3'' / third pass): synthesized `Codable` for `Host` after adding `credentialMaterialDirty`. Synthesized `init(from:)` requires the new key to be present in the JSON and would fail to decode any hosts.json written by a Plan A/B build. Adopted explicit `init(from:)` using `decodeIfPresent(...) ?? false` for the new field.
- **Rejected** (review #4'' / third pass): leaving pre-existing `credentialMaterialDirty` bits intact when the user runs the destructive "Delete from iCloud" action. Those dirty bits would be picked up by the next dirty scan and re-populate cloud immediately after the deletion. Destructive flow now atomically clears all dirty bits before pushing tombstones.
- **Rejected** (review #5'' / third pass): `HostSyncReconciler` producing `.updateRemoteCredentials` as part of its op set. The reconciler is Plan A's metadata-only diff engine; credential pushes are user-mutation-driven side-channel writes queued by HostSyncStore from a separate dirty scan, not by remote-vs-local diff.
- **Rejected** (review #1''' / fourth pass): decoder fallback chain `metadataUpdatedAt → creationDate`. A Plan A record with `creationDate=t0, modificationDate=t2` would decode as `updatedAt=t0`, letting a stale local `t1 < t2` win LWW and overwrite cloud. Adopted three-step fallback `metadataUpdatedAt → modificationDate → creationDate` plus a one-time-per-record seed step in the `.updateRemoteCredentials` executor that writes `metadataUpdatedAt = rec.modificationDate` BEFORE the first credential-only save can contaminate `modificationDate`.
- **Rejected** (review #2''' / fourth pass): destructive flow described as "atomic three steps" but actually consisting of multiple non-atomic disk + network operations. A crash or network failure mid-flight would lose delete intent and let a subsequent local edit re-populate cloud. Adopted durable `deleteCredentialsFromCloudInProgress: DeletionProgress?` field on `CredentialSyncPreferences`; HostSyncStore observes the flag at every cycle start, suppresses normal credential push, runs a resumable destructive sub-pipeline that decreases `pendingLocalHostIds` atomically with each tombstone success; clears the outer flag only when the list empties.
- **Rejected** (review #3''' / fourth pass): `.disabled` pull rule comment claiming the no-advance-lastAppliedRevision rule was justified by "incremental sync may re-receive". Wrong — checkpoint advances regardless, so incremental will not re-receive. Real reason rewritten in-place: lastAppliedRevision is the apply-time gate, separate from CKServerChangeToken's fetch-time gate. forceFull (driven by `credentialsNeedFullScan`) bypasses the fetch-time gate but still hits the apply-time gate; not advancing lastAppliedRevision in `.disabled` is what lets the post-toggle-ON forceFull replay correctly apply payloads that were ignored.
