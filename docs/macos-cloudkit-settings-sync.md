# macOS Settings Sync (CloudKit / NSUbiquitousKeyValueStore)

Caterm syncs the user-facing portion of `CatermSettings` across the
user's iCloud-signed-in Macs via `NSUbiquitousKeyValueStore`. This
document describes the runtime model, the bootstrap decision tree, and
how to reset KVS during development.

## Architecture

- **Storage:** single key `caterm.settings.v1` holds a property-list-
  encoded `SyncableSettings` projection of `CatermSettings`. Local-only
  fields (`migrationsCompleted`) are stripped.
- **Conflict resolution:** doc-level revision LWW for same-identity
  edits. Cross-identity transitions are force-apply, not LWW.
- **Identity isolation:** the previous `ubiquityIdentityToken` is
  persisted in `UserDefaults` (`caterm.settings.lastUbiquityIdentityToken`).
  On boot, classification produces one of:
  `notSignedIn / firstObservation / identitySame / identityChanged /
  signedOut / unknownPrevious`. Identity transitions go through
  `AccountSwitchHandler`, not `BootstrapDecider`.

## Boot decision tree

```
classify(persistedToken, currentToken):
  identitySame OR firstObservation
    → BootstrapDecider:
        cloud nil       → if isDefaultSeedUnedited: noOp else pushLocal
        cloud schema-newer → rejectMerge (keep local)
        local seed      → applyCloud
        revision LWW    → newer wins, with clock-skew sanity check

  identityChanged OR unknownPrevious
    → AccountSwitchHandler:
        cloud Y schema-newer → rejectMerge, stay suspended, NO token persist
        cloud Y schema-OK    → forceApply Y, persist new token
        cloud Y empty        → suspendUntilFirstEdit, NO token persist;
                                first user edit unfreezes + pushes + persists token
```

## Initial-sync write barrier

Apple's `.initialSyncChange` indicates the in-memory store is being
re-populated from iCloud. Treat it as a write barrier:
- `pushSuspended = true` on entry.
- After 500ms grace, run the classifier-then-handler dispatch.
- The grace gives the in-memory store time to settle; reading KVS
  before grace can return stale-empty.

## Two push planes

- **Observer plane** — gated by `pushSuspended`. Triggered by
  `SettingsStore.changeNotification` with
  `userInfo[sourceUserInfoKey] != "sync"`. Skipped while suspended.
- **Control plane** — direct push from `BootstrapDecider.pushLocal`,
  `AccountSwitchHandler.forceApply` (via `replaceFromSync`), and the
  first-edit unfreeze flow. NOT gated by `pushSuspended`.

This split is what lets `BootstrapDecider` legitimately push local up
during the boot write barrier — the decision is deliberate, not an
incidental observer side effect.

## Resetting KVS during development

If a stale blob is causing test confusion:

```bash
# Erase only the Caterm settings entry
defaults delete com.apple.applicationaccess "caterm.settings.v1"

# Reset the persisted identity token
defaults delete com.caterm.app caterm.settings.lastUbiquityIdentityToken
```

A full nuke (all KVS data for Caterm in this user account):

1. Quit Caterm.
2. Sign out of iCloud, sign back in.
3. Relaunch Caterm — `firstObservation` will re-bootstrap.

## Schema versioning

Devices reject a cloud blob whose `version` is greater than the local
build's known schema version. The user must upgrade the older Mac.

When adding a new schema field:
1. Bump `CatermSettings.version` and add fallback decoding in
   `init(from:)` so older blobs decode with safe defaults.
2. Append a new entry to `KnownSeedTable` if `defaultsSeed` changed.
3. Both forward (newer client reads older blob) and backward (older
   rejects newer) directions are tested in
   `SettingsSyncStoreTests/BootstrapDeciderTests` and the two-Mac
   suite.

## Manual real-device verification

Before shipping:

- Two Macs, same Apple ID, both running new build:
  - Edit on A → propagation to B within ~30s.
  - Edit on A while B offline; bring B online → revision LWW picks correct winner.
- Sign out / sign in to a different Apple ID on B (KVS Y empty):
  - Verify B's settings stay local; no push to Y.
  - Make a local edit → B pushes to Y.
- Sign out / sign in to a different Apple ID on B (KVS Y populated by another device):
  - Verify B picks up Y's settings on next boot (force-apply).

## Known limitations

- Concurrent two-Mac edits to *different* fields will lose one set of
  changes (doc-level LWW). Field-level merge is reserved as Plan D.1.
- KVS upload latency is ~30s typical, ~minutes worst case under
  development APS throttling. Not a correctness issue — eventual
  convergence holds.
