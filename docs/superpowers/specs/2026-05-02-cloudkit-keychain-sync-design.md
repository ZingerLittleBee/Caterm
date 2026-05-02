# Plan C — CloudKit Keychain Sync (SSH Credentials)

**Date:** 2026-05-02
**Status:** Design approved, awaiting implementation plan
**Predecessors:**
- [Plan A — CloudKit Host Sync](../plans/2026-05-02-cloudkit-host-sync.md) (complete, commit `40fef64`)
- [Plan B — CloudKit Push Subscriptions](2026-05-02-cloudkit-push-subscriptions-design.md) (complete, commit `ca5b312`)

## Goal

Sync SSH credentials (passwords, key passphrases, private key file content) end-to-end encrypted across the user's iCloud-signed-in Macs so that adding a host on Mac A makes it immediately usable on Mac B without re-entering secrets or pre-staging the key file.

## Non-goals

- `known_hosts` (server fingerprint) sync — SSH's trust-on-first-use is already correct; cross-device fingerprint propagation creates phantom MITM warnings when machines see different network paths.
- Continuous file-watching of the user's source key file (e.g., `~/.ssh/id_rsa`) — credential bytes are captured at host add/edit time. To pick up an out-of-band rotation the user re-imports via the host edit form.
- Writing private keys into `~/.ssh/` — Caterm's managed keys live under `~/Library/Application Support/Caterm/keys/` to avoid colliding with user-owned ssh state.
- Cross-iCloud-account migration / standalone credential export / credential backup features.
- Per-host opt-in for credential sync. v1 is a single global toggle; per-host granularity may be added later if real users ask for it.

## Why

Plan A synced host metadata only (intentionally). New devices receive hosts but trigger `CredentialSetupView` on first connect — the user must re-enter every password and re-pick every key file. For password-auth hosts that's annoying; for key-auth hosts it's worse: if the new Mac doesn't already have the right private key file at the same path, the host can't connect at all. "Seamless" requires the key bytes to travel.

## High-level approach

Add three CloudKit-encrypted fields to the existing `Host` record (`encryptedPassword`, `encryptedKeyPassphrase`, `encryptedPrivateKey`) plus a monotonic integer `credentialBlobRevision`. Encrypted fields use `CKRecord.encryptedValues`, whose key is derived from iCloud Keychain — Apple cannot decrypt them.

Credential sync is gated by a single per-device toggle in Sync settings, **default OFF**. Turning it ON backfills current local credentials to CloudKit; turning it OFF tombstones the cloud copy (clears all encrypted fields, bumps `credentialBlobRevision`) without touching local Keychain or local managed key files. Tombstones propagate to other devices and put them in a `paused-by-remote` state until the user re-arms locally.

Because credential ciphertext lives on the same `Host` record as metadata, every push is an atomic CKRecord write. Plan A's last-writer-wins via `record.modificationDate` covers credential conflicts at no extra cost.

## Scope summary

| Synced | Mechanism | Per-device default |
|--------|-----------|--------------------|
| SSH password | CKRecord `encryptedValues["password"]` | OFF |
| Key passphrase | CKRecord `encryptedValues["keyPassphrase"]` | OFF |
| Private key file bytes | CKRecord `encryptedValues["privateKey"]` | OFF |
| Host metadata | (Plan A) plain CKRecord fields | ON (existing) |
| `known_hosts` | not synced | — |

## Data model

### `Host` CKRecord — new fields

```
encryptedPassword       : encryptedValues["password"]       (Data?,  CKEncryptedValue)
encryptedKeyPassphrase  : encryptedValues["keyPassphrase"]  (Data?,  CKEncryptedValue)
encryptedPrivateKey     : encryptedValues["privateKey"]     (Data?,  CKEncryptedValue)
credentialBlobRevision  : Int64                              (plain field, default 0)
```

Schema is forward-compatible: old (Plan A/B) clients ignore unknown fields. The Plan C client treats absent `credentialBlobRevision` as `0`.

### Field semantics

- `credentialBlobRevision == 0`: never had credential sync touch this record (Plan A baseline).
- All `encrypted*` fields == nil and `credentialBlobRevision > 0`: tombstone — credential sync was disabled by some device at this revision.
- Any `encrypted*` field != nil: that ciphertext is authoritative as of `credentialBlobRevision`. The other encrypted fields being nil simply means "no value of that kind" (e.g., a `.password` host has nil `encryptedKeyPassphrase` and nil `encryptedPrivateKey`).

### `CredentialSource` enum — unchanged

```swift
enum CredentialSource {
    case password
    case keyFile(keyPath: String, hasPassphrase: Bool)
    case agent
}
```

