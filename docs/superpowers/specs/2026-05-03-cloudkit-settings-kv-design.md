# Plan D — CloudKit Settings KV Sync Design

**Status:** brainstormed 2026-05-03, awaiting user review.
**Scope:** Sync the user-facing portion of `CatermSettings` (terminal preferences + per-host overrides) across the user's Macs via `NSUbiquitousKeyValueStore`. Per-device filesystem migration markers (`migrationsCompleted`) stay local. Replaces the implicit "settings stay local" behavior; does NOT touch hosts (Plan A), pushes (Plan B), or credentials (Plan C).
**Predecessors:** Plan A (host sync) + Plan B (push) + Plan C (credential sync) — merged in PR #15.

## Goals

- Two-Mac convergence on `CatermSettings` without a server, without user-visible toggles.
- Identity-isolated: switching iCloud accounts must not bleed account X's settings into account Y.
- Default seeds must never overwrite real cloud user data on any device.
- No new permissions, no new entitlements (KVS rides on the existing iCloud entitlement from Plan A).

## Non-Goals

- Per-field LWW / merge granularity. Doc-level revision LWW only; concurrent cross-Mac edits are rare for settings and the loss is "re-pick a theme", not data loss.
- UI surface for sync state. No toggle, no indicator, no toast. Future work can add an indicator if real users complain; not in scope here.
- Pruning `hostOverrides` for hosts that no longer exist locally. Plan A's host-deletion path will surface as `hostOverrides` for ghost hosts; harmless and small. Garbage collection deferred.
- Changing how local plist is loaded/written. `SettingsStore` stays the local source of truth; `SettingsSyncStore` is a coordinator wrapped around it.

## Architectural Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Data shape on KVS | **Single blob** under one key (`caterm.settings.v1`); a `SyncableSettings` projection that excludes per-device `migrationsCompleted` | Atomic; estimated < 10 KB vs 1 MB cap; concurrent cross-Mac edits rare so doc-level LWW is acceptable. `migrationsCompleted` is per-device filesystem state and explicitly does NOT travel. |
| Enablement | **Always-on** when iCloud signed in | Mirrors Plan A; settings are not sensitive enough to warrant a Plan-C-style toggle. |
| Default-seed bootstrap | **Composite `isDefaultSeedUnedited` check; default seeds yield to cloud; pure defaults never pushed up** | Revision tracks file generation time, not user intent — naive LWW silently overwrites real data. Composite check + historical seed table is the only safe gate. |
| Conflict (both real edits) | **Doc-level revision LWW** | Simplest, mirrors Plan A/C; field-level merge would double schema size and complicate every edit path for a rarely-hit scenario. |
| Account switch (true identity change) | **Freeze-and-wait + force-apply cloud Y**: suspend pushes; wait for new account's KVS; if KVS Y has schema-compatible data, **force-apply (no LWW)** — local revision from account X is meaningless under identity Y. If KVS Y empty, keep local but stay suspended. | Cross-identity LWW would let account X's newer revision overwrite account Y's older real data. Identity transitions are not edit conflicts. |
| Account-switch trigger source | **Persisted ubiquity identity token diff + KVS `.accountChange`**, NOT `.catermICloudAccountChanged`. Token persisted via `NSKeyedArchiver(requiringSecureCoding: false)` (token only conforms to `NSCoding`, not `NSSecureCoding`). Transitions classified: `prev nil → curr nonnil = firstObservation` (BootstrapDecider); `prev nonnil → curr nonnil & differ = identityChanged` (AccountSwitchHandler); `prev nonnil → curr nil = signedOut` (stopSync); persisted Data == sentinel `"<archive-failed>"` → `unknownPrevious` (route to AccountSwitchHandler conservatively, never to revision LWW). | `.catermICloudAccountChanged` fires on every boot refresh (`CatermApp.swift:99`). Token diff alone would misclassify the "first time we've ever seen any token" case as a switch. The archive sentinel guards against the failure mode where archiving throws and falsely demotes a real prior identity to nil — that case must not fall back to BootstrapDecider's revision LWW. |
| Push timing post-account-switch | **First local user edit under new identity both unfreezes AND triggers immediate push of that flushed blob** | If we only unfreeze and wait for the *next* edit, quitting after one edit leaves account Y's KVS empty. |
| Initial sync as write barrier | **`pushSuspended = true` while initial sync is in progress.** `.initialSyncChange` does NOT signal completion — Apple's docs say the local store "is being initialized from iCloud" when this fires. Treat it as confirmation that hydration is in flight, then **extend** the barrier with a short grace backoff (500ms) before re-reading KVS and proceeding. Boot uses the same pattern: 3s wait for the notification; on arrival, add 500ms grace; on timeout, proceed anyway (no notification = nothing fresh to hydrate). | Apple's initial sync indicates hydration in progress; pushing during this window can overwrite cloud before the local view of cloud is populated. Treating `.initialSyncChange` as "ready" was the bug. |
| Schema version mismatch | **Reject merge if cloud.schemaVersion > local.schemaVersion**, log + keep local | Prevents older app versions from accidentally regressing newer data. Release cadence post-Plan-E is controlled, so version skew should be brief. |

