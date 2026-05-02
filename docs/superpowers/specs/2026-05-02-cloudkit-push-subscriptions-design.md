# Plan B — CloudKit Push Subscriptions + Incremental Sync

**Date:** 2026-05-02
**Status:** Design approved, awaiting implementation plan
**Predecessor:** [Plan A — CloudKit Host Sync](../plans/2026-05-02-cloudkit-host-sync.md) (complete, commit `40fef64`)

## Goal

Replace the 15-minute polling timer in `HostSyncStore` with CloudKit silent push (`CKDatabaseSubscription`) and migrate the read path from full re-list to `CKServerChangeToken`-based incremental fetch. Keep a 60-minute timer as a reconciliation safety net.

## Non-goals

- Conflict resolution on writes (Plan A's reconciler still wins last-writer; deferred to a later plan if needed).
- Migrating other record types (credentials / settings / SFTP bookmarks) — those are Plans C / D / E.
- User-visible notifications. All push is silent (`shouldSendContentAvailable = true`, no alert / sound / badge).

## Why

- Plan A's 15-minute polling means a Mac can be up to 15 minutes out of date when another device changes a host. With push, latency is seconds.
- Full `listHosts` per cycle wastes work and won't scale once Plans C–E add more record types. `CKServerChangeToken` is the CloudKit-native pattern.

## Implementation Cadence

Three independently shippable steps. Risks are split so configuration (APS / provisioning) and code (incremental reconciler) can fail without blocking each other.

### Step 0 — Spike

Goal: prove silent push can actually reach this dev Mac. Plan A's lesson was "Apple-config-class problems first".

Deliverables:
- `aps-environment=development` added to `apps/macos/Resources/Caterm.entitlements`.
- Mac App Development provisioning profile re-enabled with Push Notifications capability in Apple Developer Portal, re-downloaded.
- Throwaway code (a debug button or temporary CLI target) registers a `CKDatabaseSubscription` and logs receipt of remote notification.
- Manual verification: change a `Host` record in CloudKit Dashboard, confirm `application(_:didReceiveRemoteNotification:)` fires on the dev Mac.

Exit criteria:
- ✅ Push received → continue with Step 1.
- ❌ Push not received after debugging → fall back to Plan B-degraded (Step 1 only, keep timer at 15 minutes).

### Step 1 — B1: Incremental Sync Refactor (no APS dependency)

Pure code change. Timer stays at 15 minutes. Useful even if Step 2 is delayed by config issues.

- Add `ServerChangeTokenStoring` (internal to `CloudKitSyncClient` module) + `UserDefaultsServerChangeTokenStore` default impl. **Not exposed on the protocol surface** — only `CloudKitSyncClient` and its tests reference it.
- Extend `CKDatabaseProtocol` with `fetchDatabaseChanges`, `fetchZoneChanges`, `saveSubscription`, `deleteSubscription`. Update `FakeCloudDatabase`.
- Add `IncrementalHostSyncClient` protocol in the `ServerSyncClient` module exposing `preferredHostSyncMode`, `fetchHostChanges`, `fetchHostSnapshotAndCheckpoint`, `commitHostCheckpoint`, `resetHostSyncState`, `ensureHostSubscription`, `deleteHostSubscription`. `HostChangeBatch` carries an opaque `HostSyncCheckpoint`. `CloudKitSyncClient` conforms; drains DB-level and zone-level pagination internally before returning.
- `commitHostCheckpoint` is the only path that persists tokens. Fetch never advances tokens.
- Add `CloudKitSyncClient.fetchHostSnapshotAndCheckpoint()` (full snapshot via `CKFetchDatabaseChangesOperation(nil)` + `CKFetchRecordZoneChangesOperation(nil)`, drained fully, checkpoint deferred to commit). `listHosts()` stays as-is for any non-checkpointed callers but is **not** used by `HostSyncStore.forceFull` anymore.
- Add `HostSyncReconciler.reconcileDelta(local:changedHosts:deletedHostIDs:) -> [SyncOperation]` in domain types (no `CloudKit` import). Rename existing reconcile path to `reconcileFullSnapshot(local:remote:)`.
- Change `HostSyncStore.client` declared type to `IncrementalHostSyncClient`. Add `sync(mode:)` flow that asks the client for `preferredHostSyncMode()`, calls fetch, applies, then `commitHostCheckpoint`. Token-expired, zone-not-found, and per-zone token failures handled per §Error Handling.

### Step 2 — B2: Push Subscription + Timer Widening

Depends on Step 0 success and Step 1 merged.

- Add `CloudKitSyncClient.ensureHostSubscription()` (idempotent) and `deleteHostSubscription()` (for account sign-out).
- Extend the **existing** `apps/macos/Sources/Caterm/AppDelegate.swift` with `registerForRemoteNotifications` + `application(_:didReceiveRemoteNotification:)` + `application(_:didFailToRegisterForRemoteNotificationsWithError:)`. Do not introduce a second AppDelegate.
- Add `AccountIdentityTracker` to `CloudKitSyncClient` module; rewire the `.catermICloudAccountChanged` handler in `CatermApp` to compare current vs prior `userRecordID` before clearing tokens.
- AppDelegate dispatches matching `CKNotification` as `.catermCloudKitHostChanged` via `NotificationCenter`.
- `HostSyncStore` observes `.catermCloudKitHostChanged` and triggers incremental sync.
- Change `periodicInterval` init default from `15 * 60` to `60 * 60`. Periodic tick uses `mode: .forceFull` for reconciliation. (Constructor remains injectable for tests.)

## Components

### `ServerChangeTokenStoring` (new, **internal** to `CloudKitSyncClient` module)

File: `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`

```swift
internal struct StoredServerChangeToken: Equatable, Sendable {
    let archivedData: Data            // NSKeyedArchiver(requiringSecureCoding: true)
    init(archivedData: Data) { self.archivedData = archivedData }

    // throws-based archive/unarchive — never try!.
    static func archive(_ token: CKServerChangeToken) throws -> StoredServerChangeToken {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: token, requiringSecureCoding: true
        )
        return StoredServerChangeToken(archivedData: data)
    }
    func unarchive() throws -> CKServerChangeToken {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self, from: archivedData
        ) else {
            throw ServerChangeTokenError.unarchiveReturnedNil
        }
        return token
    }
}

internal enum ServerChangeTokenError: Error {
    case unarchiveReturnedNil
    case corruptPersistedData
}

internal struct TokenCAS: Sendable {
    let prev: Data?      // archivedData snapshot at fetch start (may be nil)
    let new: Data?       // archivedData to write (may be nil to clear)
}

internal enum CommitOutcome: Sendable, Equatable {
    case applied
    case staleEpoch
    case partialCAS(skippedZoneKeys: [String], skippedDb: Bool)
}

internal protocol ServerChangeTokenStoring: Sendable {
    /// Generation counter. Bumped by clearAll() and bumpEpoch().
    /// commitTokens compares against the value snapped at fetch start
    /// inside the same critical section as the writes.
    func currentEpoch() async -> UInt64
    func bumpEpoch() async

    func loadDatabaseToken() async -> StoredServerChangeToken?
    func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken?

    /// Atomic compound CAS. The implementation MUST run "epoch check +
    /// per-token CAS writes" as a single critical section — no
    /// resetHostSyncState / clearAll / bumpEpoch may interleave.
    func commitTokens(expectedEpoch: UInt64,
                      db: TokenCAS,
                      zones: [String: TokenCAS]) async -> CommitOutcome

    /// Bumps epoch AND deletes db/zone keys atomically (single critical
    /// section).
    func clearAll() async
}
```

**Atomicity contract.** `commitTokens`, `clearAll`, and `bumpEpoch` are mutually exclusive. The default impl is an `actor` (each call is automatically serialized); other impls must use a lock or serial queue. The race-condition fix from the third pass relied on the epoch check being in the same critical section as the writes — exposing the CAS as a single compound method instead of "check epoch, then call save*" closes the window where reset could land between the check and the writes.

- Not part of the public surface. Only `CloudKitSyncClient` and its tests reference it. `HostSyncStore` does **not** see token storage at all (boundary fix).
- Default impl: `UserDefaultsServerChangeTokenStore` declared as `actor` (Swift's actor isolation provides the serial-queue guarantee for free).
  - Database token key: `"cloudkit.changeToken.database"`.
  - Zone token key: `"cloudkit.changeToken.zone.<zoneName>.<ownerName>"`.
  - Epoch key: `"cloudkit.changeToken.epoch"` (stored as `UInt64` in `UserDefaults`; defaults to 0 on first read).
  - Tokens persisted as `Data` (the `archivedData` field). Comparing tokens for CAS = `Data == Data`.
  - `loadDatabaseToken` / `loadZoneToken`: read raw `Data` from UserDefaults and wrap in `StoredServerChangeToken`. **Never decodes the inner `CKServerChangeToken` synchronously**, so corrupt persisted bytes don't crash on load. Decoding happens lazily via `unarchive()` in the rare path that actually needs the live token (handing it to a CKFetch* op). On `unarchive()` failure: log, treat as if the token were absent, the calling fetch path falls back to `forceFull`.
  - `clearAll()` is implemented as a single actor method: writes epoch+1, then deletes db/zone keys, returns. Observers reading mid-transition is impossible because actor isolation serializes all access.
- Test impl: `InMemoryServerChangeTokenStore` (also an actor; dictionary + `UInt64` counter).

### `CKDatabaseProtocol` additions

The current protocol (`apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift`) has only `query / save / delete / record / zone-save`. Plan B needs four new async façade methods so `CloudKitSyncClient` doesn't bypass the protocol and `FakeCloudDatabase` stays the single test seam:

```swift
public protocol CKDatabaseProtocol: Sendable {
    // existing methods...

    func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
        async throws -> (changedZoneIDs: [CKRecordZone.ID],
                         deletedZoneIDs: [CKRecordZone.ID],            // user-deleted zone
                         purgedZoneIDs: [CKRecordZone.ID],              // server-side purge
                         encryptedDataResetZoneIDs: [CKRecordZone.ID],  // user reset their iCloud encryption
                         newToken: CKServerChangeToken?,
                         moreComing: Bool)

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          previousServerChangeToken: CKServerChangeToken?)
        async throws -> (changedRecords: [CKRecord],
                         deletedRecords: [(CKRecord.ID, CKRecord.RecordType)],
                         newToken: CKServerChangeToken?,
                         moreComing: Bool)

    func saveSubscription(_ subscription: CKSubscription) async throws -> CKSubscription
    func deleteSubscription(withID id: CKSubscription.ID) async throws -> CKSubscription.ID
}
```

`CKDatabase` extension provides default impls bridging to `CKFetchDatabaseChangesOperation` / `CKFetchRecordZoneChangesOperation` / `CKModifySubscriptionsOperation` (the async overloads added in iOS 15 / macOS 12 cover save+delete subscription; for changes operations we wrap the completion-block API in `withCheckedThrowingContinuation`).

The four DB-changes zone-callback signals are accumulated separately:
- `recordZoneWithIDChangedBlock` ⇒ `changedZoneIDs`
- `recordZoneWithIDWasDeletedBlock` ⇒ `deletedZoneIDs`
- `recordZoneWithIDWasPurgedBlock` ⇒ `purgedZoneIDs`
- `recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock` ⇒ `encryptedDataResetZoneIDs`

`FakeCloudDatabase` adds:
- `enqueueDatabaseChanges(changedZoneIDs:deletedZoneIDs:purgedZoneIDs:encryptedDataResetZoneIDs:newToken:moreComing:)` — keep all four bins so tests can exercise each.
- `enqueueZoneChanges(zoneID:changedRecords:deletedRecords:newToken:moreComing:)`
- `simulateError(_:on:)` for injecting `CKError.changeTokenExpired`, `notAuthenticated`, etc.
- `recordedSubscriptions: [CKSubscription]`, `deletedSubscriptionIDs: [CKSubscription.ID]`

### `IncrementalHostSyncClient` protocol (new)

`HostSyncStore` must not depend on `CloudKitSyncClient` directly. The store currently types its dependency as `ServerSyncClient` (`apps/macos/Sources/HostSyncStore/HostSyncStore.swift:88`); we add a refinement protocol so the store stays in domain types and **never reads/writes tokens itself**.

File: `apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift`

```swift
public enum HostSyncMode: Sendable { case incremental, forceFull }

/// Opaque marker protocol. Concrete checkpoint types live inside the
/// concrete client implementation (e.g. CloudKitSyncClient.Checkpoint).
/// HostSyncStore treats values as fully opaque — it only round-trips
/// them from `fetch*` to `commitHostCheckpoint`. Conformers carry
/// implementation-private state.
public protocol HostSyncCheckpoint: Sendable {
    /// Stable identity for tests / logs. Implementation-defined; do
    /// not interpret outside the issuing client.
    var id: UUID { get }
}

public struct HostChangeBatch: Sendable {
    public let changedHosts: [RemoteHost]
    public let deletedHostIDs: [String]      // RemoteHost.id (== recordName); Host-typed deletions only
    public let checkpoint: (any HostSyncCheckpoint)?  // nil iff tokenExpired
    public let tokenExpired: Bool
    public let mode: HostSyncMode            // which path produced this batch
}

public protocol IncrementalHostSyncClient: ServerSyncClient {
    /// Returns the mode the store should use right now. Backed by the
    /// client's internal token state — store does not touch tokens.
    func preferredHostSyncMode() async -> HostSyncMode

    /// Drains DB-level moreComing AND zone-level moreChanges fully
    /// before returning. The returned checkpoint is NOT persisted yet —
    /// caller commits after applying ops locally.
    func fetchHostChanges() async throws -> HostChangeBatch

    /// Full snapshot path (replaces listHosts for forceFull). Drains
    /// fully like fetchHostChanges. Returned checkpoint reflects the
    /// state of the world at fetch time.
    func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch

    /// Persists the checkpoint. Throws CheckpointStaleError silently
    /// (no state change) if the checkpoint's epoch no longer matches —
    /// see "Reset/commit race" below. Otherwise idempotent (committing
    /// the same checkpoint twice is a no-op). Called by HostSyncStore
    /// only after reconcile + apply ops succeed.
    func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws

    /// Used by AccountIdentityTracker on real account change to wipe
    /// state. Resets the internal token store + bumps the checkpoint
    /// epoch so any in-flight commit is rejected as stale.
    func resetHostSyncState() async

    func ensureHostSubscription() async throws       // idempotent
    func deleteHostSubscription() async throws       // idempotent (unknownItem treated as success)
}
```

Notes:
- `RemoteHost` and `String` are the only payload types crossing the boundary. `CKRecord` is fully encapsulated in `CloudKitSyncClient`.
- `HostSyncCheckpoint` is a marker protocol with `id: UUID` only. The concrete checkpoint type (e.g. `CloudKitSyncClient.Checkpoint`) is `internal` to its module and carries implementation-private state. `commitHostCheckpoint` downcasts to the concrete type the implementation owns; foreign checkpoints are rejected (treated as stale). This avoids the public/internal compilation issue where a `public struct` with `internal` payload would not be constructable from another module.
- `HostSyncStore` never holds a `ServerChangeTokenStoring` reference. It asks the client for `preferredHostSyncMode()` and hands back checkpoints via `commitHostCheckpoint`.

### `CloudKitSyncClient` (extended)

Conforms to `IncrementalHostSyncClient`. Owns the `ServerChangeTokenStoring` reference and the concrete checkpoint type:

```swift
extension CloudKitSyncClient {
    internal struct Checkpoint: HostSyncCheckpoint {
        let id: UUID
        let epoch: UInt64                          // matches tokenStore.currentEpoch at fetch start
        let prevDb: Data?                          // NSKeyedArchiver-archived prior token, or nil
        let newDb:  Data?                          // archived new token at drain end
        let prevZones: [String: Data?]             // keyed by CKRecordZone.ID stringified
        let newZones:  [String: Data?]
    }
}
```

**Comparable token form.** `CKServerChangeToken` is opaque and not `Equatable`. The internal `ServerChangeTokenStoring` therefore returns and stores tokens as `StoredServerChangeToken { archivedData: Data }` (definition above in §`ServerChangeTokenStoring`); decoding is `throws` via `unarchive()` — never `try!`. CAS in `commitTokens` compares `Data` values, which is what makes the CAS work.

CAS in `commitHostCheckpoint` compares `Data` values, which are trivially `Equatable`. The store also tracks a monotonically increasing `currentEpoch: UInt64` used to defeat the reset/commit race below.

**Pagination contract.** Both `fetchHostChanges` and `fetchHostSnapshotAndCheckpoint` drain to completion before returning. Two distinct concepts must NOT be conflated:

- `operationPreviousToken*`: passed to the CloudKit op. `nil` for `forceFull`, the persisted token for `incremental`. When persisted bytes are corrupt, also `nil`.
- `casPrevious*Archive`: snapshot of the persisted `archivedData` at fetch start (or `nil` if absent). Always captured, both modes — this is what `commitTokens` compares against. **For `forceFull` with an existing persisted token, `casPreviousArchive` is the existing archive, not `nil`** — otherwise the CAS at commit time would see `persisted != nil ≠ prev nil` and skip writing the fresh token, leaving the periodic full-sync tick unable to ever refresh the checkpoint.

```
fetchEpoch := await tokenStore.currentEpoch()
persistedDb := await tokenStore.loadDatabaseToken()         // captured both modes
casPreviousDbArchive := persistedDb?.archivedData            // commit CAS prev (both modes)
operationPreviousDbToken := (mode == .incremental) ? (try? persistedDb?.unarchive()) : nil
                                                             // CloudKit op prev (nil on forceFull
                                                             // OR on unarchive failure)

casPreviousZoneArchives: [zoneID: Data?] := {}               // captured both modes; Data? lets us
                                                             // record "absent" distinct from "missing entry"
pendingZoneTokens: [zoneID: StoredServerChangeToken] := {}
deletedZoneIDs / purgedZoneIDs / encryptedResetZoneIDs := {}

databaseLoop:
  (changedZones, dbDeletedZones, dbPurgedZones, dbEncryptedResetZones, dbToken, dbMore)
      = fetchDatabaseChanges(operationPreviousDbToken)
  // accumulate zone-status sets

  for zoneID in changedZones:
      // Capture CAS prev archive once at fetch start (BOTH modes).
      if casPreviousZoneArchives[zoneID] == .none {
          let persistedZone = await tokenStore.loadZoneToken(zoneID)
          casPreviousZoneArchives[zoneID] = persistedZone?.archivedData     // may be nil
          let opPrevZoneToken = (mode == .incremental)
              ? (try? persistedZone?.unarchive())
              : nil
          var rollingZoneToken: CKServerChangeToken? = opPrevZoneToken
          zoneLoop:
            (recs, dels, zoneToken, zoneMore)
                = fetchZoneChanges(zoneID, rollingZoneToken)
            // recordType filter — Host-only.
            accumulate Host-typed records / Host-typed deletes
            rollingZoneToken := zoneToken
            if zoneMore { continue zoneLoop }
          if let final = rollingZoneToken {
              pendingZoneTokens[zoneID] = StoredServerChangeToken.archive(final)  // throws → log
          }
      }
      // (else: this zone already drained in a prior databaseLoop iteration; skip.)

  // Roll the database operation prev forward for the next loop iteration.
  operationPreviousDbToken := dbToken
  if dbMore { continue databaseLoop }

// Build checkpoint. NOTE prevDb / prevZones come from casPrevious*, not from operationPrevious*.
let newDbArchive = dbToken.flatMap { try? StoredServerChangeToken.archive($0).archivedData }
let prevZonesForCAS: [String: Data?] = casPreviousZoneArchives.mapKeys { stringify($0) }
let newZonesForCAS:  [String: Data?] = pendingZoneTokens.mapValues { $0.archivedData }
                                                       .mapKeys  { stringify($0) }
return Checkpoint(id: UUID(), epoch: fetchEpoch,
                  prevDb: casPreviousDbArchive, newDb: newDbArchive,
                  prevZones: prevZonesForCAS, newZones: newZonesForCAS)
```

If any `unarchive()` throws (corrupt persisted bytes), log + treat the operation prev as `nil` (CloudKit op runs as if the token were absent → effectively `forceFull` for that scope). The corrupt `archivedData` stays in `casPrevious*Archive`, so the subsequent successful commit's CAS sees `persisted == casPrev` (both equal the corrupt bytes) and replaces with the fresh archive. **Never `try!`.**

After the drain loop, **deleted / purged / encrypted-reset zone handling**:
- If the Caterm zone (`CKRecordZone.ID(zoneName: "Caterm", ...)`) appears in **any** of `deletedZoneIDs`, `purgedZoneIDs`, or `encryptedResetZoneIDs`: short-circuit. Wipe the Caterm zone token (via a no-CAS direct path, or via a `commitTokens` call with `prev: <whatever>, new: nil` — either is fine because we're already in the actor) and return `HostChangeBatch(checkpoint: nil, tokenExpired: true, ...)` with empty records. The store retries `forceFull`. The forceFull path will see no records (zone is gone) and reconcile against an empty remote, which deletes locally orphaned hosts naturally — no need for the client to know what's local.
- Other zones in those sets are simply ignored (we don't own them).

Otherwise build the checkpoint:
- `Checkpoint(id: UUID(), epoch: fetchEpoch, prevDb: prevDbArchive, newDb: finalDbTokenArchive, prevZones: …, newZones: …)`
- **Do NOT persist** to `ServerChangeTokenStoring` yet. Persistence happens in `commitHostCheckpoint`. This fixes the "fetch advanced token but apply failed → records lost" risk.

`fetchHostSnapshotAndCheckpoint()` runs the drain loop with all `prev*Token := nil`. Returns `mode: .forceFull`.

`fetchHostChanges()` runs the drain loop reading current persisted tokens. Returns `mode: .incremental`.

**`commitHostCheckpoint(_:)`** — single atomic CAS via `tokenStore.commitTokens`:

```swift
func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
    guard let cp = checkpoint as? Checkpoint else { return }   // foreign: silent reject

    let dbCAS = TokenCAS(prev: cp.prevDb, new: cp.newDb)
    var zoneCASes: [String: TokenCAS] = [:]
    for (zoneID, newArchive) in cp.newZones {
        let prevArchive = cp.prevZones[zoneID] ?? nil
        zoneCASes[zoneID] = TokenCAS(prev: prevArchive, new: newArchive)
    }

    let outcome = await tokenStore.commitTokens(
        expectedEpoch: cp.epoch, db: dbCAS, zones: zoneCASes
    )

    switch outcome {
    case .applied:                       break
    case .staleEpoch:                    log.info("checkpoint stale by epoch")
    case .partialCAS(let zones, let db): log.info("CAS skipped: zones=\(zones) db=\(db)")
    }
}
```

The store-side `commitTokens` runs the epoch check **and** the per-token CAS writes inside one critical section (actor isolation in the default impl). `resetHostSyncState` / `clearAll` / `bumpEpoch` are isolated against the same actor, so they cannot interleave between the epoch check and the writes. This closes the gap the previous "check-then-write" formulation left open.

Idempotency follows from the per-token CAS: committing the same `Checkpoint` twice — the second pass sees `persisted == cp.newDb` (not `cp.prevDb`) ⇒ skip with `partialCAS`.

`preferredHostSyncMode()`:
- `await tokenStore.loadDatabaseToken() != nil ⇒ .incremental`, else `.forceFull`.

`recordWithIDWasDeletedBlock` filters by the `CKRecord.RecordType` parameter passed in: only `"Host"` deletions feed `deletedHostIDs`. This guards against future Plans C/D/E adding records to the same zone.

`CKError.changeTokenExpired` handling:
- DB-level: clear db token via `commitTokens(expectedEpoch: fetchEpoch, db: TokenCAS(prev: <captured>, new: nil), zones: [:])`, return `HostChangeBatch(checkpoint: nil, tokenExpired: true, ...)`. Store retries `forceFull`. (If `commitTokens` returns `staleEpoch`, no harm — reset already cleared everything.)
- Zone-level: same shape with `zones: [zoneID: TokenCAS(prev: <captured>, new: nil)]`.

`resetHostSyncState()`:
- `await tokenStore.clearAll()` — single actor method that bumps epoch and deletes db / zone keys atomically. No separate `bumpEpoch()` call needed externally.
- Does **not** cancel in-flight drain operations explicitly. The epoch CAS is enough: any in-flight commit becomes `staleEpoch` and silently skipped; the next sync starts fresh.

`ensureHostSubscription()` internals:
- `CKDatabaseSubscription(subscriptionID: "caterm.host.changes.v1")`, `recordType = "Host"`.
- `notificationInfo.shouldSendContentAvailable = true`. No alert / sound / badge.
- On save failure, inspect `CKError.partialFailure.partialErrorsByItemID`. If the only error is `serverRejectedRequest` indicating the subscription already exists, treat as success. Otherwise propagate.

`deleteHostSubscription()`: calls `database.deleteSubscription(withID:)`. `CKError.unknownItem` is treated as success (idempotent).

### Reset/commit race (race-condition fix)

Without an atomic critical section, this sequence corrupts state:

1. Sync A starts a `forceFull` fetch (`prevDb := nil`, captures `epoch_0`).
2. Sync A finishes fetching, builds checkpoint, calls `commitHostCheckpoint`.
3. Inside commit, **after** epoch check passes but **before** writes — user signs out / signs into a different account.
4. `AccountIdentityTracker` calls `resetHostSyncState()` → `clearAll()` bumps epoch to `epoch_1` and clears keys.
5. Sync A's commit, having passed step 3's check, would then write `cp.newDb` back into the cleared state.

The fix is to make the epoch check **and** the writes a single critical section in the token store actor. Step 3 cannot occur inside that section because actor methods are serialized: `clearAll` must wait for `commitTokens` to return, by which point the epoch has been re-checked under isolation. Reverse ordering (clearAll runs first) leaves the commit attempting to write at `epoch_0` but seeing `currentEpoch == epoch_1` ⇒ `staleEpoch`. Either way, no data corruption.

This is the reason `commitTokens` is exposed as a single compound method on `ServerChangeTokenStoring` rather than as separate `currentEpoch` / `saveDatabaseToken` / `saveZoneToken` calls.

### `HostSyncReconciler` (extended)

Stays in domain types. No `CloudKit` import added.

- Existing `reconcile(local:remote:)` (`HostSyncReconciler.swift:9`) renamed to `reconcileFullSnapshot(local:remote:)`. Behavior unchanged. Returns `[SyncOperation]`.
- New `reconcileDelta(local: [SSHHost], changedHosts: [RemoteHost], deletedHostIDs: [String]) -> [SyncOperation]`:
  - For each `RemoteHost` in `changedHosts`: emit upsert op into local set keyed by id.
  - For each id in `deletedHostIDs`: emit delete op for that local id.
  - Return type matches `reconcileFullSnapshot`: `[SyncOperation]`. `HostSyncStore`'s apply path is unchanged.

### `HostSyncStore` (modified)

- Change `client` declared type from `ServerSyncClient` to `IncrementalHostSyncClient` (`HostSyncStore.swift:88`, `:136`). Existing tests that pass a fake `ServerSyncClient` must update the fake to conform. **No `ServerChangeTokenStoring` injection on the store.**
- Subscribe to `.catermCloudKitHostChanged` in init. Tear down in deinit.
- Add `enum SyncMode { case auto; case forceFull; case incremental }` (the store's local enum; `HostSyncMode` from the protocol is the client-side equivalent).
- `sync(mode: SyncMode = .auto)` flow:
  1. Resolve effective mode: `auto` → `await client.preferredHostSyncMode()` translated 1-1; otherwise honor parameter.
  2. Call `fetchHostChanges()` or `fetchHostSnapshotAndCheckpoint()` accordingly.
  3. If `batch.tokenExpired` ⇒ retry once with `mode: .forceFull` (single retry; further failures bubble up to `SyncIndicatorState.failed`).
  4. Run reconciler on `batch.changedHosts` / `batch.deletedHostIDs` (delta) or full snapshot.
  5. Apply ops to `SessionStore` (existing path).
  6. **Only after apply succeeds**: if `let checkpoint = batch.checkpoint { try await client.commitHostCheckpoint(checkpoint) }`. Successful non-token-expired fetches always populate `checkpoint`; the optional pattern is defensive for the `tokenExpired: true` shape (where checkpoint is nil) and for any future failure modes. `commitHostCheckpoint` is itself silent on epoch / CAS misses (it just doesn't write); the store does not treat that as an error.
  7. Periodic timer tick passes `forceFull` explicitly.
- The client drains pagination internally, so the store does **not** loop on a `moreComing` flag.
- `periodicInterval`: change the **init default** from `15 * 60` to `60 * 60` (`HostSyncStore.swift:141`). Update inline `// 15-minute` comment. Constructor parameter stays injectable for tests; do not introduce a `SyncPreferences` field.
- Wake (`NSWorkspace.didWakeNotification`) and account-changed paths use `mode: .auto`.

### Existing `AppDelegate` (modify in place — do not introduce a new delegate)

`apps/macos/Sources/Caterm/AppDelegate.swift` already exists and is wired via `@NSApplicationDelegateAdaptor(AppDelegate.self)` in `CatermApp`. **Edit the existing class directly** — Swift extensions cannot override class methods, so the changes go in the primary declaration.

Three concrete edits:

1. Extend the existing `applicationDidFinishLaunching(_:)` body (currently sets activation policy + tabbing observer) by appending one line: `NSApp.registerForRemoteNotifications()`.

2. Add new method `application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any])`:
   - Try `CKNotification(fromRemoteNotificationDictionary:)`.
   - Check `subscriptionID == "caterm.host.changes.v1"`. Anything else: silent return (foreign push).
   - On match: `NotificationCenter.default.post(name: .catermCloudKitHostChanged, object: nil)`.

3. Add new method `application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error)`:
   - Log via `os.Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")` at `error` level.
   - No state change; periodic timer remains the safety net.

The push notification name `.catermCloudKitHostChanged` is declared in the `CloudKitSyncClient` module alongside the existing `.catermICloudAccountChanged`.

### Account-identity tracking

`.catermICloudAccountChanged` is posted on every `CKAccountChanged` system event, **including** the post-startup refresh sequence (`iCloudAccountSession.swift:67`). Unconditionally calling `tokenStore.clearAll()` on every post would wipe the token on every startup — defeating incremental sync entirely.

Strategy:
- New helper `AccountIdentityTracker` (in `CloudKitSyncClient` module) that calls `CKContainer.userRecordID()` and persists the last-known recordName in `UserDefaults` under `"cloudkit.lastKnownUserRecordName"`.
- On `.catermICloudAccountChanged`:
  1. `await tracker.currentUserRecordID()` (nil if signed out).
  2. Branch on (prior, current):

     | prior | current | Action |
     |---|---|---|
     | nil | nil | No-op (still signed out). |
     | nil | X | **First-observation upgrade safety:** if `tokenStore` is non-empty, `await client.resetHostSyncState()` then store identity X. If tokenStore is empty, just store identity X. Forces one full snapshot at next sync; eliminates the risk of carrying tokens that belong to a different account from a pre-tracker version. |
     | X | X | No-op (same account, common startup case). |
     | X | Y (or nil) | Real account change / sign-out: `await client.resetHostSyncState()`, `try? await client.deleteHostSubscription()`, store new identity (or clear on sign-out). |

This is the only place tokens are cleared on account events. `resetHostSyncState()` lives on the client (see `IncrementalHostSyncClient` above) so the store still doesn't see token storage. `resetHostSyncState` also bumps the token-store epoch, so any in-flight `commitHostCheckpoint` from a sync that started before the account change is rejected as stale (see "Reset/commit race" in `CloudKitSyncClient`).

### App wiring (`CatermApp.swift`)

- Construct `UserDefaultsServerChangeTokenStore` **inside** `CloudKitSyncClient`'s init (not visible to `CatermApp` or `HostSyncStore`).
- Construct `AccountIdentityTracker(container:)` and pass to `CatermApp`'s account-changed handler. The tracker holds a reference to the client so it can call `resetHostSyncState()` / `deleteHostSubscription()`.
- After launch, fire `Task { try? await cloudKitClient.ensureHostSubscription() }`. Failure is logged, not fatal.
- The `.catermICloudAccountChanged` observer calls into `AccountIdentityTracker` and only clears state on a real change.

## Data Flow

### Cold start

```
CatermApp.init
  → build CloudKitSyncClient (owns tokenStore internally)
  → build HostSyncStore(client)         // store does not see tokenStore
  → @NSApplicationDelegateAdaptor → AppDelegate (existing, extended)

applicationDidFinishLaunching
  → NSApp.registerForRemoteNotifications()
  → Task { await ensureHostSubscription() }

iCloudAccountSession verified (existing)
  → AccountIdentityTracker compares prior vs current userRecordID
    - prior == current  ⇒ no-op
    - prior nil + tokens empty + new identity X  ⇒ store X, no token reset
    - prior nil + tokens NON-empty + new identity X  ⇒ resetHostSyncState (upgrade safety), store X
  → HostSyncStore.syncIfSignedIn(mode: .auto)
    → preferredHostSyncMode() ⇒ .forceFull (tokens empty)
    → fetchHostSnapshotAndCheckpoint  → reconcileFullSnapshot → apply ops
    → if let cp = batch.checkpoint { commitHostCheckpoint(cp) }  // tokens persisted only now
```

### Remote write on another device

```
Device-B writes Host record
  → CloudKit fans out silent push to subscribers
  → AppDelegate receives, posts .catermCloudKitHostChanged
  → HostSyncStore observer triggers syncIfSignedIn(mode: .auto)
    → preferredHostSyncMode() ⇒ .incremental
    → fetchHostChanges()  // client drains DB-level + per-zone moreComing fully
    → reconcileDelta(changedHosts:, deletedHostIDs:) ⇒ apply ops
    → if let cp = batch.checkpoint { commitHostCheckpoint(cp) }  // tokens advance only now
```

### Periodic timer (60 minutes)

```
Timer fires
  → syncIfSignedIn(mode: .forceFull)
    → fetchHostSnapshotAndCheckpoint
        (CKFetchDatabaseChangesOperation(nil) + CKFetchRecordZoneChangesOperation(nil),
         drained fully)
    → reconcileFullSnapshot ⇒ apply ops
    → if let cp = batch.checkpoint { commitHostCheckpoint(cp) }
```

### Wake / foreground

`NSWorkspace.didWakeNotification` → `syncIfSignedIn(mode: .auto)`. Incremental if token exists; full otherwise.

### Token expired

```
fetchHostChanges hits CKError.changeTokenExpired
  → client clears the offending token (db or specific zone) inside its
    private ServerChangeTokenStoring
  → returns HostChangeBatch(checkpoint: nil, tokenExpired: true, ...)
HostSyncStore
  → single retry: syncIfSignedIn(mode: .forceFull)
    → fetchHostSnapshotAndCheckpoint rebuilds tokens from scratch
    → apply → commitHostCheckpoint
```

### iCloud account change / sign-out

```
.catermICloudAccountChanged fires (every CKAccountChanged event)
  → AccountIdentityTracker.compareCurrentToStored()
    ├─ both nil OR same recordName ⇒ NO-OP (common startup case)
    ├─ prior nil + first identity X +
    │   tokenStore empty   ⇒ store X, no token reset
    ├─ prior nil + first identity X +
    │   tokenStore non-empty (upgrade scenario)
    │                      ⇒ await client.resetHostSyncState(), store X
    └─ identity differs from prior ⇒
         await client.resetHostSyncState()
         try? await client.deleteHostSubscription()
         store new identity (or clear on sign-out)
  → existing .signedOut handling continues
```

## Error Handling

| Error | Source | Handling |
|---|---|---|
| `CKError.changeTokenExpired` (db level) | `fetchHostChanges` | Client clears database token via `tokenStore.saveDatabaseToken(nil)`. Don't throw. Return `tokenExpired: true`. Store retries full. |
| `CKError.changeTokenExpired` (zone level) | `fetchHostChanges` per-zone op | Client clears that zone's token via `tokenStore.saveZoneToken(nil, zoneID:)`. Don't throw; aggregate into `tokenExpired: true`. Store retries full. |
| `CKError.zoneNotFound` | `fetchHostChanges` / `fetchHostSnapshotAndCheckpoint` / `listHosts` | Treat as empty (matches Plan A `f936ce4`). Don't clear token — next write re-creates the zone. |
| Caterm zone in `deletedZoneIDs` / `purgedZoneIDs` / `encryptedDataResetZoneIDs` | `fetchHostChanges` / `fetchHostSnapshotAndCheckpoint` DB-level result | Client clears the relevant tokens, returns `tokenExpired: true` with no checkpoint. Store retries `forceFull`; the empty remote snapshot then drives reconciler to delete locally orphaned hosts. |
| Corrupt persisted token bytes | `StoredServerChangeToken.unarchive()` | Throws `ServerChangeTokenError`. Caller logs, treats token as `nil`, and proceeds as `forceFull`. Next successful commit writes a valid token. **Never `try!`.** |
| Stale checkpoint at commit | `commitHostCheckpoint` | Silent skip (no token write, no error). Caused by either the epoch CAS (resetHostSyncState ran during the sync) or the per-token CAS (a concurrent commit won). Store does not retry — the next sync starts fresh. |
| Deletion of non-Host record in same zone | `fetchHostChanges` per-record-deleted block | **Filter by `recordType` parameter passed into the deletion block; only `"Host"` deletions feed `deletedHostIDs`.** Future Plans C/D/E adding records to the same zone must not delete local Host state. |
| `CKError.serverRecordChanged` | reconciler write-back | Out of scope (read path only this plan). |
| `CKError.networkUnavailable` / `networkFailure` | any fetch | Bubble up. `HostSyncStore` → `SyncIndicatorState.failed(transient)`. Timer retries naturally. |
| `CKError.requestRateLimited` / `zoneBusy` / `serviceUnavailable` | any fetch | Honor `userInfo[CKErrorRetryAfterKey]` if present (one-shot retry). Otherwise let timer handle. |
| `CKError.notAuthenticated` | any fetch | Bubble up. `HostSyncStore` → `.signedOut` state, awaits `.catermICloudAccountChanged`. |
| `CKError.partialFailure` (subscription save) | `ensureHostSubscription` | If only error is `serverRejectedRequest` ⇒ "subscription already exists", treat as success. Otherwise propagate. |
| Other subscription save failures | `ensureHostSubscription` | Log only. Don't block startup. Timer remains. |
| `didFailToRegisterForRemoteNotifications` | AppDelegate | Log only. Timer remains. |
| Push parse failure | AppDelegate | Silent return. Probably foreign push. |

### Visibility

- Sync fetch failures: existing `SyncIndicatorState.failed` path. UI already shows.
- Subscription registration failure: **not** surfaced to UI. Sync still works (degraded to polling). Logger marks `subscription_unavailable=true` for diagnostics.
- Token-expired auto-recovery: silent. Logger `info`.

### Logging

`os.Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")`:
- `info`: subscription registered, push triggered sync, token recovered after expiry, periodic full sync diff count.
- `error`: subscription registration failure (with underlying error), APS registration failure, fetch errors (transient vs permanent tagged separately).
- Never log record-level data (avoid leaking host fields).

## Testing

### Layers

| Layer | Files | Coverage |
|---|---|---|
| Unit | `Tests/CloudKitSyncClientTests`, `Tests/HostSyncStoreTests` | Token store round-trip, reconcileDelta, sync mode decision tree, AppDelegate push parsing |
| Contract | `Tests/CloudKitSyncClientTests` | `FakeCKDatabase` extended, error-mapping per §Error Handling |
| Manual integration | This document, end | Spike + 2-device + offline + account change |

### Fakes

- **`FakeCKDatabase`** (existing, extended): `enqueueDatabaseChanges(...)`, `enqueueZoneChanges(...)`, `simulateError(_:on:)`, `recordedSubscriptions: [CKSubscription]`.
- **`InMemoryServerChangeTokenStore`** (new): dict-backed `ServerChangeTokenStoring`.
- **Push dispatch**: tests post `.catermCloudKitHostChanged` directly via `NotificationCenter.default`. No fake needed.

### Required test cases

`HostSyncStoreTests`:
1. `testIncrementalModePreferenceFromClientCallsFetchHostChanges`
2. `testForceFullModePreferenceFromClientCallsFetchHostSnapshotAndCheckpoint`
3. `testApplyFailureDoesNotAdvanceChangeTokens` — fake client records that `commitHostCheckpoint` was NOT called when reconciler/apply throws.
4. `testCheckpointCommittedOnlyAfterApplySucceeds` — assert order: `fetch` → reconcile → apply → `commitHostCheckpoint`. No commit ahead of apply.
5. `testTokenExpiredTriggersSingleForceFullRetry` (token clearing happens inside client; store just retries once).
6. `testFurtherFailureAfterRetryBubblesToFailedState`.
7. `testPushNotificationTriggersIncrementalSync`.
8. `testStartupAccountChangedDoesNotClearTokens` — `AccountIdentityTracker` sees same/first-with-empty-tokens → no `resetHostSyncState` call.
9. `testRealAccountChangeCallsResetAndDeleteSubscription` (different `userRecordID` from prior run).
10. `testPeriodicTimerFiresForceFullEvenWhenIncrementalIsPreferred`.
11. `testSubscriptionRegistrationFailureDoesNotBreakSync`.
12. `testNilCheckpointFromTokenExpiredBatchSkipsCommit` — covers the `if let checkpoint` defensive bind.

`CloudKitSyncClientTests`:
1. `testFetchHostChangesDrainsZoneLevelMoreComing` — fake yields zoneMore=true on first call, false on second; client returns batch with all records and **does not** require store to loop.
2. `testFetchHostChangesDrainsDatabaseLevelMoreComing` — analogous for DB-level.
3. `testFetchHostChangesAggregatesAcrossZones`.
4. `testFetchHostChangesReturnsTokenExpiredFlagInsteadOfThrowing` — asserts the relevant token (db or specific zone) was cleared.
5. `testFetchHostChangesReturnsZoneNotFoundAsEmpty`.
6. `testFetchHostChangesIgnoresDeletionsOfNonHostRecordTypes` — deletion of a `Settings` / `Credential` record in the same zone produces `deletedHostIDs == []`.
7. `testFetchHostChangesDoesNotPersistTokensBeforeCommit` — read tokens from `tokenStore` after fetch, assert unchanged from before fetch.
8. `testCatermZoneInDeletedZoneIDsReturnsTokenExpiredAndForcesForceFullEmpty` — DB-level result includes Caterm zone in deletedZoneIDs ⇒ batch.tokenExpired=true, checkpoint=nil. Subsequent forceFull returns empty changedHosts and reconciler emits delete-local for all prior hosts.
9. `testCatermZoneInPurgedZoneIDsBehavesIdenticallyToDeletedZone` — server-side purge path.
9a. `testCatermZoneInEncryptedDataResetZoneIDsBehavesIdenticallyToDeletedZone` — user iCloud-encryption-reset path; uses the dedicated `recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock` callback.
10. `testCommitHostCheckpointPersistsBothDbAndZoneTokens`.
11. `testCommitHostCheckpointIsIdempotent` — committing the same checkpoint twice is safe.
12. `testCommitHostCheckpointSkipsWhenPersistedTokenArchiveDiffersFromPrev` — concurrent push fetch committed a newer token first; the older commit's CAS fails and writes nothing.
13. `testResetDuringApplyPreventsStaleCheckpointCommit` — start a fetch, capture its in-flight checkpoint, then call `resetHostSyncState()`, then attempt `commitHostCheckpoint`; assert no token was written (`commitTokens` returned `.staleEpoch`).
13a. `testResetInterleavedBetweenEpochCheckAndWriteIsImpossible` — uses an actor-isolated `ServerChangeTokenStoring` impl with an injected suspension point inside `commitTokens`; assert that even with maximally adversarial scheduling, `clearAll()` cannot run between the epoch check and the writes (proves the atomicity contract).
13b. `testCorruptStoredTokenFallsBackToForceFull` — pre-seed `UserDefaults` with garbage bytes for the database token; `unarchive()` throws; the next `fetchHostChanges` treats prior token as `nil` and proceeds as `forceFull`, persisting a fresh valid token afterwards.
14. `testResetHostSyncStateBumpsEpochAndClearsTokens`.
15. `testFetchHostSnapshotAndCheckpointReturnsAllHostsAndCheckpointReflectsAllZones`.
15a. `testForceFullWithExistingTokensCommitsFreshCheckpoint` — pre-seed the token store with a non-nil prior db / zone archive; run `fetchHostSnapshotAndCheckpoint` (which passes `nil` to the CloudKit op); assert the returned checkpoint's `prevDb` / `prevZones` equal the **existing persisted archives**, NOT nil. After commit, assert the persisted store contains the fresh server tokens. Failing this test would mean the periodic 60-min full-sync tick can never refresh the checkpoint.
15b. `testForceFullWithCorruptPersistedTokenStillCommitsFresh` — pre-seed garbage bytes; force-full fetch runs (op prev = nil); checkpoint's `prevDb` carries the corrupt archive; commit replaces with valid fresh token.
16. `testPreferredHostSyncModeReflectsTokenStoreState`.
17. `testCommitHostCheckpointRejectsForeignCheckpointType` — pass a stub `HostSyncCheckpoint` conformer; assert no state change.
18. `testEnsureHostSubscriptionIsIdempotentWhenAlreadyExists`.
19. `testEnsureHostSubscriptionPropagatesNonExistsError`.
20. `testDeleteHostSubscriptionTreatsUnknownItemAsSuccess`.

`AccountIdentityTrackerTests` (new):
1. `testFirstObservationWithEmptyTokensStoresIdentityWithoutResetting`.
2. `testFirstObservationWithExistingTokensCallsResetThenStores` — upgrade-safety branch.
3. `testSameIdentityIsNoOp`.
4. `testDifferentIdentityCallsResetAndDeleteSubscription`.
5. `testSignOutAfterPriorIdentityCallsResetAndDeleteSubscription`.

`AppDelegateTests` (new file, exercising the push-handling additions to existing `AppDelegate`):
1. `testRemoteNotificationWithMatchingSubscriptionIDPostsCatermNotification`
2. `testRemoteNotificationWithDifferentSubscriptionIDIsIgnored`
3. `testMalformedUserInfoDoesNotCrash`

### Manual verification checklist

**Spike (Step 0):**
- [ ] `aps-environment=development` entitlement added; Xcode build & sign green.
- [ ] CloudKit Dashboard edit on a `Host` record → dev Mac Console shows `application:didReceiveRemoteNotification:` firing.

**B1 (Step 1):**
- [ ] First launch with empty token → `fetchHostSnapshotAndCheckpoint` runs → both database token and per-zone token written to `UserDefaults` (visible via `defaults read`).
- [ ] Second launch → `fetchDatabaseChanges` runs → 0 records when nothing changed.
- [ ] Edit a record in Dashboard, launch app → 1 changed record applied locally.

**B2 (Step 2):**
- [ ] Two-Mac: Mac-A edits a host → Mac-B updates within 5 seconds (no timer reliance).
- [ ] Mac-B killed for 30 minutes while Mac-A makes 5 edits → Mac-B on relaunch picks up all 5.
- [ ] Sign out of iCloud → sign in to a different account → previous account's hosts not visible.

## Open Items

- None. All Q1–Q3 brainstorming questions resolved:
  - Q1: keep timer as fallback, widened to 60 min.
  - Q2: hybrid — incremental day-to-day, full on the 60-minute reconciliation tick.
  - Q3: spike first.

## Revision Log

- **2026-05-02 (sixth pass):** Separate CAS-prev from operation-prev; sample sync:
  - **`forceFull` no longer breaks CAS commits.** The drain loop now distinguishes `operationPreviousToken*` (passed to the CloudKit op — `nil` for forceFull or on unarchive failure) from `casPrevious*Archive` (snapshot of the persisted `archivedData` at fetch start, captured for both modes). The checkpoint's `prevDb` / `prevZones` come from `casPrevious*`. Without this split, a 60-minute reconciliation tick with an existing persisted token would build the checkpoint with `prev == nil` while the store still held the prior archive ⇒ CAS mismatch ⇒ commit silently skipped ⇒ checkpoint never refreshed. Same logic preserves a corrupt archive in CAS prev so a successful forceFull can replace it.
  - New tests: `testForceFullWithExistingTokensCommitsFreshCheckpoint`, `testForceFullWithCorruptPersistedTokenStillCommitsFresh`.
  - **"Comparable token form" sample synced.** The leftover `var token: CKServerChangeToken` accessor in §`CloudKitSyncClient` was reduced to a one-line cross-reference pointing at the canonical `StoredServerChangeToken` definition with `unarchive() throws`. Prevents an implementer from copy-pasting the old `try!` shape back in.

- **2026-05-02 (fifth pass):** Atomicity, callback completeness, decode safety, dedup:
  - **`commitTokens` is now an atomic compound operation on the token store.** Replaced the old `currentEpoch` getter + separate `saveDatabaseToken` / `saveZoneToken` calls. The default impl is an `actor`, which makes the epoch check and the per-token CAS writes share a single critical section — `clearAll` / `bumpEpoch` cannot interleave between them. Closes the residual race the fourth pass left.
  - **Encrypted-data-reset zone callback added.** `CKFetchDatabaseChangesOperation` exposes a separate `recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock` that previously was conflated with `purgedZoneIDs`. Added a fourth bin `encryptedDataResetZoneIDs` to the protocol and to `FakeCloudDatabase.enqueueDatabaseChanges`. Caterm zone in any of the three (deleted / purged / encrypted-reset) triggers the same forceFull-empty path.
  - **Token decode no longer uses `try!`.** `StoredServerChangeToken.unarchive()` throws; the drain loop logs + treats a corrupt token as absent + falls back to `forceFull`. New test `testCorruptStoredTokenFallsBackToForceFull`.
  - **Removed the duplicated `preferredHostSyncMode` / `changeTokenExpired` / `resetHostSyncState` paragraph block** that the fourth-pass edits left around line 342. The reset prose there used a stale "cooperative cancellation flag" formulation that contradicted the epoch-based design.
  - **`enqueueDatabaseChanges` test helper** now mirrors the protocol shape: takes all four zone-status bins.

- **2026-05-02 (fourth pass):** Concurrency, types, and zone-deletion fixes:
  - **`HostSyncCheckpoint` is now a marker protocol**, not a `public struct` with `internal` payload (which wouldn't have compiled — `internal` payload is invisible across modules). The concrete checkpoint type lives `internal` to `CloudKitSyncClient`. `commitHostCheckpoint` downcasts and silent-rejects foreign types.
  - **Reset/commit race fixed via epoch CAS.** `ServerChangeTokenStoring` now exposes `currentEpoch` + `bumpEpoch()`. `resetHostSyncState` and `clearAll` bump it. `commitHostCheckpoint` rejects checkpoints whose epoch no longer matches — eliminates the "in-flight account-1 sync writes back its token after sign-in to account-2" data-corruption path.
  - **Per-token CAS uses `Data` equality.** `CKServerChangeToken` is opaque and not `Equatable`, so the internal store now hands back `StoredServerChangeToken` (token + `archivedData: Data`). CAS in `commitHostCheckpoint` compares `Data` values — concurrent commits where a push-driven sync committed first now correctly skip the older sync's commit.
  - **Caterm-zone deletion / purge surfaced.** `CKFetchDatabaseChangesOperation` reports `deletedZoneIDs` (zone deleted) and `purgedZoneIDs` (encryption reset). When the Caterm zone appears in either, the client returns `tokenExpired: true, checkpoint: nil`; the store retries `forceFull`, which yields an empty remote snapshot, and the reconciler deletes locally orphaned hosts naturally — no need for the client to know what's local.
  - **`if let checkpoint`** replaces `batch.checkpoint!` everywhere. Defensive against the `tokenExpired: true ⇒ checkpoint == nil` shape; new test `testNilCheckpointFromTokenExpiredBatchSkipsCommit` covers the bind.
  - Added tests: `testResetDuringApplyPreventsStaleCheckpointCommit`, `testCommitHostCheckpointSkipsWhenPersistedTokenArchiveDiffersFromPrev`, `testCommitHostCheckpointRejectsForeignCheckpointType`, `testCatermZoneInDeletedZoneIDsReturnsTokenExpiredAndForcesForceFullEmpty`, `testCatermZoneInPurgedZoneIDsBehavesIdenticallyToDeletedZone`, `testResetHostSyncStateBumpsEpochAndClearsTokens`.

- **2026-05-02 (third pass):** Atomicity, pagination, and boundary fixes:
  - **Token persistence deferred to apply success.** `fetchHostChanges` / `fetchHostSnapshotAndCheckpoint` no longer write to `ServerChangeTokenStoring`. They return an opaque `HostSyncCheckpoint`; `HostSyncStore` calls `commitHostCheckpoint` only after reconcile + apply succeed. Eliminates the "fetch advanced tokens but apply failed → records permanently lost" race.
  - **Per-zone pagination drained inside the client.** Each `CKFetchRecordZoneChangesOperation` is looped until `moreChanges == false`; database-level `moreComing` likewise drained inside the client. Removes the store-level `moreComing` loop, which would have lost the next page after the database token advanced past a zone.
  - **`ServerChangeTokenStoring` is now internal to the `CloudKitSyncClient` module.** Removed from any protocol surface visible to the store. `HostSyncStore` asks `client.preferredHostSyncMode()` instead of reading the token store directly.
  - **`CKDatabaseProtocol` extended** with `fetchDatabaseChanges`, `fetchZoneChanges`, `saveSubscription`, `deleteSubscription`, so `FakeCloudDatabase` remains the single test seam.
  - **Upgrade safety in `AccountIdentityTracker`:** when `prior == nil` and the token store is non-empty, call `resetHostSyncState()` before recording the new identity. Eliminates risk of carrying tokens that belong to a different account from a pre-tracker version.
  - **AppDelegate snippet rewritten as prose** ("edit this method, add these methods") since Swift extensions can't override class methods. The `override func ... extension` shape was misleading.
  - Typos: `local: [Host]` → `local: [SSHHost]`; reconciler return labeled `[SyncOperation]` to match `apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift:10`.

- **2026-05-02 (post-review):** Tightened module boundaries and token semantics:
  - `forceFull` no longer goes through `listHosts()` (CKQuery yields no token); use `fetchHostSnapshotAndCheckpoint()` built on `CKFetchDatabaseChangesOperation` + `CKFetchRecordZoneChangesOperation`.
  - Introduced `IncrementalHostSyncClient` protocol so `HostSyncStore` stays decoupled from `CloudKitSyncClient`.
  - Moved `CKRecord` decoding inside `CloudKitSyncClient`; reconciler / store handle only `RemoteHost` + `String`.
  - Spelled out per-zone token flow (read prior zone token, persist after each zone success, db token after all zones).
  - Replaced unconditional `tokenStore.clearAll()` on `.catermICloudAccountChanged` with `AccountIdentityTracker` to avoid wiping tokens on every startup.
  - Reuse existing `apps/macos/Sources/Caterm/AppDelegate.swift` instead of a new `CatermAppDelegate`.
  - Backed out the `SyncPreferences.periodicInterval` move; just change the constructor default.
  - Added explicit `recordType == "Host"` filter on the per-record-deletion block + dedicated test, so future record types in the same zone can't delete local Host state.

## References

- [Plan A — CloudKit Host Sync](../plans/2026-05-02-cloudkit-host-sync.md)
- [macOS dev signing pitfalls](../../macos-dev-signing.md)
- Apple: `CKDatabaseSubscription`, `CKFetchDatabaseChangesOperation`, `CKServerChangeToken`
