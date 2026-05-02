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

- Add `ServerChangeTokenStoring` protocol + `UserDefaultsServerChangeTokenStore` default impl.
- Add `CloudKitSyncClient.fetchHostChanges(since:)` using `CKFetchDatabaseChangesOperation` + `CKFetchRecordZoneChangesOperation`.
- Add `HostSyncReconciler.reconcileDelta(changed:deleted:local:)`. Rename existing reconcile path to `reconcileFullSnapshot(...)`.
- `HostSyncStore.sync(mode:)` decides full vs incremental. Token-expired and zone-not-found errors handled per §Error Handling.

### Step 2 — B2: Push Subscription + Timer Widening

Depends on Step 0 success and Step 1 merged.

- Add `CloudKitSyncClient.ensureHostSubscription()` (idempotent) and `deleteHostSubscription()` (for account sign-out).
- Add `CatermAppDelegate` via `@NSApplicationDelegateAdaptor` for `registerForRemoteNotifications` + `application(_:didReceiveRemoteNotification:)`.
- AppDelegate dispatches matching `CKNotification` as `.catermCloudKitHostChanged` via `NotificationCenter`.
- `HostSyncStore` observes `.catermCloudKitHostChanged` and triggers incremental sync.
- Widen periodic timer constant from 15 → 60 minutes. Periodic tick uses `mode: .forceFull` for reconciliation.

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

### `CloudKitSyncClient` (extended)

```swift
struct HostChangeBatch {
    let changedRecords: [CKRecord]
    let deletedRecordIDs: [CKRecord.ID]
    let newDatabaseToken: CKServerChangeToken?
    let newZoneTokens: [CKRecordZone.ID: CKServerChangeToken]
    let moreComing: Bool
    let tokenExpired: Bool
}

func fetchHostChanges(since token: CKServerChangeToken?) async throws -> HostChangeBatch
func ensureHostSubscription() async throws       // idempotent
func deleteHostSubscription() async throws       // for account sign-out cleanup
```

`fetchHostChanges` internals:
1. `CKFetchDatabaseChangesOperation(previousServerChangeToken: token)` — get changed `zoneID`s.
2. For each `zoneID`, run `CKFetchRecordZoneChangesOperation`, filter `recordType == "Host"`.
3. On `CKError.changeTokenExpired`, do **not** throw. Return `HostChangeBatch(tokenExpired: true, ...)` with empty records so the caller can drop the token and retry full.
4. If `moreComing == true`, the caller is expected to re-invoke until false.

`ensureHostSubscription` internals:
- `CKDatabaseSubscription(subscriptionID: "caterm.host.changes.v1")`.
- `subscription.recordType = "Host"`.
- `notificationInfo.shouldSendContentAvailable = true`. No alert / sound / badge.
- On save failure, inspect `CKError.partialFailure.partialErrorsByItemID`. If the only error is `serverRejectedRequest` indicating the subscription already exists, treat as success. Otherwise propagate.

### `HostSyncReconciler` (extended)

- Existing `reconcile(remote:local:)` renamed to `reconcileFullSnapshot(remote:local:)`. Behavior unchanged.
- New `reconcileDelta(changed:deleted:local:)`:
  - For each `CKRecord` in `changed`: `CKRecordHostMapping.host(from:)` → upsert into local set keyed by `recordName`.
  - For each `CKRecord.ID` in `deleted`: remove from local set by `recordName`.
  - Output is the same `Result` struct (apply ops) as `reconcileFullSnapshot`. `HostSyncStore`'s apply path is unchanged.

### `HostSyncStore` (modified)

- Inject `ServerChangeTokenStoring` (default `UserDefaultsServerChangeTokenStore`).
- Subscribe to `.catermCloudKitHostChanged` in init. Tear down in deinit.
- Add `enum SyncMode { case auto; case forceFull; case incremental }`.
- `sync(mode: SyncMode = .auto)` decision tree:
  - `auto` → token present ⇒ `incremental`; absent ⇒ `forceFull`.
  - `incremental` → call `fetchHostChanges`; if `tokenExpired` ⇒ clear token, re-call with `forceFull`; if `moreComing` ⇒ loop.
  - `forceFull` → call existing `listHosts` + `reconcileFullSnapshot`, then write fresh database token.
  - Periodic timer tick passes `forceFull` explicitly.
- `periodicInterval`: move to `SyncPreferences`, change from `.minutes(15)` to `.minutes(60)`.
- Wake (`NSWorkspace.didWakeNotification`) and account-changed paths use `mode: .auto` (incremental preferred).

### `CatermAppDelegate` (new)

File: `apps/macos/Sources/Caterm/CatermAppDelegate.swift`

