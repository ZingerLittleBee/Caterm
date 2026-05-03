# Plan D — CloudKit Settings KV Sync Design

**Status:** brainstormed 2026-05-03, awaiting user review.
**Scope:** Sync `CatermSettings` (terminal preferences, host overrides, migration markers) across the user's Macs via `NSUbiquitousKeyValueStore`. Replaces the implicit "settings stay local" behavior; does NOT touch hosts (Plan A), pushes (Plan B), or credentials (Plan C).
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
| Data shape on KVS | **Single blob** under one key (`caterm.settings.v1`) | Atomic; `migrationsCompleted` syncs naturally; estimated < 10 KB vs 1 MB cap; concurrent edits rare so doc-level LWW is acceptable. |
| Enablement | **Always-on** when iCloud signed in | Mirrors Plan A; settings are not sensitive enough to warrant a Plan-C-style toggle. |
| Default-seed bootstrap | **Composite `isDefaultSeedUnedited` check; default seeds yield to cloud; pure defaults never pushed up** | Revision tracks file generation time, not user intent — naive LWW silently overwrites real data. Composite check + historical seed table is the only safe gate. |
| Conflict (both real edits) | **Doc-level revision LWW** | Simplest, mirrors Plan A/C; field-level merge would double schema size and complicate every edit path for a rarely-hit scenario. |
| Account switch | **Freeze-and-wait**: suspend pushes on `.CKAccountChanged`; wait for new account's KVS; if KVS empty, keep local but stay suspended; user's first edit under new account unfreezes + pushes | Identity isolation without losing the user's current session. |
| Push timing post-account-switch | **Any local edit unfreezes** | "User edits = accepts new identity"; auto-unfreeze would silently bleed account X's settings into account Y. |
| Schema version mismatch | **Reject merge if cloud.schemaVersion > local.schemaVersion**, log + keep local | Prevents older app versions from accidentally regressing newer data. Release cadence post-Plan-E is controlled, so version skew should be brief. |

## Data Model Changes

### `CatermSettings` v2 (additive, schema bump from v1)

```swift
public struct CatermSettings: Codable, Equatable {
    public var version: Int                  // bumped to 2
    public var revision: String              // existing — timestamp+random; doc-level LWW key
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var migrationsCompleted: Set<String>

    // NEW v2 fields:
    public var seedVersion: Int              // matches CatermSettings.defaultsSeed identity at seed time
    public var seededByDefault: Bool         // true iff load() took the "file missing / quarantined" path
    public var firstUserEditedAt: Date?      // set on first SettingsStore.update(_:); never reset
    public var canonicalSeedHash: String     // SHA-256 hex of canonical PartialSettings at seed time; "" for migrated v1 users
}
```

### v1 → v2 migration (in `SettingsStore.load`)

When decoding a v1 blob, fill new fields conservatively:
- `seededByDefault: false` — assume migrated user has edited
- `firstUserEditedAt: Date()` (now) — opaque sentinel meaning "before we tracked it"
- `seedVersion: 1`
- `canonicalSeedHash: ""` — empty string never matches `KnownSeedHashes`, so migrated user is always "real edits"