The enum still describes "what kind of credential this host uses". `keyPath` remains "where to find the key file on **this** Mac". hosts.json on Mac A and Mac B can legally have different `keyPath` values for the same host: Mac A keeps the user's original path (e.g. `~/.ssh/id_rsa`); Mac B has the Caterm-managed path (e.g. `~/Library/Application Support/Caterm/keys/<hostId>`). The CKRecord stores neither — it stores the encrypted bytes.

### KeychainStore — unchanged

Same service `com.caterm.host`, account format `<hostId>.<kind>` (`kind ∈ {password, keyPassphrase}`), access group `caterm.shared`, accessibility `kSecAttrAccessibleWhenUnlocked`, **`kSecAttrSynchronizable = false`**. Cross-device sync travels exclusively via CloudKit encrypted fields; iCloud Keychain is not used. Single sync path is easier to reason about than two parallel ones.

### `ManagedKeyStore` — new module

`apps/macos/Sources/ManagedKeyStore/ManagedKeyStore.swift` (~80 LoC).

```swift
public actor ManagedKeyStore {
    public init(rootURL: URL = .applicationSupport.appending("Caterm/keys"))

    public func write(hostId: UUID, bytes: Data) throws -> URL  // chmod 600, returns absolute URL
    public func read(hostId: UUID) -> Data?
    public func delete(hostId: UUID)                            // idempotent; ignores ENOENT
    public func path(hostId: UUID) -> URL                       // computed; file may not exist
}
```

### Per-device sync state — `CredentialSyncPreferences`

Stored alongside existing `SyncPreferences`. Three states:

```swift
enum CredentialSyncState {
    case disabled                      // toggle off; default
    case enabled                       // toggle on; push + pull active
    case pausedByRemote(seenRevision: Int64) // received tombstone; awaiting re-arm
}
```

Plus `lastAppliedRevision: [UUID: Int64]` (per-host high-water mark for incoming).

## Component layout

| Module | Additions |
|--------|-----------|
| `CloudKitSyncClient` | Extend `CKRecordHostMapping` to encode/decode encrypted fields + revision; extend the `IncrementalHostSyncClient` `RemoteHost` shape with optional `credentialBlob` payload. |
| `HostSyncStore` | Apply credential blob per `CredentialSyncState` rules; wire toggle ON/OFF actions; persist per-host `lastAppliedRevision`. |
| `ManagedKeyStore` | New module per above. |
| `Caterm` (UI) | Sync settings tab gains credential toggle + paused-by-remote banner. `CredentialSetupView` trigger conditions extended (decrypt failure / disk write failure → fallback). |

## State machine

Each device runs one of three states (`CredentialSyncPreferences`).

```
                  user toggles ON
       disabled  ─────────────────►  enabled
          ▲       ◄─────────────────    │
          │       user toggles OFF      │ receives tombstone (rev>last, encrypted*=nil)
          │       (push tombstone)      ▼
          │                          pausedByRemote
          │                              │
          └─── user toggles OFF ◄────────┤
                                         │
              user toggles ON  ──────────┘
              (re-arm: backfill from local)
```

### Push rules

Triggered when local credentials change (form submit) or when state transitions to `enabled` (one-shot backfill).

- `disabled` / `pausedByRemote`: do not push credentials. Metadata-only push continues per Plan A.
- `enabled`:
  - Read local Keychain (password / passphrase) and local key file bytes (if `.keyFile`).
  - Encode into `encryptedValues`. Bump `credentialBlobRevision = max(remoteRev, localRev) + 1`.
  - Push the same CKRecord that carries metadata (one CKModifyRecordsOperation, atomic).

### Pull rules

For each received Host record:

```
if remote.credentialBlobRevision <= local.lastAppliedRevision[hostId]:
    skip — stale message

else:  // remote is newer
    switch state:
    case .disabled:
        // ignore credential payload entirely; advance high-water mark so
        // we don't re-process the same delta after a future toggle ON.
        local.lastAppliedRevision[hostId] = remote.credentialBlobRevision

    case .pausedByRemote:
        // already paused; just track the freshest tombstone rev observed.
        local.lastAppliedRevision[hostId] = remote.credentialBlobRevision

    case .enabled:
        if all encrypted* == nil:
            // tombstone arrived from a peer; transition to paused.
            state → .pausedByRemote(seenRevision: remote.credentialBlobRevision)
            local.lastAppliedRevision[hostId] = remote.credentialBlobRevision
            do NOT touch local Keychain or ManagedKeyStore
        else:
            try decrypt:
                write password / passphrase to local Keychain
                write privateKey bytes via ManagedKeyStore.write
                rewrite hosts.json keyPath → ManagedKeyStore.path(hostId)
                local.lastAppliedRevision[hostId] = remote.credentialBlobRevision
            on decrypt failure:
                log
                do NOT advance lastAppliedRevision
                do NOT touch local state
                (next sync re-attempts; iCloud Keychain may catch up later)
```