```swift
@MainActor
final class CatermAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

`CatermApp` adopts via `@NSApplicationDelegateAdaptor(CatermAppDelegate.self)`.

### App wiring (`CatermApp.swift`)

- Construct `UserDefaultsServerChangeTokenStore` and pass to both `CloudKitSyncClient` and `HostSyncStore`.
- After launch, fire `Task { try? await cloudKitClient.ensureHostSubscription() }`. Failure is logged, not fatal.
- On `.catermICloudAccountChanged` to signed-out / different account: call `tokenStore.clearAll()` and `try? await cloudKitClient.deleteHostSubscription()`.

## Data Flow

### Cold start

```
CatermApp.init
  → build CloudKitSyncClient(tokenStore)
  → build HostSyncStore(client, tokenStore)
  → @NSApplicationDelegateAdaptor → CatermAppDelegate

applicationDidFinishLaunching
  → NSApp.registerForRemoteNotifications()
  → Task { await ensureHostSubscription() }

iCloudAccountSession verified (existing)
  → HostSyncStore.syncIfSignedIn(mode: .auto)
    → token == nil ⇒ forceFull ⇒ listHosts ⇒ reconcileFullSnapshot
    → persist new database token
```

### Remote write on another device

```
Device-B writes Host record
  → CloudKit fans out silent push to subscribers
  → CatermAppDelegate receives, posts .catermCloudKitHostChanged
  → HostSyncStore observer triggers syncIfSignedIn(mode: .auto)
    → token present ⇒ fetchHostChanges(since: token)
    → reconcileDelta ⇒ apply ops
    → persist new database token
    → moreComing == true ⇒ loop
```

### Periodic timer (60 minutes)

```
Timer fires
  → syncIfSignedIn(mode: .forceFull)
    → listHosts (full)
    → reconcileFullSnapshot ⇒ apply ops
    → persist new database token
```

### Wake / foreground

`NSWorkspace.didWakeNotification` → `syncIfSignedIn(mode: .auto)`. Incremental if token exists; full otherwise.

### Token expired

```
fetchHostChanges hits CKError.changeTokenExpired
  → returns HostChangeBatch(tokenExpired: true, ...)
HostSyncStore
  → tokenStore.saveDatabaseToken(nil)
  → syncIfSignedIn(mode: .forceFull)
```

### iCloud account change / sign-out

```
.catermICloudAccountChanged fires
  → tokenStore.clearAll()
  → Task { try? await cloudKitClient.deleteHostSubscription() }
  → existing .signedOut handling continues
```

## Error Handling

| Error | Source | Handling |
|---|---|---|
| `CKError.changeTokenExpired` | `fetchHostChanges` | Don't throw. Return `tokenExpired: true`. Caller clears token + retries full once. |
| `CKError.zoneNotFound` | `fetchHostChanges` / `listHosts` | Treat as empty (matches Plan A `f936ce4`). Don't clear token — next write re-creates the zone. |
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
2. `testFullSyncWhenNoTokenExists`
3. `testTokenExpiredTriggersTokenClearAndFullRetry`
4. `testMoreComingLoopsUntilFalse`
5. `testPushNotificationTriggersIncrementalSync`
6. `testAccountSignedOutClearsTokensAndAttemptsSubscriptionDelete`
7. `testPeriodicTimerFiresForceFullEvenWhenTokenExists`
8. `testSubscriptionRegistrationFailureDoesNotBreakSync`

`CloudKitSyncClientTests`:
1. `testFetchHostChangesAggregatesAcrossZones`
2. `testFetchHostChangesReturnsTokenExpiredFlagInsteadOfThrowing`
3. `testFetchHostChangesReturnsZoneNotFoundAsEmpty`
4. `testEnsureHostSubscriptionIsIdempotentWhenAlreadyExists`
5. `testEnsureHostSubscriptionPropagatesNonExistsError`

`CatermAppDelegateTests` (new):
1. `testRemoteNotificationWithMatchingSubscriptionIDPostsCatermNotification`
2. `testRemoteNotificationWithDifferentSubscriptionIDIsIgnored`
3. `testMalformedUserInfoDoesNotCrash`

### Manual verification checklist

**Spike (Step 0):**
- [ ] `aps-environment=development` entitlement added; Xcode build & sign green.
- [ ] CloudKit Dashboard edit on a `Host` record → dev Mac Console shows `application:didReceiveRemoteNotification:` firing.

**B1 (Step 1):**
- [ ] First launch with empty token → `listHosts` runs → token written to `UserDefaults` (visible via `defaults read`).
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

## References

- [Plan A — CloudKit Host Sync](../plans/2026-05-02-cloudkit-host-sync.md)
- [macOS dev signing pitfalls](../../macos-dev-signing.md)
- Apple: `CKDatabaseSubscription`, `CKFetchDatabaseChangesOperation`, `CKServerChangeToken`
