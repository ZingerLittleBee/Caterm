# Pre-ship Two-Mac Smoke (Plan E Phase 3)

End-to-end live verification of CloudKit-backed sync against the **Production**
container. Run this **after** Phase 1 + Phase 2 are merged and a Distribution
build (`make dist`) is signed, embedded, and verified per
`docs/macos-dev-signing.md`.

This consolidates Plan E Tasks 3.1, 3.2, and 3.3 into a single tester
checklist so a single human can sign off both Macs without bouncing between
documents.

## Prerequisites

- [ ] CloudKit container `iCloud.com.caterm.app` schema deployed to **Production**
      (CK Dashboard → "Deploy to Production"). Schema must include the `Host`
      record type queryable on `recordName`, plus the credential blob fields
      from Plan C.
- [ ] Plan D settings sync uses `NSUbiquitousKeyValueStore` key
      `caterm.settings.v1`. KVS has no CK Dashboard schema; provisioning is
      automatic per-account. Verified at runtime in §3.
- [ ] Two physical Macs (Mac-A, Mac-B), both signed in to the same iCloud
      account "user-A". A spare iCloud account "user-B" available for §3 Step
      3-4.
- [ ] `make dist` produced a Distribution-signed `.app` and `dist-package.sh`'s
      three-way verification passed (bundle + main + askpass entitlements all
      green; askpass carries no app/team identity entitlements).
- [ ] On launch, `Console.app` (subsystem `com.caterm.app`, category
      `signing-diag`) shows one line:
      `Resolved entitlements: aps=production ck-env=Production`.
      **If `ck-env` is unset or `Development`, STOP** — the build is going to
      hit the wrong container.
- [ ] The Distribution `.app` is installed and launched at least once on both
      Macs (so APS device tokens register and CloudKit subscriptions exist).
      Confirm via `Console.app` filter `com.caterm.app` / `cloudkit-sync`:
      `APS register OK: token-bytes=32`.

## Test machine identifiers (record before starting)

| | Mac-A | Mac-B |
|---|---|---|
| Mac model + macOS version | | |
| Caterm build commit | | |

---

## §1 — Silent push live delivery (observability, NOT gate)

Reference: Plan E Task 3.1 / `docs/superpowers/plans/2026-05-02-cloudkit-push-subscriptions.md` Task 2.5.

Per Apple's `CKQueryNotification` documentation, silent push (`content-available: 1`)
is delivered best-effort: the system MAY coalesce, drop, or delay individual
notifications. **This section observes push behavior; it is NOT a hard pass/fail
gate.** The load-bearing sync triggers per `cloudkit_migration_status.md` are:
60-min forceFull, per-launch incremental, iCloud-account-change observers.
Push is acceleration on top.

Both Macs run Caterm in the foreground throughout. Writer is Mac-B; reader is
Mac-A. (The same machine cannot be both source and destination of a CloudKit
silent push.)

- [ ] **Step 1**: Mac-A Caterm running, foreground. Mac-B Caterm running,
      foreground. Confirm both show "Signed in to iCloud" in Preferences →
      Sync.
- [ ] **Step 2**: On Mac-B, modify Host X's port via the host edit sheet. Wait
      for the local push to complete — `Console.app` filtered on
      `CloudKitSyncClient` should show a successful save record op.
- [ ] **Step 3**: Observe Mac-A. `AppDelegate.application(_:didReceiveRemoteNotification:)`
      (the AppKit two-arg form, NOT the iOS `fetchCompletionHandler:` shape)
      logs the push, `parsePushUserInfo` dispatches, and the host list reflects
      the change. **Record the latency** from Mac-B save-success to Mac-A UI
      update.
- [ ] **Step 4**: Repeat 5 times with different fields (port, label,
      username). Record each latency in the table below.
- [ ] **Step 5**: Repeat once with Mac-A AppNapped (foreground but demoted —
      Activity Monitor shows "App Nap: Yes"). Record same metrics.
- [ ] **Step 6 (gate)**: Quit Mac-A Caterm; reopen it. Confirm the per-launch
      incremental sync pulls Mac-B's edits regardless of whether push delivered.
      **This is the gate** — push delivery is not.

### §1 latency table

| Attempt | Field changed | Latency (s) | Delivered? | Notes |
|---------|---------------|-------------|------------|-------|
| 1 | port    |  | yes / no |  |
| 2 | label   |  | yes / no |  |
| 3 | username|  | yes / no |  |
| 4 |         |  | yes / no |  |
| 5 |         |  | yes / no |  |
| AppNap (Step 5) | |  | yes / no |  |

### §1 pass criteria

- **Gate**: Step 6 succeeds — per-launch incremental pulls all of Mac-B's edits within `forceFullInterval` bounds (default 60 min).
- **Observability** (record but do NOT gate):
  - Median / p90 / max latency from §1 table.
  - Delivery count out of 5 attempts.
  - AppNap behavior — same metrics.