### Toggle transitions

| Action | Behavior |
|--------|----------|
| `disabled` → `enabled` (user opt-in) | One-shot backfill: read every host's local Keychain + local key file, encrypt, push. Each record's `credentialBlobRevision++`. |
| `enabled` → `disabled` (user opt-out) | Tombstone push: for every host record, set `encrypted* = nil` and `credentialBlobRevision++`. Local Keychain + ManagedKeyStore remain untouched. |
| `pausedByRemote` → `enabled` (user re-arms locally) | Same as `disabled` → `enabled`: this Mac's local state is the new authoritative source. |
| `pausedByRemote` → `disabled` | No push needed (cloud is already tombstoned by a peer). Local toggle moves to off. |

### Conflict resolution

Already covered by Plan A's CAS: each CKRecord modification verifies `record.modificationDate` server-side. If two Macs push concurrently:

1. Server accepts the first; second receives `serverRecordChanged` error with the new server record.
2. Losing client refetches, re-merges its local state with the just-arrived remote, recomputes `credentialBlobRevision = serverRev + 1`, and retries.

The "user changed credentials on Mac A and Mac B nearly simultaneously" outcome is "last successful server-side write wins" — same as Plan A. There is no field-level merge; credentials are an indivisible blob per record.

## Sync flow integration

`HostSyncReconciler` produces the same `SyncOperation` enum (`.createRemote / createLocal / updateRemote / updateLocal / deleteLocal`). No new operation types.

`CKRecordHostMapping`:
- `encode(host:credentialSyncState:)`: writes encrypted fields when state == `.enabled` and the host has values to push (otherwise nil); always writes the matching `credentialBlobRevision`.
- `decode(record:) -> RemoteHost`: returns the metadata fields plus optional `credentialBlob: CredentialBlob?` carrying ciphertext + remote revision.

`HostSyncStore`:
- After `apply()` materializes the metadata, a separate "credential apply" step runs the §State machine pull rules for each affected host.
- Push side: when a host edit changes credentials, the flow already calls `apply(.updateRemote)`; encode pulls the latest local secrets at encode time (the encoder is the source of truth for "what to ship").

Existing sync triggers (per-launch, push-driven, 60-min forceFull) all carry the credential plumbing for free.

## Lifecycle hooks

| Event | KeychainStore | ManagedKeyStore | CredentialSyncPreferences |
|-------|---------------|-----------------|---------------------------|
| Decrypt success on incoming sync | `set(account, secret)` for password/passphrase | `write(hostId, bytes)` for privateKey | `lastAppliedRevision[hostId]` advanced |
| User edits host (form submit) | local-only update; if state == `.enabled`, also re-encrypts + pushes | re-reads source key file path, re-encrypts, pushes | unchanged |
| Host deleted (local or remote) | `deleteAll(prefix: hostId)` | `delete(hostId)` | drop `lastAppliedRevision[hostId]` |
| Toggle `.enabled` → `.disabled` | unchanged | unchanged | tombstone push for every host; state := `.disabled` |
| Toggle `.disabled` / `.pausedByRemote` → `.enabled` | unchanged | unchanged | re-encrypt + push every host; state := `.enabled` |
| iCloud account change (existing Plan B handler) | unchanged (Keychain is device-local) | wipe entire keys directory | clear all `lastAppliedRevision`; state := `.disabled` |

## UI changes

- **Sync settings tab**: new toggle "Sync SSH credentials across devices" (default OFF). When ON, status line "N hosts' credentials synced; end-to-end encrypted, Apple cannot read them".
- **Paused-by-remote banner**: shown at top of Sync settings when `state == .pausedByRemote`. Text: "Credential sync was disabled on another device. Re-enable here." Button re-arms (transitions to `.enabled` and triggers backfill).
- **Host edit form**: no visible change. Toggle is global; per-host badges would muddy the mental model.
- **`CredentialSetupView`** trigger condition extended: still fires on "local Keychain miss → connect attempt", and now additionally serves as the user-visible fallback when sync is enabled but the most recent decrypt failed or ManagedKeyStore write failed.

## Migration