## Data Model Changes

### `CatermSettings` v2 (additive, schema bump from v1)

```swift
public struct CatermSettings: Codable, Equatable {
    public var version: Int                  // bumped to 2
    public var revision: String              // existing — timestamp+random; doc-level LWW key
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var migrationsCompleted: Set<String>  // NEVER synced to KVS — local filesystem migration markers

    // NEW v2 fields:
    public var seedVersion: Int              // matches CatermSettings.defaultsSeed identity at seed time
    public var seededByDefault: Bool         // true iff load() took the "file missing / quarantined" path
    public var firstUserEditedAt: Date?      // set on first SettingsStore.update(_:); never reset
    public var canonicalSeedHash: String     // SHA-256 hex of canonical PartialSettings at seed time; "" if unknown
}
```

### KVS blob shape (subset of `CatermSettings`)

The KVS-encoded blob is a `SyncableSettings` projection — `CatermSettings` minus `migrationsCompleted`:

```swift
struct SyncableSettings: Codable {
    let version: Int
    let revision: String
    let global: PartialSettings
    let hostOverrides: [HostId: PartialSettings]
    let seedVersion: Int
    let seededByDefault: Bool
    let firstUserEditedAt: Date?
    let canonicalSeedHash: String
}
```

`migrationsCompleted` is **never written to or read from KVS**. It is per-device filesystem migration state (see `SettingsMigrationStep.runIfNeeded` checking the token before doing filesystem work like writing `placeholderUserConfig`). Syncing it would let device B skip filesystem migrations that have only run on device A. Stays in the local plist exclusively.

### v1 → v2 migration (in `SettingsStore.load`)

When decoding a v1 blob, classify by canonical shape against the v1 default seed:

```
1. Compute canonicalHash(v1.global) and check v1.hostOverrides.isEmpty.
2. If canonicalHash matches the v1 defaultsSeed canonical hash AND hostOverrides is empty:
     → seededByDefault: true
       firstUserEditedAt: nil
       seedVersion: 1
       canonicalSeedHash: <v1 seed canonical hash>
   Else:
     → seededByDefault: false
       firstUserEditedAt: Date() (sentinel: "edited before tracking, exact moment unknown")
       seedVersion: 1
       canonicalSeedHash: ""  // empty never matches KnownSeedTable, locks user in "real edits"
```

This preserves the "pure defaults never push" invariant for users who installed v1, never edited, and are now upgrading to v2. Without the shape check, every v1 user would be falsely flagged as "real edits" and the very first launch would push their unchanged defaults into KVS.

### `KnownSeedTable` (hardcoded, append-only)

Stores `(seedVersion, canonicalSeedHash, PartialSettings snapshot)` for every default seed shipped historically. Static `let` table; hashes computed once on first access (lazy-initialized). Each future change to `CatermSettings.defaultsSeed` appends a new entry to the table; entries are NEVER deleted, so old defaults are still recognized.

### `isDefaultSeedUnedited` predicate

ALL of:
1. `settings.seededByDefault == true`
2. `settings.firstUserEditedAt == nil`
3. `settings.seedVersion ∈ KnownSeedTable.versions`
4. `settings.canonicalSeedHash ∈ KnownSeedTable.hashes`
5. `settings.global` canonical-equals the seed table's snapshot for that version
6. `settings.hostOverrides.isEmpty`
7. `settings.migrationsCompleted ⊆ allMigrationsKnownAtBoot`

Any single failure → "real edits" (treated as user data).

## Module Layout

### New module: `apps/macos/Sources/SettingsSyncStore/`

Leaf target. Depends on `SettingsStore` + Foundation/CloudKit. No dependency from `SettingsStore` back into `SettingsSyncStore` (one-way arrow).

```
SettingsSyncStore.swift              // @MainActor coordinator; installLifecycleObservers/startSync/stopSync
BootstrapDecider.swift               // pure: (local, cloud) → Decision enum
AccountSwitchHandler.swift           // pure: (local, cloudY) → Decision enum (force-apply or suspend)
IsDefaultSeedUnedited.swift          // composite predicate
KnownSeedTable.swift                 // append-only historical seeds
KVSAdapter.swift                     // protocol KVSProtocol + NSUbiquitousKeyValueStore impl + reason classifier
IdentityTokenStore.swift             // archive/unarchive ubiquityIdentityToken; isEqual compare; UserDefaults persistence
SettingsBlobCodec.swift              // PropertyListEncoder round-trip + schema-version gate; SyncableSettings projection
```

