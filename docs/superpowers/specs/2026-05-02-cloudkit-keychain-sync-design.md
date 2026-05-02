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
| Master key persistence | `kSecClassGenericPassword`, `kSecAttrSynchronizable=true`, `kSecAttrAccessible=kSecAttrAccessibleAfterFirstUnlock` (synchronizable items must use AfterFirstUnlock or weaker) |
| Master key service / account | service `com.caterm.cloudkit-sync.masterKey`, account `<credentialKeyID UUID>` |
| Ciphertext format | `AES.GCM.SealedBox.combined` (12-byte nonce ‖ ciphertext ‖ 16-byte tag) |
| Per-message nonce | random per-encrypt (handled by `CryptoKit.AES.GCM.seal`) |
| AAD (authenticated additional data, **not** encrypted but bound) | UTF-8 of `"\(hostId.uuidString)|\(fieldKind)|\(credentialBlobRevision)|\(schemaVersion)"` where `fieldKind ∈ {"password", "passphrase", "privateKey"}` and `schemaVersion = 1` for v1 |
| Algorithm versioning | `credentialCryptoVersion: Int64` field on the CKRecord. v1 = 1. Future bumps for KDF / cipher migration. |

**AAD binding rationale**: prevents replay of one host's ciphertext as another host's, swapping `password` ciphertext into the `privateKey` slot, and replaying old revisions over newer ones. Any of those mismatches → `AES.GCM.open` throws → handled per §Failure modes.

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
```

Schema is forward-compatible: old (Plan A/B) clients ignore unknown fields; absent fields decode to nil / "" / 0.

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

Previously, `SessionStore.addRemoteHost(_:)` defaulted incoming hosts to `.password`, and `setCredentialOnly(_:for:)` was the only path that changed credential variant — and that path was deliberately device-local with no remote propagation. Plan C extends this: when the pull side decrypts a `Host` record and the decrypted payload contains private key bytes, the receiving Mac **must** also flip its local `host.credential` from `.password` to `.keyFile(managedPath, hasPassphrase: blob.hasPassphrase)`. A new `SessionStore.applyRemoteCredential(blob:for:)` API does this atomically with the Keychain + ManagedKeyStore writes. `setCredentialOnly` retains its existing local-only semantics for the `CredentialSetupView` flow.

### KeychainStore — unchanged

Continues to use service `com.caterm.host`, accounts `<hostId>.<kind>`, access group `caterm.shared`, accessibility `kSecAttrAccessibleWhenUnlocked`, **`kSecAttrSynchronizable=false`**. iCloud Keychain stores only the master key, not the credentials themselves.

### `ManagedKeyStore` — new module

`apps/macos/Sources/ManagedKeyStore/ManagedKeyStore.swift`.

```swift
public actor ManagedKeyStore {
    public init(rootURL: URL = .applicationSupport.appending("Caterm/keys"))

    /// Atomically writes bytes to keys/<hostId>; returns the URL.
    /// Implementation: write to `<rootURL>/.tmp.<hostId>.<rand>`, fsync, rename.
    public func write(hostId: UUID, bytes: Data) throws -> URL

    public func read(hostId: UUID) -> Data?
    public func delete(hostId: UUID)                 // idempotent
    public func path(hostId: UUID) -> URL            // computed; file may not exist
}
```

**Filesystem hardening (mandatory):**
- Root directory created with mode `0o700`.
- Each file written with mode `0o600`.
- Atomic write: `O_CREAT | O_EXCL | O_WRONLY` to a tmp path inside the root, fsync, rename to target. Reject if target exists when writing — caller must `delete` first to overwrite.
- **Reject** any path that resolves (after `realpath`) outside `rootURL`. Reject paths containing `..` or symlinks. The tmp path generation never accepts user-provided strings.
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

Plus `lastAppliedRevision: [UUID: Int64]` (per-host high-water mark for incoming).

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

Triggered by:
- Local credential edit (host form submit; `CredentialSetupView` save) when state == `.enabled`.
- Toggle transition `disabled` / `pausedByRemote` → `.enabled` AND user explicitly chose "push my Mac's credentials" (separate action from the toggle itself; not on v1 critical path — see §Migration / future work).

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
        // ignore credential payload entirely; advance high-water mark.
        local.lastAppliedRevision[hostId] = remote.credentialBlobRevision

    case .pausedByRemote:
        // already paused; just track the freshest revision observed.
        local.lastAppliedRevision[hostId] = remote.credentialBlobRevision

    case .waitingForKey:
        // remember the keyID we need; retry on every sync until iCloud
        // Keychain delivers the key. Do not advance lastAppliedRevision.
        if remote.credentialBlobState == "payload":
            update observedKeyID := remote.credentialKeyID
        // else: tombstone or none — nothing to wait for; stay in waitingForKey
        // until user toggles off or the next payload arrives.

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

| Action | Behavior |
|--------|----------|
| Toggle OFF (per-device, default) → `.enabled` | If iCloud Keychain isn't reachable (probe via `KeychainSyncMasterKeyStore.loadAny()` failure to find existing key + system-level "iCloud Keychain enabled" check) → block transition with UI: "Enable iCloud Keychain in System Settings → Apple ID → iCloud → Passwords & Keychain". Otherwise: if a master key already exists in cloud → state → `.waitingForKey` until iCloud Keychain delivers it locally; if no master key anywhere AND no `state="payload"` records exist → generate fresh master key, state → `.enabled`. Pull cloud state and apply. **Do not auto-push local credentials over cloud.** |
| `.enabled` / `.waitingForKey` / `.pausedByRemote` → toggle OFF | State → `.disabled`. Stop pushing, stop applying incoming credentials. Cloud ciphertext untouched. Local Keychain and ManagedKeyStore untouched. |
| `.waitingForKey` → master key arrives via iCloud Keychain | State → `.enabled`. Re-run pull on next sync. |
| `.pausedByRemote` → toggle OFF then ON | Same path as `.disabled` → toggle ON: pull cloud state; if cloud is empty (all tombstones / `state="none"`), nothing applies locally, but the device is now active and any subsequent local edit will push. (Pushing existing local credentials to re-populate cloud requires a separate explicit "Push this Mac's credentials" action — out of v1 scope.) |
| Destructive button: "Delete synced credentials from iCloud..." | Confirmation modal: "This removes credentials from iCloud for ALL your devices. Each device keeps its local credentials. To re-enable sync afterward, enable the toggle on a device of your choice. Are you sure?" On confirm: for every host record, push `state="tombstone"`, `credentialBlobRevision=max+1`, all ciphertext fields nil. **Master key is left untouched in iCloud Keychain** (cheap to keep; user might re-enable). Local state on this Mac stays `.enabled`. Other Macs receive the tombstone and transition to `.pausedByRemote`. |

**Concurrent destructive action + ongoing edits**: while the destructive modal is open, the device should not accept credential edits (UI-level disable). Once tombstones are pushed, any concurrent edit from another device wins the LWW race per CloudKit's `serverRecordChanged` semantics.

### Conflict resolution

CloudKit's actual mechanism is `recordChangeTag` + `ifServerRecordUnchanged` save policy. Server returns `CKError.serverRecordChanged` (currently mapped to HTTP 409 by `CloudKitErrorMapping`) on stale writes. Plan A's existing behavior — and Plan C's — is "next sync trigger pulls latest record state, encoder re-encodes from current local Keychain, push retries naturally". There is no in-process refetch/merge/retry loop in v1; that would belong to a Plan A/B hardening exercise outside Plan C's scope.

For credentials specifically: race outcome is "last successful server-side write wins". Mac A and Mac B push different credentials in close succession → server accepts the first → second sees `serverRecordChanged` → on next sync, second pulls fresh state and re-encrypts current local; server now has the chronologically-second credential. The user observes "the device that pushed last wins", same as Plan A metadata.

## Sync flow integration

`HostSyncReconciler` produces the existing `SyncOperation` set (`.createRemote / .createLocal / .updateRemote / .updateLocal / .deleteLocal`), **plus a new `.updateRemoteCredentials(hostId)`** to address review #4: today, `SessionStore.setCredentialOnly` deliberately doesn't trigger any sync because credential changes are device-local. Plan C lifts that restriction when state == `.enabled` by emitting a `.updateRemoteCredentials(hostId)` operation alongside the existing local Keychain write. The existing `.updateRemote` op stays metadata-only; the new op carries the credential blob.

`CKRecordHostMapping`:
- `encode(host:credentialBlob:)` writes ciphertext + state + revision + keyID + cryptoVersion when the caller supplies a non-nil `credentialBlob`. Otherwise it leaves those fields nil and writes `state = "none"`, `revision = currentRev` (no bump for metadata-only changes).
- `decode(record:) -> RemoteHost` returns metadata plus optional `credentialBlob: CredentialBlob?` carrying ciphertext + revision + keyID + state + cryptoVersion.

`HostSyncStore`:
- The `apply()` step is extended with credential application via `SessionStore.applyRemoteCredential` per §Pull rules.
- The push side: `setCredentialOnly` now emits a `.updateRemoteCredentials` op when state == `.enabled`. The op carries the freshly-computed encrypted blob.
- Existing sync triggers (per-launch, push-driven, 60-min forceFull) all carry the credential plumbing for free.

## Lifecycle hooks

| Event | Local Keychain | ManagedKeyStore | Master key (synchronizable) | `lastAppliedRevision` |
|-------|---------------|-----------------|----------------------------|----------------------|
| Pull decrypt success | `set(account, secret)` | `write(hostId, bytes)` for privateKey | unchanged | advance for hostId |
| User edits host (form submit) | local-only update; if state == `.enabled`, also re-encrypts and emits `.updateRemoteCredentials` | re-reads source key file path; re-encrypts; pushes | unchanged | unchanged |
| Host deleted (local or remote) | `deleteAll(prefix: hostId)` | `delete(hostId)` | unchanged | drop `lastAppliedRevision[hostId]` |
| Toggle ON → OFF (per-device) | unchanged | unchanged | unchanged | unchanged |
| `.disabled` → toggle ON | unchanged | unchanged | look up; generate iff cloud is empty | unchanged |
| Destructive: "Delete synced credentials from iCloud..." (confirmed) | unchanged | unchanged | **unchanged** (not removed; cheap to keep for re-enable) | reset to 0 for all hosts (re-pull baseline after tombstone) |
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
- **First-time toggle ON**: per §Toggle transitions, defaults to pulling cloud state. Plan A users opting in for the first time on their first device will find cloud is empty → they remain in `.enabled` with no payload. To populate cloud, they need to either (a) edit a host (which triggers `.updateRemoteCredentials`) or (b) use the future "Push this Mac's credentials" action (out of v1 scope). v1 ships with this gap — users edit a host once to seed the cloud.

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

### Integration (in-process `FakeCloudDatabase` + mock `KeychainSyncMasterKeyStore` with two Caterm instances representing Mac A / Mac B)

- Push-decrypt round-trip: Mac A enables sync (generates master key), Mac B has the same master key pre-installed in its mock; Mac A edits credentials; Mac B decrypts and writes Keychain + ManagedKeyStore; Mac B's `host.credential` flips from `.password` to `.keyFile(managedPath, ...)`.
- Toggle ON → OFF round-trip on per-device: Mac A toggles OFF; Mac A stops pushing/applying; Mac B continues normal sync with peers.
- Destructive action round-trip: Mac A clicks "Delete from iCloud" + confirms; Mac B receives tombstone; Mac B transitions to `.pausedByRemote`; Mac B's local Keychain and ManagedKeyStore untouched.
- Master-key-not-yet-arrived path: Mac B starts with empty mock master-key store; receives payload; transitions to `.waitingForKey`; pre-load master key into Mock; trigger sync; `.waitingForKey` → `.enabled` and decrypt succeeds.
- AAD-mismatch path: stub mapping intentionally reorders fieldKind in the AAD; verify `AES.GCM.open` throws and apply aborts.
- Hard invariant: inject a Keychain write failure during apply; verify `commitHostCheckpoint` is not invoked and the next sync re-fetches.
- Bounded retry: simulate 3 sync passes that all fail decrypt; verify host moves to `corruptCredentials` and the user-visible fallback path is offered.

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