This guarantees no migrated v1 user is ever misclassified as `isDefaultSeedUnedited`.

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
SettingsSyncStore.swift              // @MainActor coordinator; start/stop/freeze
BootstrapDecider.swift               // pure: (local, cloud, accountState) → Decision enum
IsDefaultSeedUnedited.swift          // composite predicate
KnownSeedTable.swift                 // append-only historical seeds
KVSAdapter.swift                     // protocol KVSProtocol + NSUbiquitousKeyValueStore impl
SettingsBlobCodec.swift              // PropertyListEncoder round-trip + schema-version gate
```

### Modified: `apps/macos/Sources/SettingsStore/`

- `CatermSettings.swift` — schema v2 fields.
- `SettingsStore.swift` — `wasSeeded: Bool` flag exposed on the store; first call to `update(_:)` sets `firstUserEditedAt = Date()` if nil; seed path sets `seededByDefault = true`, `seedVersion`, `canonicalSeedHash`.
- `SettingsMigrationStep.swift` — add v1→v2 step.

### Wired in: `apps/macos/Sources/Caterm/CatermApp.swift`

After `BootSequence.run` returns the `SettingsStore`, construct `SettingsSyncStore(store: settingsStore, kvs: NSUbiquitousKeyValueStore.default, accountSession: icloudSession)` and call `start()`. Subscribe to `.catermICloudAccountChanged`.

## Boot Sequence

```
1. SettingsStore.load(from: plistPath)         // existing, synchronous
2. SettingsSyncStore.start():
   a. If !accountSession.isSignedIn: no-op, return.
   b. KVS.synchronize() to trigger initial pull.
   c. Wait for `didChangeExternallyNotification` (any reason)
      OR 3-second timeout, whichever first.
3. BootstrapDecider.decide(local: SettingsStore.settings, cloud: KVS.data(forKey: KEY)):
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
4. Steady-state: subscribe to didChangeExternallyNotification + SettingsStore.changeNotification.
```

## Steady-State Triggers

### Local → KVS (push)

- Source: `SettingsStore.changeNotification`. Scope is ignored; always push the full blob.
- Debounce: rely on the existing 200ms debounce in `SettingsStore.flushNow()`. `SettingsSyncStore` pushes after each `flushNow`. No additional debounce layer.
- Failure: `KVS.set` is fire-and-forget; KVS handles retry. If `synchronize()` returns false 5 consecutive times, log a warning and set `syncStalled` flag (currently unused; reserved for a future indicator).
- Suppression: when `pushSuspended == true` (account switch in progress), changes are observed but not pushed.

### KVS → Local (pull)

`didChangeExternallyNotification` arrives with a `reason`:

- `.serverChange` / `.initialSyncChange`: decode → run `BootstrapDecider.decide(local, cloud)` → apply.
- `.quotaViolationChange`: log, verify our key still present via `dictionaryRepresentation()`, do not apply.
- `.accountChange`: trigger account-switch flow (below).

`BootstrapDecider` is the **only** merge entry point. Boot calls it once; every steady-state pull calls it again. No duplicate logic.

## Account Switch Flow

Triggered by `.catermICloudAccountChanged` (Plan A's existing notification, posted by `iCloudAccountSession`).

```
1. pushSuspended = true                        // observe local changes, do not push
2. KVS.synchronize()                           // request fresh pull for new account
3. Wait for next didChangeExternallyNotification OR 3-second timeout.
4. If KVS has data:
     run BootstrapDecider.decide → typically applyCloud (local is account-X edits;
     cloud is account-Y data; revision LWW usually picks newer cloud)
     pushSuspended = false
   If KVS empty + timeout:
     keep local, stay pushSuspended = true
     UNFREEZE: on next user-driven local edit (next flushNow with semantic change),
     pushSuspended = false → push begins on the following change.
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `KVS.set` returns false | Log; rely on next change for retry. After 5 consecutive failures, set `syncStalled`. |
| `.quotaViolationChange` notification | Log, verify our key, no-op. Re-push naturally on next local change. |
| Cloud blob decode failure | Log error, mirror corrupt blob to `~/Library/Application Support/Caterm/settings-cloud-broken-<ISO8601>.plist`, keep local untouched. Do NOT overwrite cloud — avoid clobbering valid data on other devices. |
| `cloud.schemaVersion > local.schemaVersion` | Reject merge, log warning, keep local. User upgrades older Mac to resolve. |
| iCloud signed out (cold) | `start()` no-ops; observers not registered; local `SettingsStore` continues working. |
| iCloud signed out (hot, while running) | `.catermICloudAccountChanged` fires with `isSignedIn == false` → `stop()`: remove observers, set `pushSuspended = true`. Local writes still flush to plist. On next sign-in, `start()` re-runs the boot sequence. |
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
- **`SettingsSyncStoreTests`** — start/stop, account switch freeze-unfreeze, debounce push, signed-out no-op.