### Modified: `apps/macos/Sources/SettingsStore/`

- `CatermSettings.swift` — schema v2 fields.
- `SettingsStore.swift`:
  - Seed path sets `seededByDefault = true`, `seedVersion`, `canonicalSeedHash`.
  - First call to `update(_:)` sets `firstUserEditedAt = Date()` if nil.
  - **NEW** `replaceFromSync(_ blob: SyncableSettings)` — sync-side cloud-apply API:
    - Writes the cloud blob's `revision` verbatim (does NOT call `makeRevision()`); `firstUserEditedAt` and `seededByDefault` from cloud override local; `migrationsCompleted` is preserved unchanged from local.
    - Atomically writes plist.
    - Posts `changeNotification` with `userInfo[sourceKey] = "sync"` (new constant `SettingsStore.sourceUserInfoKey`).
    - `SettingsSyncStore`'s push listener filters on `source == "sync"` and skips, breaking the apply→push feedback loop.
    - `LiveReloadCoordinator` ignores the source key and reloads as normal — sync-applied changes look like any other change to live-reload consumers.
- `SettingsMigrationStep.swift` — add v1→v2 step that uses canonical-shape detection (see Data Model Changes).

### Wired in: `apps/macos/Sources/Caterm/CatermApp.swift`

After `BootSequence.run` returns the `SettingsStore`, construct `SettingsSyncStore(store: settingsStore, kvs: NSUbiquitousKeyValueStore.default, accountSession: icloudSession, userDefaults: .standard, identityTokenStore: IdentityTokenStore())` and call `installLifecycleObservers()` followed by `startSync()`. The lifecycle observer for `.catermICloudAccountChanged` is the only thing that observes that notification, and only for the narrow purpose of detecting `isSignedIn == false → true` to re-trigger `startSync()`. Account-switch detection uses `IdentityTokenStore` (see Boot Sequence) instead.

## Observer Lifecycle

`SettingsSyncStore` has two observer groups with distinct lifetimes:

### Lifecycle observers (installed once at init, never removed)

- `.catermICloudAccountChanged` — sole purpose is detecting `isSignedIn == false → true` to call `startSync()`. Must persist across hot sign-out so the later sign-in is observed and triggers a restart.

### Sync observers (registered by `startSync()`, removed by `stopSync()`)

- `NSUbiquitousKeyValueStore.didChangeExternallyNotification`
- `SettingsStore.changeNotification` (push listener)

`stopSync()` (called on hot sign-out) only removes the **sync** observers; lifecycle observers stay registered. `startSync()` is idempotent — calling it while already-running is a no-op.

## Boot Sequence

