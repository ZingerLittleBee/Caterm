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

- Add `ServerChangeTokenStoring` protocol + `UserDefaultsServerChangeTokenStore` default impl + opaque `CKServerChangeTokenOpaque` value type.
- Add `IncrementalHostSyncClient` protocol in the `ServerSyncClient` module. `CloudKitSyncClient` conforms.
- Add `CloudKitSyncClient.fetchHostChanges()` (incremental) and `fetchHostSnapshotAndCheckpoint()` (full snapshot via `CKFetchDatabaseChangesOperation(nil)` + `CKFetchRecordZoneChangesOperation(nil)`, returning fresh tokens). `listHosts()` stays as-is for any non-checkpointed callers but is **not** used by `HostSyncStore.forceFull` anymore.
- Add `HostSyncReconciler.reconcileDelta(changedHosts:deletedHostIDs:local:)` in domain types (no `CloudKit` import). Rename existing reconcile path to `reconcileFullSnapshot(...)`.
- Change `HostSyncStore.client` declared type to `IncrementalHostSyncClient`. Add `sync(mode:)` decision tree. Token-expired, zone-not-found, and per-zone token failures handled per §Error Handling.

### Step 2 — B2: Push Subscription + Timer Widening

Depends on Step 0 success and Step 1 merged.

- Add `CloudKitSyncClient.ensureHostSubscription()` (idempotent) and `deleteHostSubscription()` (for account sign-out).
- Extend the **existing** `apps/macos/Sources/Caterm/AppDelegate.swift` with `registerForRemoteNotifications` + `application(_:didReceiveRemoteNotification:)` + `application(_:didFailToRegisterForRemoteNotificationsWithError:)`. Do not introduce a second AppDelegate.
- Add `AccountIdentityTracker` to `CloudKitSyncClient` module; rewire the `.catermICloudAccountChanged` handler in `CatermApp` to compare current vs prior `userRecordID` before clearing tokens.
- AppDelegate dispatches matching `CKNotification` as `.catermCloudKitHostChanged` via `NotificationCenter`.
- `HostSyncStore` observes `.catermCloudKitHostChanged` and triggers incremental sync.
- Change `periodicInterval` init default from `15 * 60` to `60 * 60`. Periodic tick uses `mode: .forceFull` for reconciliation. (Constructor remains injectable for tests.)

## Components

### `ServerChangeTokenStoring` (new)

File: `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`

```swift
protocol ServerChangeTokenStoring {
    func loadDatabaseToken() -> CKServerChangeToken?
    func saveDatabaseToken(_ token: CKServerChangeToken?)
    func loadZoneToken(zoneID: CKRecordZone.ID) -> CKServerChangeToken?
    func saveZoneToken(_ token: CKServerChangeToken?, zoneID: CKRecordZone.ID)
    func clearAll()
}
```

- Default impl: `UserDefaultsServerChangeTokenStore`.
  - Database token key: `"cloudkit.changeToken.database"`.
  - Zone token key: `"cloudkit.changeToken.zone.<zoneName>.<ownerName>"`.
  - Token persisted as `Data` via `NSKeyedArchiver` (`requiringSecureCoding: true`).
- Test impl: `InMemoryServerChangeTokenStore` (dictionary-backed).

### `IncrementalHostSyncClient` protocol (new)

`HostSyncStore` must not depend on `CloudKitSyncClient` directly. The store currently types its dependency as `ServerSyncClient` (`apps/macos/Sources/HostSyncStore/HostSyncStore.swift:88`); we add a refinement protocol so the store stays in domain types.

File: `apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift`

```swift
public struct HostChangeBatch: Sendable {
    public let changedHosts: [RemoteHost]            // already decoded
    public let deletedHostIDs: [String]              // RemoteHost.id (== recordName); only Host record deletions
    public let newDatabaseToken: CKServerChangeTokenOpaque?
    public let newZoneTokens: [String: CKServerChangeTokenOpaque]   // key: zoneID stringified
    public let moreComing: Bool
    public let tokenExpired: Bool
}

public protocol IncrementalHostSyncClient: ServerSyncClient {
    func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch  // forceFull path
    func fetchHostChanges() async throws -> HostChangeBatch                // incremental path
    func ensureHostSubscription() async throws                              // idempotent
    func deleteHostSubscription() async throws                              // sign-out cleanup
}
```