### Integration (`apps/macos/Tests/SettingsSyncStoreIntegrationTests/`)

Two-Mac simulator using a `FakeKVS` shared between two `SettingsSyncStore` instances:

1. **Basic propagate.** A edits font → KVS → B sees notification → applies.
2. **Concurrent both-edit conflict.** A and B both edit while offline; B reconnects later, has newer revision → wins; A's loser changes lost (documented).
3. **Anti seed-pollution (core scenario).** A has real edits + revision T. B is fresh-seeded yesterday at T+1day with default seed. B boots with KVS available → `isDefaultSeedUnedited` true → applyCloud. A's data preserved.
4. **Clock-tampered seed.** Same as 3 but B's clock is set 1 year in future. `isDefaultSeedUnedited` doesn't depend on time → still applyCloud.
5. **Account switch.** A on account X → real edits pushed. Switch to account Y → KVS empty for Y. Verify no push happens. Edit something locally → push begins.
6. **Schema version reject.** v3 blob in KVS, v2 client decodes → rejectMerge, local untouched.

### Manual real-device verification

Tracked in plan as a Plan-D-Task-N checklist; done before merging:
- Two Macs, same Apple ID, both running v2 build: edit on A, observe propagation to B within ~30s (KVS is typically faster).
- Edit on A while B offline; bring B online; verify revision LWW picks correct winner.
- Sign out / sign in to a different Apple ID on B: verify no settings bleed across accounts.
- Sign out / sign in to a different Apple ID on B with non-empty KVS on Y: verify B picks up Y's settings.

## Affected Existing Tests

`SettingsStoreTests` constructs `CatermSettings` instances; v2 fields default to safe values via the new initializer signature, but `Equatable` comparisons that include the whole struct may need `firstUserEditedAt` plumbing. Inventory + fix is one of the implementation tasks.

## Implementation Workload

11 tasks, half-day to one day:

1. v1→v2 schema migration in `CatermSettings` + `SettingsStore` plumbing for `seededByDefault` / `firstUserEditedAt` / `seedVersion` / `canonicalSeedHash`.
2. `KnownSeedTable` + canonical hash function.
3. `IsDefaultSeedUnedited` predicate + unit tests.
4. `SettingsBlobCodec` (encode/decode + schema gate) + unit tests.
5. `KVSAdapter` protocol + `NSUbiquitousKeyValueStore` impl + unit tests.
6. `BootstrapDecider` pure-function + unit tests (8 branches).
7. `SettingsSyncStore` coordinator (start/stop, push, pull, account switch) + unit tests.
8. `CatermApp` wiring + boot sequence integration.
9. Two-Mac integration test suite.
10. `docs/macos-cloudkit-settings-sync.md` operator-facing doc (architecture diagram + decision tree).
11. Manual real-device verification checklist + run.

## Open Items / Deferred

- **Sidebar indicator for `syncStalled`.** Hooks left in code but no UI consumer this round. Pull into Plan E or a follow-up if real users complain.
- **`hostOverrides` GC for deleted hosts.** Currently kept on the assumption that storage is cheap. Revisit if anyone hits the 1 MB cap.
- **Field-level merge.** Reserved as Plan D.1 if doc-level LWW produces user-visible regressions in practice.

## References

- `docs/superpowers/specs/2026-05-02-cloudkit-keychain-sync-design.md` — Plan C, similar coordinator + reset patterns.
- `docs/superpowers/plans/2026-05-02-cloudkit-host-sync.md` — Plan A, KVS predecessor for `iCloudAccountSession` + `.catermICloudAccountChanged`.
- Apple — `NSUbiquitousKeyValueStore`: https://developer.apple.com/documentation/Foundation/NSUbiquitousKeyValueStore
- Apple — Synchronizing app preferences with iCloud: https://developer.apple.com/documentation/foundation/icloud/synchronizing_app_preferences_with_icloud