```
1. SettingsStore.load(from: plistPath)              // existing, synchronous
2. SettingsSyncStore.installLifecycleObservers()    // app-lifetime, runs once
3. SettingsSyncStore.startSync():                   // idempotent
   a. If !accountSession.isSignedIn: no-op, return.
   b. pushSuspended = true                          // initial-sync write barrier
   c. Register sync observers (KVS didChangeExternally + SettingsStore.changeNotification).
   d. Read persisted token Data from UserDefaults key
      "caterm.settings.lastUbiquityIdentityToken":
        - if Data present, NSKeyedUnarchiver.unarchivedObject(of: NSObject.self,
          from: data) → previousToken (NSObject? conforming to NSCoding)
        - else previousToken = nil
      Read currentToken = FileManager.default.ubiquityIdentityToken (NSObject? conforming
      to NSCoding & NSCopying & NSObjectProtocol).
      Classify:
        - persisted Data == sentinel "<archive-failed>" → unknownPrevious (treat
          conservatively as identityChanged — route through AccountSwitchHandler,
          which is force-apply if Y has data, else stays suspended; never falls
          back to BootstrapDecider's revision LWW. This guarantees no cross-
          identity LWW even when archiving the previous token failed.)
        - previousToken == nil && currentToken == nil → notSignedIn (return)
        - previousToken == nil && currentToken != nil → firstObservation
        - previousToken != nil && currentToken == nil → signedOut (defensive — shouldn't
          reach here because step 3a already returned)
        - previousToken != nil && currentToken != nil:
            previousToken.isEqual(currentToken) → identitySame
            else → identityChanged
   e. KVS.synchronize() to trigger initial pull.
   f. Wait for didChangeExternallyNotification with reason == .initialSyncChange
      OR 3-second timeout, whichever first.
   g. If notification arrived: keep pushSuspended = true and wait an additional 500ms
      grace backoff. Apple's `.initialSyncChange` indicates hydration is *in progress*,
      not complete; the grace gives the in-memory store time to settle.
      If timeout fired: proceed (no notification = no fresh hydration in flight).
4. Decision:
   ┌─ identityChanged OR unknownPrevious
   │    └─ AccountSwitchHandler (see Account Switch Flow below)
   └─ firstObservation OR identitySame
        └─ BootstrapDecider.decide(local: SettingsStore.settings,
                                   cloud: SettingsBlobCodec.decode(KVS.data(forKey: KEY))):
             ┌─ cloud == nil
             │    ├─ local.isDefaultSeedUnedited → noOp
             │    └─ else → pushLocal
             └─ cloud != nil
                  ├─ cloud.schemaVersion > local.schemaVersion → rejectMerge (log, keep local)
                  ├─ local.isDefaultSeedUnedited → applyCloud
                  ├─ cloud.revision == local.revision → noOp
                  ├─ revision LWW with sanity check:
                  │    let cloudWins = cloud.revision > local.revision
                  │    let clockSkewSuspect = cloudWins
                  │      && local.firstUserEditedAt != nil
                  │      && local.firstUserEditedAt! > bootStartedAt
                  │    if cloudWins && !clockSkewSuspect → applyCloud
                  │    else → pushLocal
5. Persist current ubiquityIdentityToken via `IdentityTokenStore.archive(token)`,
   which uses `NSKeyedArchiver` with `requiringSecureCoding: false` — Apple only
   documents the token as `NSCoding & NSCopying & NSObjectProtocol`, NOT
   `NSSecureCoding`, so secure coding would throw on real-world tokens whose
   classes do not adopt the secure protocol. If archive throws (corrupt token,
   future-OS shape change), persist the sentinel string `"<archive-failed>"` as
   the stored Data marker and log a warning. Next-boot classification handles
   the sentinel (see step 3d below).
6. pushSuspended = false. Enter steady-state.
```

**`firstObservation` rationale**: this covers v1 → v2 upgraders signing in for the first time post-upgrade, AND fresh installs that signed in only after some local edits were made offline. In both cases there is no prior identity to leak from; treating it as a switch would silently quarantine real local edits until the user happened to make another change. Routing through `BootstrapDecider` lets these edits push naturally if KVS is empty, or yield to cloud if cloud has data.

## Push Pipeline: Control Plane vs Observer Plane

Pushes to KVS happen via two distinct paths and `pushSuspended` only gates the **observer plane**:

- **Observer plane** (gated by `pushSuspended`): `SettingsStore.changeNotification` listener inside `SettingsSyncStore`. When `pushSuspended == true`, the notification is observed but the resulting push is skipped.
- **Control plane** (NOT gated by `pushSuspended`): direct method calls invoked by `BootstrapDecider`'s `pushLocal` action, `AccountSwitchHandler`'s force-apply (which calls `replaceFromSync`, not push) and its first-edit unfreeze flow. These call the underlying `pushBlob(_:)` private method directly. They are deliberate decisions to push, not observer-triggered side effects.

This split exists because boot runs while `pushSuspended == true` (write barrier active), but the bootstrap decision may legitimately conclude "push local up". That conclusion is a control-plane action and proceeds regardless of the barrier. The barrier is for *uncontrolled* pushes from incidental user edits during hydration.

When AccountSwitchHandler hits the "Y empty, first user edit unfreezes" branch, the unfreeze flips `pushSuspended = false` BEFORE the observer-plane handler processes that notification — so the observer plane sees an unsuspended state and pushes normally. This is the only place where the two planes interact.

## Steady-State Triggers

### Local → KVS (push, observer plane)

- Source: `SettingsStore.changeNotification`.
- **Filter on `userInfo[sourceUserInfoKey]`**: if `"sync"`, the change came from `replaceFromSync` and must NOT be re-pushed (breaks the apply→push feedback loop). Otherwise it's a user/code-driven edit; proceed.
- Debounce: rely on the existing 200ms debounce in `SettingsStore.flushNow()`. `SettingsSyncStore` pushes after each `flushNow`. No additional debounce layer.
- Encode: `SettingsBlobCodec.encode(SyncableSettings.init(from: localSettings))` — strips `migrationsCompleted`.
- Write: `KVS.set(blob, forKey: KEY)` (returns Void; no in-band failure signal). Optionally call `KVS.synchronize()` for prompt persistence; `synchronize() -> Bool` indicates only that the local persistence to user defaults succeeded, not that the upload to iCloud has completed. Treat false as "retry next change"; treat the absence of any subsequent `.serverChange` over hours as a separate `syncStalled` heuristic (out of scope this round).
- Failure surface: quota errors arrive **only** via `didChangeExternallyNotification` with reason `.quotaViolationChange`; not via the set call.
- Suppression: when `pushSuspended == true` (initial-sync barrier or account-switch in progress), the change is observed but the push is skipped. The next *user-driven* change that arrives while `pushSuspended == false` will push the full current blob; nothing is queued.