- If push delivery rate drops below 50% even on Production, document in
  `cloudkit_migration_status.md` memory and ship anyway; the data plane is
  correct without push. File p90 > 60 s as an Apple Feedback Assistant report.

---

## §2 — Cross-device credential decrypt

Reference: Plan E Task 3.2 / `docs/superpowers/plans/2026-05-02-cloudkit-keychain-sync.md` Task 26 Step 4.

- [ ] **Step 1**: Mac-A with credential sync enabled, has 2 hosts with
      passwords + 1 host with key file. Confirm via Sync settings: "3 host
      credentials synced".
- [ ] **Step 2**: Mac-B is a fresh install of the Distribution `.app`, signed
      in to user-A. Enable credential sync.
- [ ] **Step 3**: Mac-B downloads the master key from iCloud Keychain (CKKVS),
      then unwraps and writes the per-host key files to
      `~/Library/Application Support/Caterm/keys/<hostId>`. Verify the files
      exist; verify the master key item shows up in **Mac-B**'s login keychain
      under service `com.caterm.host` (Keychain Access app).
- [ ] **Step 4**: From Mac-B, connect to all 3 hosts. **None should prompt for
      password / key passphrase.**

### §2 pass criteria

- 0 prompts; SSH session establishes within ControlMaster handshake bounds.
- Failures: check the `corruptCredentials` 3-strike marker (Plan C) — if hit,
  the decrypt path is broken at the KDF / AAD layer, not the transport. Pull
  `Console.app` filtered on `com.caterm.app` / `credential-sync` for the strike
  count and the failing host id.

---

## §3 — Two-Mac settings sync

Reference: Plan E Task 3.3 / `docs/superpowers/plans/2026-05-03-cloudkit-settings-kv-manual-verification.md` (Tests 1-4) plus the broader scenarios in `docs/macos-cloudkit-settings-sync.md`.

- [ ] **Step 1 — Test 1 (basic propagation)**: On Mac-A, change a setting (e.g.
      cursor blink). On Mac-B, confirm the change appears within 30 s. Reverse
      direction.
- [ ] **Step 2 — Test 2 (offline edit reconciliation, revision LWW)**: Quit
      Mac-A. On Mac-B, change setting X. On Mac-A (still offline), change
      setting Y. Bring Mac-A online. Both should converge: X from Mac-B and Y
      from Mac-A both visible. If both edited the same field, the higher
      revision wins.
- [ ] **Step 3 — Test 3 (account switch, Y populated, force-apply)**: Sign Mac-B
      into iCloud account user-B (which has its own previously-pushed
      `caterm.settings.v1`). Confirm Mac-B's local settings get force-applied
      from user-B's KVS within 30 s.
- [ ] **Step 4 — Test 4 (account switch, Y empty, no auto-push)**: Sign Mac-B
      into a fresh iCloud account user-C with no `caterm.settings.v1`. Confirm
      Mac-B does NOT auto-push its local Z to user-C — it waits for an explicit
      user edit.
- [ ] **Step 5 — `inInitialSyncGrace` window**: After fresh sign-in, the first
      500 ms of edits suspendUntilFirstEdit, then unfreeze. Verify by changing
      settings rapidly post-sign-in; confirm the first push lands ≥500 ms after
      sign-in completion.
- [ ] **Step 6 — quarantine path**: Manually corrupt the KVS blob via a debug
      build (or `defaults write` against the KVS blob) — write `Data([0xFF])`
      to `caterm.settings.v1`. Expect Mac-B to enter `.quarantined` state and
      cease pushing. `Console.app` filter `SettingsSyncStore` should show the
      `.quarantined` transition.
- [ ] **Step 7 — `.initialSyncChange` write barrier**: Sign in to a fresh
      iCloud on Mac-B with Y populated; Mac-B should NOT push its local Z over
      Y for the duration of the grace window.
- [ ] **Step 8 — reset path**: Destructive credential delete on Mac-A
      propagates tombstone to Mac-B; Mac-B's UI shows "0 host credentials
      synced" within 30 s.

### §3 pass criteria

- 8/8 scenarios pass.
- Capture `Console.app` filtered on `SettingsSyncStore` for any unexpected
  `quarantined` / `suspendUntilFirstEdit` transitions during Steps 1-5.

---

## Sign-off

| Section | Result | Tester | Date | Notes |
|---------|--------|--------|------|-------|
| §1 (push, gate=Step 6 only) | pass / fail |  |  |  |
| §2 (credential decrypt, 4/4) | pass / fail |  |  |  |
| §3 (settings sync, 8/8) | pass / fail |  |  |  |

After all three sections sign off:

- [ ] Update `cloudkit_migration_status.md` memory with sign-off date, both
      machine identifiers (Mac model + macOS version + Caterm build commit),
      and §1 latency observations (median / p90 / max + delivery rate).
- [ ] Mark Plan E **DONE + LIVE-VERIFIED** in the same memory.