Notes:
- `RemoteHost` and `String` are the only types crossing the boundary. `CKRecord` is fully encapsulated in `CloudKitSyncClient`.
- Tokens are exchanged via an opaque wrapper `CKServerChangeTokenOpaque` (a thin value type wrapping `Data` produced by `NSKeyedArchiver`) so `HostSyncStore` and the protocol module never import `CloudKit`. Token persistence lives behind `ServerChangeTokenStoring`; clients pass tokens by injecting the store, not by parameter.
- Both `fetchHostSnapshotAndCheckpoint` and `fetchHostChanges` read previous tokens from and write new tokens to the injected `ServerChangeTokenStoring`. Callers don't pass tokens in.

### `CloudKitSyncClient` (extended)

Conforms to `IncrementalHostSyncClient`. Holds a reference to `ServerChangeTokenStoring`.

`fetchHostSnapshotAndCheckpoint()`:
1. `CKFetchDatabaseChangesOperation(previousServerChangeToken: nil)` → all zone IDs that have any records.
2. For each `zoneID`, `CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: nil)` (token nil) → all records.
3. Filter `recordType == "Host"` in the per-record block; ignore other types.
4. Decode `Host` records → `RemoteHost` via `CKRecordHostMapping.decode(_:)`.
5. Persist returned `serverChangeToken`s for both database and each zone via `ServerChangeTokenStoring`.
6. Returns `HostChangeBatch(changedHosts: [...], deletedHostIDs: [], moreComing:, tokenExpired: false)`.

This replaces the use of `listHosts()` for `forceFull` reconciliation, because `CKQuery` does not yield a `CKServerChangeToken`. `listHosts()` itself stays for backwards compat with anything that wants a snapshot without checkpoint, but `HostSyncStore.forceFull` calls `fetchHostSnapshotAndCheckpoint`.

`fetchHostChanges()`:
1. Read prior database token via `tokenStore.loadDatabaseToken()`.
2. `CKFetchDatabaseChangesOperation(previousServerChangeToken: dbToken)` → changed zone IDs + new db token.
3. For each changed `zoneID`: read prior zone token via `tokenStore.loadZoneToken(zoneID:)`. Run `CKFetchRecordZoneChangesOperation` with that token.
4. In the operation's `recordWasChangedBlock`: filter `recordType == "Host"`, decode → append to `changedHosts`.
5. In `recordWithIDWasDeletedBlock`: filter on the `recordType` parameter — only append `recordID.recordName` to `deletedHostIDs` if the deleted record's type is `"Host"`. **This guard prevents future record types (Plans C/D/E) sharing the zone from accidentally deleting local Host state.**
6. On per-zone success, persist the new zone token via `tokenStore.saveZoneToken(_:zoneID:)`. Persist the new db token via `tokenStore.saveDatabaseToken(_:)` only after all zones have committed.
7. On `CKError.changeTokenExpired`: clear the offending token (`saveDatabaseToken(nil)` if expired at db level, or `saveZoneToken(nil, zoneID:)` if expired at a specific zone). Return `tokenExpired: true` instead of throwing.
8. `moreComing: true` is propagated when either operation reports more changes available.

`ensureHostSubscription()` internals:
- `CKDatabaseSubscription(subscriptionID: "caterm.host.changes.v1")`.
- `subscription.recordType = "Host"`.
- `notificationInfo.shouldSendContentAvailable = true`. No alert / sound / badge.
- On save failure, inspect `CKError.partialFailure.partialErrorsByItemID`. If the only error is `serverRejectedRequest` indicating the subscription already exists, treat as success. Otherwise propagate.

`deleteHostSubscription()`: `database.deleteSubscription(withID: "caterm.host.changes.v1")`. `CKError.unknownItem` is treated as success (idempotent).

### `HostSyncReconciler` (extended)

Stays in domain types. No `CloudKit` import added.

- Existing `reconcile(remote:local:)` renamed to `reconcileFullSnapshot(remote:local:)`. Behavior unchanged.
- New `reconcileDelta(changedHosts: [RemoteHost], deletedHostIDs: [String], local: [Host])`:
  - For each `RemoteHost` in `changedHosts`: upsert into local set keyed by id.
  - For each id in `deletedHostIDs`: remove from local set by id.
  - Output is the same `Result` struct (apply ops) as `reconcileFullSnapshot`. `HostSyncStore`'s apply path is unchanged.

### `HostSyncStore` (modified)

