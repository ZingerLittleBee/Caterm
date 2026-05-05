# Plan E Phase 1 — Cleanup Smoke

Run before merging the Plan E Phase 1 PR. Verifies that the legacy
`URLSessionServerSyncClient` / `AuthSession` / `ServerURL` / `SignInView`
wiring is fully gone and the surviving CloudKit-backed path is the only
sync source.

## Static checks

- [ ] **Legacy-symbol greps in `Sources/` return zero matches** (run from `apps/macos/`):

  ```bash
  for sym in \
      "URLSessionServerSyncClient" \
      ": AuthSession\\b" \
      "AuthSession(" \
      "ServerURL\\." \
      "SignInView" \
      "ORPCEnvelope" \
      "EmptyInput" \
      "parseORPCResponse" \
      "RemoteHostIdInput"; do
      count=$(grep -rEn "$sym" Sources 2>/dev/null | wc -l | tr -d ' ')
      echo "$sym: $count"
  done
  ```

  Expected: every line ends in `: 0`.

- [ ] **`import ServerSyncClient` is allowed to remain** — the module is kept as a shared types holder (`ServerSyncClient` protocol, `AuthSessionProtocol`, `RemoteHost`/`RemoteHostCreateInput`/`RemoteHostUpdateInput`/`RemoteHostCreateOutput`, `SyncErrors`, `IncrementalHostSyncClient`). Do NOT gate on this grep.

- [ ] `swift build` from `apps/macos/` exits 0.

- [ ] `swift test` from `apps/macos/` exits 0 with the post-Plan-E test count baseline (560 tests / 11 skipped / 0 failures as of cleanup commit; absolute number not load-bearing — what matters is `0 failures`).

## Runtime checks (built + signed dev binary)

- [ ] Launch Caterm. Open Preferences (⌘,) → click the **Sync** tab.
  - No "Server URL" TextField is visible.
  - No "Sign In…" / "Sign Out" buttons.
  - No email/password sheet appears under any code path.

- [ ] Sign out of iCloud in System Settings → relaunch Caterm → reopen Preferences → Sync.
  - Account section reads "Not signed in to iCloud" with a hint pointing to System Settings.
  - "Sync Now" button is disabled.

- [ ] Sign back into iCloud → relaunch Caterm.
  - Account section reads "Signed in to iCloud".
  - "Sync Now" button is enabled.
  - Hosts and settings still pull from CloudKit (verifies the surviving path is intact).

## Data integrity

- [ ] The legacy `caterm.server.baseURL` UserDefaults key from pre-Plan-E builds, if present, is NOT removed by this build. Older builds rolling back must still find their value:

  ```bash
  defaults read com.caterm.app caterm.server.baseURL 2>/dev/null
  ```

  Either prints the previously-stored URL, or `does not exist` for fresh installs. Both are acceptable. Plan E neither writes nor deletes this key.

## Sign-off

- [ ] All static checks green
- [ ] All runtime checks green
- [ ] Tester:  __________   Date:  __________
