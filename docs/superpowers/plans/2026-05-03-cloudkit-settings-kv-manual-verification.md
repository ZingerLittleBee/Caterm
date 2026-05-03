# Plan D — Manual Real-Device Verification

Run this list before declaring Plan D done. All steps require a Caterm
build with Plan D merged.

## Prerequisites

- Two Macs (Mac-A, Mac-B), both:
  - signed in to the same iCloud account "user-A" initially
  - have Caterm installed at the same Plan D build
- A spare iCloud account "user-B" available for the account-switch tests
  (Mac-B will sign out of A and sign in to B mid-test).

## Test 1 — Basic propagation (same-identity)

- [ ] On Mac-A: open Preferences, change Font Size from 13 → 18.
- [ ] On Mac-B: within 30 seconds, observe Font Size flip to 18 in
      Preferences (or via xterm restart if live reload is partial).

Expected: PASS. If propagation takes > 60s, capture
`Console.app` filtered on `SettingsSyncStore` and attach to a follow-up
issue.

## Test 2 — Offline edit reconciliation

- [ ] On Mac-B: turn off Wi-Fi.
- [ ] On Mac-A: change Theme to "Solarized Dark".
- [ ] On Mac-B (still offline): change Theme to "Tokyo Night".
- [ ] On Mac-B: turn Wi-Fi back on.
- [ ] Observe: revision LWW picks the newer-revision device. Both Macs
      converge to the same theme within 60 seconds.

Expected: PASS. The other device's theme silently loses; this is
documented in `docs/macos-cloudkit-settings-sync.md#known-limitations`.

## Test 3 — Account switch, Y populated

- [ ] On Mac-A (still user-A): set Font Size to 19 (any unique value).
- [ ] Wait 30s for KVS upload.
- [ ] On Mac-B: sign out of user-A's iCloud, sign in to user-B's iCloud.
- [ ] Pre-stage Mac-B's KVS Y by signing in to user-B on a third device
      (or another account where you've set Font Size to 25). Wait for
      that to upload.
- [ ] Restart Caterm on Mac-B.
- [ ] Observe: Font Size on Mac-B becomes 25 (force-apply of Y), NOT
      19 (which would be cross-identity LWW).

Expected: PASS.

## Test 4 — Account switch, Y empty

- [ ] On Mac-B: sign in to a brand-new iCloud account that has never
      run Caterm.
- [ ] Restart Caterm. Observe: Font Size stays at whatever it was
      before the switch — Mac-B did NOT push local data into the new
      identity.
- [ ] Open Preferences and edit Font Size.
- [ ] Wait 30s. Sign in to a third device with the same new iCloud
      account. Observe: Font Size on the third device matches Mac-B's
      edit.

Expected: PASS. The first edit under the new identity is what pushes
data; quitting before any edit leaves Y empty.

## Test 5 — Schema reject (synthetic, only if schema bump in flight)

Skip unless someone has staged a v3 blob in KVS.

## Sign-off

- [ ] All 4 tests passed
- [ ] Console logs reviewed for unexpected `[SettingsSyncStore]` lines
- [ ] CloudKit Dashboard inspected: `caterm.settings.v1` key contains
      a recent blob

Sign-off date: ____________  Tester: ____________