- Change `client` declared type from `ServerSyncClient` to `IncrementalHostSyncClient` (`HostSyncStore.swift:88, :136`). Existing tests that pass a fake `ServerSyncClient` must update the fake to conform.
- Subscribe to `.catermCloudKitHostChanged` in init. Tear down in deinit.
- Add `enum SyncMode { case auto; case forceFull; case incremental }`.
- `sync(mode: SyncMode = .auto)` decision tree:
  - `auto` → tokenStore.loadDatabaseToken() != nil ⇒ `incremental`; nil ⇒ `forceFull`.
  - `incremental` → call `fetchHostChanges()`; if `tokenExpired` ⇒ tokens already cleared by client, re-call with `forceFull`; if `moreComing` ⇒ loop until false.
  - `forceFull` → call `fetchHostSnapshotAndCheckpoint()` + `reconcileFullSnapshot`. Tokens are persisted by the client.
  - Periodic timer tick passes `forceFull` explicitly.
- `periodicInterval`: change the **init default** from `15 * 60` to `60 * 60`. Update inline `// 15-minute` comment near the timer setup. The constructor parameter remains injectable for tests; do not introduce a `SyncPreferences` field for this.
- Wake (`NSWorkspace.didWakeNotification`) and account-changed paths use `mode: .auto`.

### Existing `AppDelegate` (extended, not new)

`apps/macos/Sources/Caterm/AppDelegate.swift` already exists and is wired via `@NSApplicationDelegateAdaptor(AppDelegate.self)` in `CatermApp`. **Do not introduce a second AppDelegate.** Extend the existing class:

```swift
// adds to existing AppDelegate
extension AppDelegate {
    override func applicationDidFinishLaunching(_ notification: Notification) {
        // existing body retained, plus:
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let ckNotification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              ckNotification.subscriptionID == "caterm.host.changes.v1" else { return }
        NotificationCenter.default.post(name: .catermCloudKitHostChanged, object: nil)
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Log only; periodic timer remains.
    }
}
```

(Implementation merges `applicationDidFinishLaunching` rather than overriding via extension, but the additive nature is the design contract.)

### Account-identity tracking

`.catermICloudAccountChanged` is posted on every `CKAccountChanged` system event, **including** the post-startup refresh sequence (`iCloudAccountSession.swift:67`). Unconditionally calling `tokenStore.clearAll()` on every post would wipe the token on every startup — defeating incremental sync entirely.

Strategy:
- New helper `AccountIdentityTracker` (in `CloudKitSyncClient` module) that calls `CKContainer.userRecordID()` and persists the last-known recordName in `UserDefaults` under `"cloudkit.lastKnownUserRecordName"`.
- On `.catermICloudAccountChanged`:
  1. `await tracker.currentUserRecordID()` (nil if signed out).
  2. Compare to the stored value:
     - both nil ⇒ still signed out, no-op.
     - prior nil, new value ⇒ first sign-in observed; store new value, **do not** clear tokens (this is the legitimate case where we just learned the identity; tokens were either absent or belong to this same account from a prior session).
     - prior == new ⇒ same account refreshed (the common startup case), no-op.
     - prior != new (including new == nil) ⇒ real account change or sign-out: `tokenStore.clearAll()`, `try? await deleteHostSubscription()`, store the new value (or clear it on sign-out).

This is the only place tokens are cleared on account events.

### App wiring (`CatermApp.swift`)

- Construct `UserDefaultsServerChangeTokenStore` and pass to `CloudKitSyncClient`.
- Construct `AccountIdentityTracker(container:)` and pass to `CatermApp`'s account-changed handler.
- After launch, fire `Task { try? await cloudKitClient.ensureHostSubscription() }`. Failure is logged, not fatal.
- The `.catermICloudAccountChanged` observer calls into `AccountIdentityTracker` and only clears state on a real change.

## Data Flow

### Cold start

```
CatermApp.init
  → build CloudKitSyncClient(tokenStore)
  → build HostSyncStore(client, tokenStore)
  → @NSApplicationDelegateAdaptor → AppDelegate (existing, extended)

applicationDidFinishLaunching
  → NSApp.registerForRemoteNotifications()
  → Task { await ensureHostSubscription() }

iCloudAccountSession verified (existing)
  → AccountIdentityTracker observes prior == new (or first sign-in observed)
    ⇒ DO NOT clear tokens
  → HostSyncStore.syncIfSignedIn(mode: .auto)
    → token == nil ⇒ forceFull ⇒ fetchHostSnapshotAndCheckpoint ⇒ reconcileFullSnapshot
    → client persists new database + zone tokens
```

### Remote write on another device