### KVS → Local (pull)

`didChangeExternallyNotification` arrives with a `reason`. `SettingsSyncStore` dispatches:

- `.initialSyncChange`: hydration **in progress** signal (per Apple). Set `pushSuspended = true`, schedule a 500ms grace backoff, then re-read KVS and run the appropriate handler (`BootstrapDecider` if identity matches persisted, `AccountSwitchHandler` if identity differs — token re-checked, since `.initialSyncChange` and `.accountChange` can both indicate identity transitions in some scenarios). Restore `pushSuspended = false` after.
- `.serverChange`: another device pushed. Decode → `BootstrapDecider.decide(local, cloud)` → apply via `replaceFromSync`. Identity must match the persisted token; if not, route to `AccountSwitchHandler` instead.
- `.quotaViolationChange`: log, verify our key still present via `dictionaryRepresentation()`, do NOT apply or repush this turn. Re-push naturally on next user edit.
- `.accountChange`: route to `AccountSwitchHandler`.

`BootstrapDecider` is the **only** revision-LWW entry point. `AccountSwitchHandler` is the only force-apply entry point. Boot calls one of them once; every steady-state pull dispatches via reason. No duplicate merge logic across paths.

## Account Switch Flow

### Identifying a real switch

`AccountSwitchHandler` runs on either of:

- KVS `didChangeExternallyNotification` with reason `.accountChange`.
- Boot-time `ubiquityIdentityToken` classified as `identityChanged` (previous and current both non-nil and `isEqual` returns false) — see Boot Sequence step 3d.

`firstObservation` (previous nil, current non-nil) does NOT route here; it goes through `BootstrapDecider` because there is no prior identity to leak from.