- **Existing Plan A users on first launch with the Plan C build**: see new toggle, default OFF. Zero behavior change. All existing hosts stay exactly as they are. `credentialBlobRevision` for existing CKRecords is treated as 0 (absent field decodes to 0).
- **Schema migration**: none. CloudKit schema additions are backwards compatible — new fields appear lazily as records are written by Plan C clients. Old clients (Plan A/B) ignore them and keep working with the metadata fields only.
- **First-time toggle ON**: backfills all currently-tracked hosts. Hosts whose source key file has gone missing on disk: skip the `encryptedPrivateKey` field, still push password/passphrase if present, and surface a non-blocking warning in the form ("Couldn't read /Users/alice/.ssh/id_rsa — re-import to sync the key").

## Failure modes

| Scenario | Behavior |
|----------|----------|
| iCloud Keychain not yet ready on this device → CKEncryptedValue decrypt fails | Log; do not advance `lastAppliedRevision`; do not touch local state; retry next sync. UI does not raise an error (avoids noise during normal device-onboarding latency). User connecting falls back to `CredentialSetupView`. |
| Partial push during toggle (network blip mid-batch) | Persist a "pending toggle action" record in `CredentialSyncPreferences`. Next sync retries. Tombstone pushes are idempotent (writing nil + same-or-higher revision twice is a no-op on the record). |
| iCloud account change | Reuses Plan B `AccountIdentityTracker`. On user-record-name change: wipe `ManagedKeyStore` directory, clear `lastAppliedRevision[*]`, set `state = .disabled`. Local Keychain is untouched (Keychain is device-local). |
| User's source key file path no longer exists at edit time | Form-level error; that host's `encryptedPrivateKey` is skipped this push but password/passphrase still go. Other Macs decrypting the record see `encryptedPrivateKey == nil` → write Keychain only, no managed key file → user prompted by `CredentialSetupView` on first connect. |
| `ManagedKeyStore.write` fails (disk full, sandbox denial) | Log error; do not write Keychain (avoid half-state); do not advance `lastAppliedRevision`; user falls back to `CredentialSetupView`. |
| Local Keychain `set` fails (very rare; OS-level) | Same as above: don't advance; retry next sync. |
| Revision regression (race) | Server rejects via CAS on `record.modificationDate`. Client refetches, recomputes `rev = serverRev + 1`, retries. Same path as Plan A metadata conflict. |

## Testing

### Unit

- `ManagedKeyStoreTests`: write/read/delete/`chmod 600` enforcement; path-only computation when file absent; idempotent delete; root creation.
- `CredentialBlobMappingTests`: encode → CKRecord encryptedValues + revision; decode → `CredentialBlob`. Round-trip with CKRecord fixture.
- `CredentialSyncStateMachineTests`: every transition in the state diagram. Push/pull predicate per state. Tombstone arrival from any state.
- `RevisionMonotonicTests`: stale-revision drop, tombstone-revision-induced state transition, backfill revision is `max(remote, local) + 1`.

### Integration (in-process `FakeCloudDatabase` with two `CloudKitSyncClient` instances representing Mac A / Mac B)

- Push-decrypt round-trip: Mac A enables sync, edits credentials, Mac B decrypts and writes Keychain + ManagedKeyStore.
- Toggle ON → OFF round-trip: Mac A toggles ON (backfill), Mac B observes ciphertext + applies. Mac A toggles OFF, Mac B observes tombstone, transitions to `.pausedByRemote`, retains its local Keychain.
- Decrypt-failure path: inject a stub `EncryptedValuesAdapter` that throws on decrypt. Verify no Keychain mutation, no `lastAppliedRevision` advance.
- Host delete: ManagedKeyStore + Keychain both cleaned.
- iCloud account change: `AccountIdentityTracker` triggers ManagedKeyStore wipe and credential preferences reset.

### Manual (deferred to Plan E pre-ship smoke, jointly with Plan B Phase 2 Task 2.5)

- Single-Mac CloudKit Dashboard simulation: edit a Host record's `encryptedValues` (Dashboard supports this), fresh-launch this Mac, observe credential decryption + ManagedKeyStore materialization on disk + Keychain entry creation.
- Real two-Mac live silent push round-trip in production environment (Distribution profile + Production CloudKit env), validating the full chain end-to-end.

## Open questions tracked into implementation plan

- Concrete `EncryptedValuesAdapter` shape for testability (CloudKit's `encryptedValues` is concrete on `CKRecord`; we need a thin wrapper to inject in-process fakes).
- Naming of the `CredentialSyncState` UserDefaults key and the persistence schema for `lastAppliedRevision` map.
- Whether to expose a "credential sync is currently working" indicator on individual host rows or keep it strictly in Sync settings (defer until UI implementation; default to "Sync settings only").