```
Device-B writes Host record
  → CloudKit fans out silent push to subscribers
  → AppDelegate receives, posts .catermCloudKitHostChanged
  → HostSyncStore observer triggers syncIfSignedIn(mode: .auto)
    → token present ⇒ fetchHostChanges()
    → reconcileDelta(changedHosts:, deletedHostIDs:) ⇒ apply ops
    → client persists new database + per-zone tokens
    → moreComing == true ⇒ loop
```

### Periodic timer (60 minutes)

```
Timer fires
  → syncIfSignedIn(mode: .forceFull)
    → fetchHostSnapshotAndCheckpoint
        (CKFetchDatabaseChangesOperation(nil) + CKFetchRecordZoneChangesOperation(nil))
    → reconcileFullSnapshot ⇒ apply ops
    → client persists fresh database + per-zone tokens
```

### Wake / foreground

`NSWorkspace.didWakeNotification` → `syncIfSignedIn(mode: .auto)`. Incremental if token exists; full otherwise.

### Token expired

```
fetchHostChanges hits CKError.changeTokenExpired
  → client clears the offending token (db or specific zone) inside ServerChangeTokenStoring
  → returns HostChangeBatch(tokenExpired: true, ...)
HostSyncStore
  → syncIfSignedIn(mode: .forceFull)
    → fetchHostSnapshotAndCheckpoint rebuilds tokens from scratch
```

### iCloud account change / sign-out

```
.catermICloudAccountChanged fires (every CKAccountChanged event)
  → AccountIdentityTracker.compareCurrentToStored()
    ├─ both nil OR same recordName ⇒ NO-OP (this is the common startup case)
    ├─ first observation of an identity ⇒ store identity, NO-OP on tokens
    └─ identity differs from prior ⇒
         tokenStore.clearAll()
         try? await cloudKitClient.deleteHostSubscription()
         store new identity (or clear on sign-out)
  → existing .signedOut handling continues
```

## Error Handling

| Error | Source | Handling |
|---|---|---|
| `CKError.changeTokenExpired` (db level) | `fetchHostChanges` | Client clears database token via `tokenStore.saveDatabaseToken(nil)`. Don't throw. Return `tokenExpired: true`. Store retries full. |
| `CKError.changeTokenExpired` (zone level) | `fetchHostChanges` per-zone op | Client clears that zone's token via `tokenStore.saveZoneToken(nil, zoneID:)`. Don't throw; aggregate into `tokenExpired: true`. Store retries full. |
| `CKError.zoneNotFound` | `fetchHostChanges` / `fetchHostSnapshotAndCheckpoint` / `listHosts` | Treat as empty (matches Plan A `f936ce4`). Don't clear token — next write re-creates the zone. |
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
1. `testIncrementalSyncWithExistingTokenCallsFetchHostChanges`
2. `testFullSyncWhenNoTokenCallsFetchHostSnapshotAndCheckpoint`
3. `testTokenExpiredTriggersFullRetry` (token clearing happens inside client; store just retries)
4. `testMoreComingLoopsUntilFalse`
5. `testPushNotificationTriggersIncrementalSync`
6. `testStartupAccountChangedDoesNotClearTokens` (AccountIdentityTracker sees same/first identity → tokens preserved across app restarts)
7. `testRealAccountChangeClearsTokensAndDeletesSubscription` (different `userRecordID` from prior run)
8. `testPeriodicTimerFiresForceFullEvenWhenTokenExists`
9. `testSubscriptionRegistrationFailureDoesNotBreakSync`

`CloudKitSyncClientTests`:
1. `testFetchHostChangesAggregatesAcrossZones`
2. `testFetchHostChangesReturnsTokenExpiredFlagInsteadOfThrowing` (asserts the relevant token was cleared)
3. `testFetchHostChangesReturnsZoneNotFoundAsEmpty`
4. `testFetchHostChangesIgnoresDeletionsOfNonHostRecordTypes` (deletion of a `Settings`/`Credential` record in the same zone produces `deletedHostIDs == []`)
5. `testFetchHostSnapshotAndCheckpointReturnsAllHostsAndPersistsTokens`
6. `testEnsureHostSubscriptionIsIdempotentWhenAlreadyExists`
7. `testEnsureHostSubscriptionPropagatesNonExistsError`
8. `testDeleteHostSubscriptionTreatsUnknownItemAsSuccess`

`AccountIdentityTrackerTests` (new):
1. `testFirstObservationStoresIdentityWithoutClearing`
2. `testSameIdentityIsNoOp`
3. `testDifferentIdentityReportsChange`
4. `testSignOutAfterPriorIdentityReportsChange`

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