It does **not** subscribe to `.catermICloudAccountChanged` directly — that notification is posted on every cold launch by `CatermApp.swift:99` as part of `iCloudAccountSession.refresh()`. (`SettingsSyncStore` does observe `.catermICloudAccountChanged` for one narrow purpose: detecting a transition from `isSignedIn == false` → `true` to call `startSync()`. That observer is in the lifecycle group, registered once for the app's lifetime.)

### Force-apply, not LWW

```
1. pushSuspended = true                          // observe local changes, do not push
2. KVS.synchronize()                             // request fresh pull for new account
3. Wait for next didChangeExternallyNotification (capture reason) OR 3-second timeout.
3a. If notification reason == .initialSyncChange: hydration is *in progress*; add
    a 500ms grace backoff before reading KVS, same rule as boot. Keep barrier up.
    If reason was something else (.serverChange, .accountChange) or timeout fired:
    proceed immediately — no grace needed.
4. cloudY = SettingsBlobCodec.decode(KVS.data(forKey: KEY))
   ┌─ cloudY != nil
   │    ├─ cloudY.schemaVersion > local.schemaVersion → rejectMerge (log, keep local,
   │    │   stay pushSuspended = true so we don't pollute Y; user must upgrade older Mac)
   │    └─ schema-compatible:
   │         FORCE-APPLY cloudY via replaceFromSync (no revision comparison —
   │         local revision belonged to account X and is meaningless under Y)
   │         pushSuspended = false
   │         Persist current ubiquityIdentityToken.
   └─ cloudY == nil (empty Y, or hydration timed out)
        keep local, stay pushSuspended = true
        UNFREEZE on first user-driven local change:
          - pushSuspended = false BEFORE handling the push for that change
          - That same change's blob is pushed immediately as account Y's first data
          - Persist current ubiquityIdentityToken.
```

**Critical**: cross-identity LWW is forbidden. If account X's local revision is newer than account Y's cloud revision (entirely possible — X has been actively edited on this Mac), naive LWW would push X's settings into Y and corrupt Y's data on every other Y device. Force-apply guarantees account isolation.

**Critical (unfreeze ordering)**: when KVS Y was empty and the user makes their first local edit under Y, the unfreeze MUST happen before the push for that same edit, not after. Otherwise: edit → push skipped → app quits → KVS Y stays empty.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `KVS.synchronize()` returns false | Indicates local persistence to user defaults failed (rare). Log, rely on next change. `KVS.set(_:forKey:)` itself returns Void — there is no in-band failure signal at write time. |
| `.quotaViolationChange` notification | Log, verify our key, no-op. Re-push naturally on next local change. |
| Cloud blob decode failure | Log error, mirror corrupt blob to `~/Library/Application Support/Caterm/settings-cloud-broken-<ISO8601>.plist`, keep local untouched. Do NOT overwrite cloud — avoid clobbering valid data on other devices. |
| `cloud.schemaVersion > local.schemaVersion` | Reject merge, log warning, keep local. User upgrades older Mac to resolve. |
| iCloud signed out (cold) | Lifecycle observers (incl. `.catermICloudAccountChanged`) are still registered at init time. `startSync()` no-ops because `isSignedIn == false`; sync observers (KVS + SettingsStore push listener) are NOT registered. Local `SettingsStore` continues working. Later sign-in posts `.catermICloudAccountChanged`, the lifecycle observer calls `startSync()`, and full boot/sync flow runs. |
| iCloud signed out (hot, while running) | `.catermICloudAccountChanged` fires with `isSignedIn == false` → `stopSync()`: remove the **sync** observers, set `pushSuspended = true`. Lifecycle observer for `.catermICloudAccountChanged` stays registered. Local writes still flush to plist. On next sign-in, the lifecycle observer calls `startSync()` again. |
| Local plist corrupted | Existing `quarantineCorrupted` runs in `SettingsStore.load`, re-seeds defaults with `seededByDefault: true`. Boot decider then applies cloud if cloud has data — free recovery path. |
| Clock skew (system time changed) | Boot decider has a sanity check: if cloud appears newer but `local.firstUserEditedAt > bootStartedAt`, prefer local. Imperfect but stops the worst case where rewinding the clock erases real edits. |
| KVS slow on cold boot | 3-second timeout. If KVS data arrives later (e.g., 5s in), the resulting `didChangeExternallyNotification` re-runs the decider — eventual convergence. Local pushes during that window are preserved (LWW will reconcile). |

## Test Plan

### Unit (`apps/macos/Tests/SettingsSyncStoreTests/`)

- **`BootstrapDeciderTests`** — 8 branches:
  1. cloud nil + local seed → noOp
  2. cloud nil + local real edits → pushLocal
  3. cloud real + local seed → applyCloud
  4. cloud real + local real + cloud.revision > local → applyCloud
  5. cloud real + local real + cloud.revision < local → pushLocal
  6. cloud real + local real + revision equal → noOp (anti-flap)
  7. cloud.schemaVersion > local → rejectMerge
  8. clock-skew sanity: cloud.revision > local but local.firstUserEditedAt > bootStartedAt → pushLocal
- **`IsDefaultSeedUneditedTests`** — 1 positive + 7 negatives (each predicate condition broken in isolation).
- **`SettingsBlobCodecTests`** — round-trip; v1 blob decode; corrupted bytes; schema gate.
- **`KVSAdapterTests`** — fake KVS verifies set/get/notification routing; reason classifier.
- **`SettingsSyncStoreTests`** —
  - `installLifecycleObservers` registers `.catermICloudAccountChanged` observer; remains registered across `stopSync()`
  - `startSync` is idempotent
  - signed-out cold start: lifecycle observer registered, sync observers not registered, later sign-in triggers full flow
  - hot sign-out: sync observers removed, lifecycle observer survives, subsequent sign-in resumes
  - initial-sync write barrier: pushes during the boot wait window are dropped, replayed implicitly by the next user change after barrier lifts
  - `.initialSyncChange` arrival extends barrier with 500ms grace, then re-runs decider; pushes during the grace are also suspended
  - replaceFromSync feedback-loop suppression: applying cloud emits change notification with `source == "sync"`, push listener filters and does not re-push
  - cold launch where unarchived token `isEqual` persisted → identitySame → bootstrap path
  - cold launch where unarchived token does NOT `isEqual` persisted → identityChanged → AccountSwitchHandler
  - cold launch where persisted token absent and current non-nil → firstObservation → BootstrapDecider (NOT AccountSwitchHandler)
  - both nil → notSignedIn no-op
  - `.catermICloudAccountChanged` does NOT trigger account-switch flow on its own
- **`IdentityTokenStoreTests`** —
  - archive/unarchive round-trip via `NSKeyedArchiver` with `requiringSecureCoding: false`
  - **fake token conforming to `NSCoding & NSCopying & NSObjectProtocol` but NOT `NSSecureCoding`** archives successfully (regression guard against accidentally re-enabling secure coding)
  - `isEqual` comparison detects same vs different tokens
  - persisted Data corruption (truncated bytes) → load returns nil, no crash
  - archive failure path (e.g., token whose encoder throws): persists sentinel `"<archive-failed>"` Data; subsequent load returns the sentinel; classifier maps sentinel → `unknownPrevious`
- **`AccountSwitchHandlerTests`** (additional) —
  - `unknownPrevious` classification (sentinel persisted) routes through AccountSwitchHandler regardless of current token: KVS Y has data → force-apply; empty → suspend
  - notification with reason `.initialSyncChange` adds 500ms grace before reading KVS Y; reason `.serverChange` / `.accountChange` reads immediately
- **`AccountSwitchHandlerTests`** —
  - Y has data + schema OK → force-apply (verifies revision is NOT compared)
  - Y has data + schema newer than local → rejectMerge, keep local, stay suspended
  - Y empty → suspend persists, first local edit unfreezes BEFORE push so that edit's blob lands in Y
  - Y empty + app quits before any edit → no push, KVS Y remains empty (acceptable)
- **`SettingsStoreReplaceFromSyncTests`** — `replaceFromSync` preserves cloud `revision` (no `makeRevision` bump), preserves local `migrationsCompleted`, posts `changeNotification` with `userInfo[sourceUserInfoKey] == "sync"`.

### Integration (`apps/macos/Tests/SettingsSyncStoreIntegrationTests/`)

Two-Mac simulator using a `FakeKVS` shared between two `SettingsSyncStore` instances:

1. **Basic propagate.** A edits font → KVS → B sees notification → applies.
2. **Concurrent both-edit conflict.** A and B both edit while offline; B reconnects later, has newer revision → wins; A's loser changes lost (documented).
3. **Anti seed-pollution (core scenario).** A has real edits + revision T. B is fresh-seeded yesterday at T+1day with default seed. B boots with KVS available → `isDefaultSeedUnedited` true → applyCloud. A's data preserved.
4. **Clock-tampered seed.** Same as 3 but B's clock is set 1 year in future. `isDefaultSeedUnedited` doesn't depend on time → still applyCloud.
5. **Account switch — Y has data, force-apply.** A's local was edited under account X with revision `T2`. Account Y's KVS holds an older blob with revision `T1` (`T1 < T2`). Switch identity. Verify: `replaceFromSync` applies Y's blob despite older revision (force-apply, NOT LWW); local is now Y's data; persisted token updated.
6. **Account switch — Y empty, first edit pushes.** A is signed in to X with real edits, KVS X has data. User signs out, signs in to Y; KVS Y is empty. Verify: A's local data is preserved but `pushSuspended` stays true. Make a local edit → that single edit's blob is pushed to Y on the same flush cycle. Quit before edit ⇒ Y stays empty.
7. **`.catermICloudAccountChanged` is not enough alone.** Post the broad notification without changing the persisted ubiquityIdentityToken. Verify: no account-switch path fires; pushes continue normally.
8. **Initial-sync write barrier.** During the 3-second boot wait, fire local edits via `SettingsStore.update`. Verify: no `KVS.set` calls happen until `.initialSyncChange` arrives + 500ms grace OR timeout fires. Also: a steady-state `.initialSyncChange` mid-session re-suspends pushes for 500ms grace.
8a. **firstObservation upgrade path.** v2 build's first launch: persisted token absent, current `ubiquityIdentityToken` non-nil. Local has real edits (v1 plist, edited). KVS empty. Verify: `BootstrapDecider` runs (not `AccountSwitchHandler`); local pushed up immediately via control-plane (despite `pushSuspended == true` during the boot barrier); persisted token written. NOT silently quarantined.
8b. **Archive-failure sentinel routes safely.** Inject an `IdentityTokenStore` whose archive throws. Run boot. Verify: sentinel `"<archive-failed>"` is persisted; on the *next* boot, classifier returns `unknownPrevious` and routes to AccountSwitchHandler (force-apply if Y has data, else suspend) — never to BootstrapDecider's revision LWW. This is the cross-identity-leak guard for archive failures.
8c. **AccountSwitch + initialSyncChange grace.** During account-switch flow, the wait completes with `.initialSyncChange` reason. Verify: 500ms grace fires before KVS read. Without grace, KVS Y is read while still hydrating and may appear empty when it actually has data.
9. **Schema version reject.** v3 blob in KVS, v2 client decodes → rejectMerge, local untouched.
10. **`migrationsCompleted` does not sync.** Device A has token `settings-gui-v1` set; pushes blob to KVS. Device B (without the token) decodes — its `migrationsCompleted` is unchanged. Then Device B applies its own filesystem migration, sets the token locally, the token does NOT propagate via `replaceFromSync` from any subsequent A push.
11. **v1 → v2 unedited migration.** v1 plist with `global == defaultsSeed` and empty `hostOverrides` migrates with `seededByDefault = true`, `firstUserEditedAt = nil`, `canonicalSeedHash` populated. `isDefaultSeedUnedited` returns true. KVS empty + this state ⇒ no push.
12. **v1 → v2 edited migration.** v1 plist with any deviation from default seed migrates with `seededByDefault = false`, `firstUserEditedAt = Date()`, `canonicalSeedHash = ""`. `isDefaultSeedUnedited` returns false. KVS empty + this state ⇒ pushLocal.

### Manual real-device verification

Tracked in plan as a Plan-D-Task-N checklist; done before merging:
- Two Macs, same Apple ID, both running v2 build: edit on A, observe propagation to B within ~30s (KVS is typically faster).
- Edit on A while B offline; bring B online; verify revision LWW picks correct winner.
- Sign out / sign in to a different Apple ID on B: verify no settings bleed across accounts.
- Sign out / sign in to a different Apple ID on B with non-empty KVS on Y: verify B picks up Y's settings.

## Affected Existing Tests

`SettingsStoreTests` constructs `CatermSettings` instances; v2 fields default to safe values via the new initializer signature, but `Equatable` comparisons that include the whole struct may need `firstUserEditedAt` plumbing. Inventory + fix is one of the implementation tasks.

## Implementation Workload

13 tasks, ~1 day:

1. `CatermSettings` v2 schema fields + canonical-shape v1→v2 migration in `SettingsStore.load` (anti-pollution path).
2. `SettingsStore` plumbing: `firstUserEditedAt` set on first `update(_:)`; seed path sets `seededByDefault` + `seedVersion` + `canonicalSeedHash`; new `replaceFromSync(_:)` preserving cloud revision and posting `userInfo[sourceUserInfoKey] = "sync"`; preserves local `migrationsCompleted`.
3. `KnownSeedTable` (append-only) + canonical hash helper.
4. `IsDefaultSeedUnedited` predicate + unit tests (1 positive + 7 negatives).
5. `SyncableSettings` projection + `SettingsBlobCodec` (encode strips `migrationsCompleted`; decode + schema gate) + unit tests.
6. `KVSAdapter` protocol (`set(_:forKey:)` Void; `synchronize() -> Bool`; `data(forKey:)`; `removeObject(forKey:)`; `dictionaryRepresentation()`) + `NSUbiquitousKeyValueStore` impl + reason classifier + unit tests. Identity-token persistence is **not** part of this adapter — it lives in `SettingsSyncStore` which reads `FileManager.default.ubiquityIdentityToken` directly and archives via `NSKeyedArchiver`. `IdentityTokenStore` helper handles archive/unarchive + `isEqual(_:)` comparison + UserDefaults plumbing; unit tested separately.
7. `BootstrapDecider` pure function + unit tests (8 branches).
8. `AccountSwitchHandler` pure function + unit tests (force-apply, schema reject, empty Y, schema-newer reject).
9. `SettingsSyncStore` coordinator: install lifecycle observers + `startSync()` / `stopSync()` lifecycle, initial-sync write barrier with 500ms grace backoff (boot AND in AccountSwitchHandler when reason == .initialSyncChange), control-plane vs observer-plane push split, token classification (notSignedIn / firstObservation / identitySame / identityChanged / unknownPrevious), push listener with `source == "sync"` filter, pull dispatcher by KVS reason, freeze/unfreeze ordering on first edit + unit tests.
10. `CatermApp` wiring + boot sequence integration. Persists `caterm.settings.lastUbiquityIdentityToken` in UserDefaults.
11. Two-Mac integration test suite covering all 12 scenarios listed above.
12. `docs/macos-cloudkit-settings-sync.md` operator-facing doc (architecture diagram + decision tree + identity token semantics).
13. Manual real-device verification checklist + run.

## Open Items / Deferred

- **Sidebar indicator for `syncStalled`.** Hooks left in code but no UI consumer this round. Pull into Plan E or a follow-up if real users complain.
- **`hostOverrides` GC for deleted hosts.** Currently kept on the assumption that storage is cheap. Revisit if anyone hits the 1 MB cap.
- **Field-level merge.** Reserved as Plan D.1 if doc-level LWW produces user-visible regressions in practice.

## References

- `docs/superpowers/specs/2026-05-02-cloudkit-keychain-sync-design.md` — Plan C, similar coordinator + reset patterns.
- `docs/superpowers/plans/2026-05-02-cloudkit-host-sync.md` — Plan A, KVS predecessor for `iCloudAccountSession` + `.catermICloudAccountChanged`.
- Apple — `NSUbiquitousKeyValueStore`: https://developer.apple.com/documentation/Foundation/NSUbiquitousKeyValueStore
- Apple — Synchronizing app preferences with iCloud: https://developer.apple.com/documentation/foundation/icloud/synchronizing_app_preferences_with_icloud
