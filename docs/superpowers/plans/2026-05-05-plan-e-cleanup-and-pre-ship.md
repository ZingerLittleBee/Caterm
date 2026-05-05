# Plan E — Server-Mode Cleanup, SFTP Bookmarks, and Pre-Ship Smoke

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the CloudKit migration. Three independent strands:

1. **Cleanup** — strip the legacy `apps/server` data path (`URLSessionServerSyncClient`, `AuthSession`, `ServerURL`, `SignInView`) now that Plans A–D are live. The wiring was kept on a coma-drip through PRs #15/#16 to limit blast radius; Plan E pulls the plug.
2. **SFTP remote-path bookmarks** — last user-facing parity gap with the web `apps/web/src/components/file-panel/dialogs/bookmark-dialog.tsx`. Per-host favorites for remote paths, stored locally; CloudKit sync deferred to a hypothetical Plan F.
3. **Pre-ship live two-Mac smoke** — bundles the verifications deferred from Plans B Phase 2 / C / D. Requires Distribution provisioning profile + CloudKit Production environment.

**Predecessors:** Plans A (PR #15), B (PR #15), C (PR #15), D (PR #16) — all merged. CloudKit data plane is in production-equivalent shape; Plan E deletes the safety-net wiring and validates the result on real hardware.

**Tech Stack:** Swift 5.10, SwiftPM, XCTest. Phase 3 introduces a Distribution-only entitlements file (`Caterm.distribution.entitlements`) with `aps-environment=production` and `icloud-container-environment=Production`; the existing `Caterm.entitlements` (Development) is unchanged. CloudKit Production environment + Distribution profile required for Phase 3 only.

---

## File structure

### Files to delete

| Path | Reason |
|------|--------|
| `apps/macos/Sources/ServerSyncClient/ServerURL.swift` | Persisted server URL is meaningless once HTTP client is gone. |
| `apps/macos/Sources/ServerSyncClient/AuthSession.swift` (the `AuthSession` concrete class only) | Email/password auth replaced by `iCloudAccountSession`. **Keep** `AuthSessionProtocol` — `iCloudAccountSession` conforms to it. |
| `apps/macos/Sources/Caterm/Views/SignInView.swift` | Email/password sign-in form. |
| `URLSessionServerSyncClient` (the concrete class inside `ServerSyncClient/ServerSyncClient.swift`) | Legacy oRPC HTTP client. **Keep** the `ServerSyncClient` protocol — `CloudKitSyncClient` conforms to it. |

### Files to modify

| File | What changes |
|------|-------------|
| `apps/macos/Sources/ServerSyncClient/ServerSyncClient.swift` | Drop the `URLSessionServerSyncClient` class; protocol stays. |
| `apps/macos/Sources/ServerSyncClient/AuthSession.swift` | Becomes a single-protocol file; rename to `AuthSessionProtocol.swift`. |
| `apps/macos/Sources/Caterm/CatermApp.swift` | Drop `let authSession: AuthSession` field, drop `ServerURL.current`, stop threading `authSession` into `SyncEnvironment`. |
| `apps/macos/Sources/Caterm/Views/SyncSettingsView.swift` | Delete server-URL TextField, delete email/password sign-in button + sheet, delete `accountState` `.sessionExpired` branch (CloudKit has no token-expired shape). |
| `apps/macos/Sources/Caterm/Views/Preferences/SyncSettingsTab.swift` | Drop `authSession` and `serverURL` parameters and the `ServerURL.set(...)` `onChange` handler. |
| `apps/macos/Sources/Caterm/Views/Preferences/PreferencesWindowController.swift` | `SyncEnvironment` no longer carries `authSession`. |
| `apps/macos/Sources/Caterm/Views/SyncStatusRow.swift` | Drop sign-in CTA; CloudKit account state comes from `iCloudAccountSession`. |
| `apps/macos/Sources/Caterm/Views/FileDrawerView.swift` | Add bookmark toolbar button + popover; wire to `RemoteBookmarkStore`. |
| `apps/macos/Tests/CatermTests/SyncSettingsAccountStateTests.swift` | Drop `.sessionExpired` cases; rewrite to use `iCloudAccountSession` mock. |
| `apps/macos/Tests/SessionStoreTests/SessionStoreMutationPublisherTests.swift` | Replace `@testable import ServerSyncClient` reliance on `URLSessionServerSyncClient` (if any) with a fake. |

### Test files to delete

The legacy `ServerSyncClient` tests fall into three buckets. Delete only what tests the deleted classes — the protocol and shared types stay.

| Path | Action | Reason |
|------|--------|--------|
| `apps/macos/Tests/ServerSyncClientTests/AuthSessionTests.swift` | **Delete** | Tests the `AuthSession` concrete class (constructor `AuthSession(...)` on line 14). Class is gone in Task 1.3. |
| `apps/macos/Tests/ServerSyncClientTests/ServerSyncClientHTTPTests.swift` | **Delete** | Tests `URLSessionServerSyncClient` HTTP behavior. Class is gone in Task 1.2. |
| `apps/macos/Tests/ServerSyncClientTests/MockURLProtocol.swift` | **Delete** | Test fixture only used by `ServerSyncClientHTTPTests.swift`. |
| `apps/macos/Tests/ServerSyncClientTests/ORPCEnvelopeTests.swift` | **Delete** | Verified `ORPCEnvelope`, `EmptyInput`, `parseORPCResponse` are only referenced by `URLSessionServerSyncClient` (the HTTP path being deleted). `CloudKitSyncClient` and `CKRecordHostMapping` do **not** use them — they encode `Host` records directly via `CKRecord` fields. Delete these tests with their subjects in Task 1.2. |
| `apps/macos/Tests/ServerSyncClientTests/RemoteHostCodableTests.swift` | **Keep** | `RemoteHost` is the wire shape used by `CKRecordHostMapping` to translate between Swift values and `CKRecord` fields; codable round-trip is still load-bearing. |

### New files

| File | Purpose |
|------|---------|
| `apps/macos/Sources/SessionStore/RemoteBookmarkStore.swift` | `@MainActor` ObservableObject; per-host JSON file at `~/Library/Application Support/Caterm/bookmarks/<hostId>.json`; CRUD + `bookmarks(for:)`. |
| `apps/macos/Tests/SessionStoreTests/RemoteBookmarkStoreTests.swift` | Round-trip persistence, ordering, dedup, missing-file = empty. |
| `apps/macos/Sources/Caterm/Views/RemoteBookmarkPopover.swift` | Popover content for FileDrawer bookmark button. |
| `apps/macos/Manual/plan-e-cleanup-smoke.md` | Pre-merge sanity for Phase 1 (no orphan symbols, login UI gone). |
| `apps/macos/Manual/pre-ship-two-mac-smoke.md` | Aggregates B Phase 2 Task 2.5 + C Task 26 Step 4 + D scenarios 1–10 into a single tester checklist. |
| `apps/macos/Resources/Caterm.distribution.entitlements` | Production variant of `Caterm.entitlements`: `aps-environment=production` + `icloud-container-environment=Production` (single-string, not array). Selected by `dev-codesign.sh --profile distribution`. |
| `apps/macos/Scripts/dist-package.sh` | Distribution analog of `dev-run-app.sh`: builds release `.app` bundle, embeds Distribution provisioning profile at `Contents/embedded.provisionprofile`, re-seals at bundle level with Distribution entitlements (per Pitfall 5). |

---

## Phase order rationale

- **Phase 1 (cleanup) first.** Compile-time deletion is the tightest test that Plans A–D really did supersede the old path. If anything still secretly depends on `URLSessionServerSyncClient` or email/password `AuthSession`, the build will refuse. Doing this before Phase 2 keeps the bookmarks feature from getting tangled in legacy plumbing.
- **Phase 2 (bookmarks)** is purely additive and untouched by anything else. Land after Phase 1 so its diff doesn't have to coexist with sweeping deletes.
- **Phase 3 (pre-ship smoke)** runs against a Distribution-signed build. It cannot start until Phases 1+2 are merged because rolling back after Distribution validation costs another notarization round-trip.

Each phase ends with `swift build` + `swift test` green and a matching `apps/macos/Manual/*.md` smoke-test pass.

---

## Phase 1 — Strip server-mode wiring

### Task 1.1: Inventory remaining references

- [ ] **Step 1: Snapshot what's currently using each legacy symbol.**

```bash
cd apps/macos
grep -rn "URLSessionServerSyncClient" Sources Tests
grep -rn "\\bAuthSession\\b" Sources Tests       # word boundary — excludes AuthSessionProtocol
grep -rn "ServerURL" Sources Tests
grep -rn "SignInView" Sources Tests
grep -rn "import ServerSyncClient" Sources Tests
```

- [ ] **Step 2: Capture the output as a comment in the PR description.** Each future task removes a line; the inventory is the truth source for "are we done?".

### Task 1.2: Drop `URLSessionServerSyncClient` and the oRPC HTTP envelope

**Files:**
- modify `apps/macos/Sources/ServerSyncClient/ServerSyncClient.swift` (delete the concrete class; keep the protocol)
- delete `apps/macos/Sources/ServerSyncClient/ORPCEnvelope.swift` (only `URLSessionServerSyncClient` uses `ORPCEnvelope` / `EmptyInput` / `parseORPCResponse`; `CloudKitSyncClient` does not — verified)
- modify `apps/macos/Sources/ServerSyncClient/RemoteHost.swift` to drop `RemoteHostIdInput` (only used by the deleted HTTP class; `CKRecordHostMapping` references the bare `RemoteHost` struct)
- delete `apps/macos/Tests/ServerSyncClientTests/{ServerSyncClientHTTPTests.swift, MockURLProtocol.swift, ORPCEnvelopeTests.swift}`

There is no compile-time "class is gone" test in SwiftPM (negative compilation can't be asserted from inside a test target). The contract here is enforced by the smoke `grep` in Task 1.8 + Phase 1 exit checklist + CI.

- [ ] **Step 1: Verify `ORPCEnvelope` / `EmptyInput` / `parseORPCResponse` / `RemoteHostIdInput` are unused outside the HTTP path.**

```bash
cd apps/macos
grep -rn "ORPCEnvelope\|EmptyInput\|parseORPCResponse\|RemoteHostIdInput" Sources Tests
```

Expected hits before edits: `ORPCEnvelope.swift` (definitions), `ServerSyncClient.swift` (the deleted HTTP class), `RemoteHost.swift` (`RemoteHostIdInput` definition only), `ORPCEnvelopeTests.swift`. Nothing in `CloudKitSyncClient/`, `HostSyncStore/`, or `Caterm/`. If any new hit appears outside this list, escalate before deleting.

- [ ] **Step 2: Delete the test files that exercise the deleted symbols.** `ServerSyncClientHTTPTests.swift` references `URLSessionServerSyncClient` directly (line 5, 12). `MockURLProtocol.swift` is its only consumer. `ORPCEnvelopeTests.swift` tests only the envelope code being deleted.

- [ ] **Step 3: Delete `URLSessionServerSyncClient` from `ServerSyncClient.swift`.** Keep the `ServerSyncClient` protocol definition. Anything downstream (`CloudKitSyncClient: ServerSyncClient`) is unaffected.

- [ ] **Step 4: Delete `ORPCEnvelope.swift` and remove `RemoteHostIdInput` from `RemoteHost.swift`.** Keep the `RemoteHost` struct itself — `CKRecordHostMapping` still uses it as the wire shape inside CloudKit `CKRecord` fields.

- [ ] **Step 5: Build.** `swift build 2>&1 | tail -20` and `swift test 2>&1 | tail -20`. Expected: green.

### Task 1.3: Drop `AuthSession` (concrete)

**Files:** rename `apps/macos/Sources/ServerSyncClient/AuthSession.swift` → `AuthSessionProtocol.swift`; delete the `AuthSession` class; delete `apps/macos/Tests/ServerSyncClientTests/AuthSessionTests.swift`.

- [ ] **Step 1: Verify all call sites use the protocol, not the class.**

```bash
grep -rn "AuthSession(" Sources Tests    # constructor calls
grep -rn ": AuthSession\\b" Sources Tests # type annotations
```

Expected hits before edits: `CatermApp.swift:58`, `SyncSettingsView.swift:54,68,179`, `SyncSettingsTab.swift:23,32`, `SignInView.swift:5`, `PreferencesWindowController.swift:17,24`, `AuthSessionTests.swift:14`. All are removed by Phase 1 tasks.

- [ ] **Step 2: Delete `AuthSessionTests.swift`.** It constructs the class directly (line 14) and tests its HTTP semantics; nothing in the new path needs that coverage.

- [ ] **Step 3: Delete the `AuthSession` class body.** The file should now contain only `AuthSessionProtocol` plus any types it depends on. Rename the file to `AuthSessionProtocol.swift`.

- [ ] **Step 4: Update `CatermApp.swift`.** Delete the `let authSession: AuthSession` stored property and the `self.authSession = AuthSession(baseURL: ServerURL.current)` line. The constructed `iCloudAccountSession` is what `HostSyncStore` already uses (`authSession: icloudSession` on line ~91).

- [ ] **Step 5: Build.** Expected failures point at `SyncSettingsView`, `SyncSettingsTab`, `PreferencesWindowController`, `SignInView` — fix in subsequent tasks.

### Task 1.4: Drop `ServerURL`

**Files:** delete `apps/macos/Sources/ServerSyncClient/ServerURL.swift`; update `SyncSettingsView.swift`, `SyncSettingsTab.swift`.

- [ ] **Step 1: Find any UserDefaults reads of the persisted server URL.**

The real key (per `apps/macos/Sources/ServerSyncClient/ServerURL.swift:7`) is `caterm.server.baseURL`.

```bash
grep -rn "ServerURL\\." Sources Tests
grep -rn "caterm\\.server\\.baseURL" Sources Tests
```

- [ ] **Step 2: Delete `ServerURL.swift`.** Strip the `serverURL` `@State` and bound TextField from `SyncSettingsTab.swift`. Remove the "Restart Caterm after changing the server URL." hint from `SyncSettingsView.swift`.

- [ ] **Step 3: Stop reading the persisted UserDefaults key.** If `ServerURL.set` wrote to UserDefaults under `caterm.server.baseURL`, leave the stale data alone; it's harmless. **Do not** add a migration that wipes it — users may roll back to a pre-Plan-E build temporarily.

### Task 1.5: Delete `SignInView` and the sign-in code path in `SyncSettingsView`

- [ ] **Step 1: Delete `apps/macos/Sources/Caterm/Views/SignInView.swift`.**

- [ ] **Step 2: In `SyncSettingsView.swift`:**
  - Drop `@State private var showSignIn`.
  - Drop the `.sheet(isPresented: $showSignIn) { SignInView(...) }` modifier.
  - Drop the `accountState` `.sessionExpired` case + its UI branch.
  - Replace `accountState(isSignedIn:lastSyncError:lastSyncErrorKind:)` callers with the iCloud account-state derivation. The new `AccountState` is binary: `.signedIn` / `.signedOut`. Source: `iCloudAccountSession.isSignedIn`.

- [ ] **Step 3: In `SyncStatusRow.swift`:** the existing "click to open sync settings" notification continues to work; only its destination view changed (the destination still exists, just minus the sign-in form).

- [ ] **Step 4: Update `Tests/CatermTests/SyncSettingsAccountStateTests.swift`** to test the binary derivation. Delete the `.sessionExpired` test cases.

### Task 1.6: Update `PreferencesWindowController.SyncEnvironment`

- [ ] **Step 1: Drop `authSession: AuthSession` from `SyncEnvironment`.** Update both call sites in `CatermApp.swift` (`.catermOpenSyncSettings` notification handler and the ⌘, button).

- [ ] **Step 2: Build clean.** `swift build 2>&1 | tail -5` should succeed; `swift test 2>&1 | tail -10` should remain green.

### Task 1.7 (optional, recommended): Rename module `ServerSyncClient` → `SyncTypes`

The module name is now a misnomer (it holds shared protocols + DTOs, no server client). **All-or-nothing for this PR**: either complete the rename or skip the task entirely. Do not leave TODO breadcrumbs in code — track follow-up in a GitHub issue if deferred.

- [ ] **Step 1:** Rename `Sources/ServerSyncClient/` → `Sources/SyncTypes/`, update `Package.swift`, find/replace `import ServerSyncClient` → `import SyncTypes` across `Sources/` and `Tests/`. Same for `Tests/ServerSyncClientTests/` → `Tests/SyncTypesTests/`.
- [ ] **Step 2:** `swift build && swift test`.
- [ ] **Step 3:** If the rename diff would balloon the PR past review-ability (>20 files touched outside the actual cleanup), **skip and open a follow-up issue** titled "Rename ServerSyncClient module to SyncTypes". Do not add `// TODO` comments to the code.

### Task 1.8: Phase 1 smoke

- [ ] **Step 1: Author `apps/macos/Manual/plan-e-cleanup-smoke.md`** containing:
  - `swift build` clean
  - `swift test` green (count parity with pre-Plan-E baseline minus removed test files)
  - `grep -rn "URLSessionServerSyncClient\|SignInView\|: AuthSession\\b\|ServerURL\\." apps/macos/Sources` returns nothing
  - Launch app: ⌘, → Sync tab → no email/password fields visible, no server URL field visible, account state derives from iCloud
  - Sign out of iCloud in System Settings → relaunch → Sync tab shows "Not signed in to iCloud" copy (no email form)

- [ ] **Step 2: Run smoke. Mark all checkboxes in the smoke file.**

---

## Phase 2 — SFTP remote-path bookmarks

### Task 2.1: `RemoteBookmarkStore` data layer

**Files:** new `apps/macos/Sources/SessionStore/RemoteBookmarkStore.swift`, new `apps/macos/Tests/SessionStoreTests/RemoteBookmarkStoreTests.swift`.

- [ ] **Step 1: Spec the data model.**

```swift
public struct RemoteBookmark: Codable, Equatable, Identifiable {
    public let id: UUID
    public var label: String      // user-visible name; defaults to last path component
    public var path: String       // e.g. "/var/log" or "~/projects"
    public var createdAt: Date
}
```

Storage: one JSON file per host at `~/Library/Application Support/Caterm/bookmarks/<hostId>.json`. JSON top-level: `{ "version": 1, "bookmarks": [...] }`. Versioned for forward-compat; reader treats unknown `version` as **read-only quarantine**, NOT a recoverable empty: in-memory bookmarks list is empty, the FileDrawer disables the Add button with tooltip "Bookmarks file is from a newer build — refusing to overwrite", and `save()` is a no-op until the file is removed/renamed by the user. This prevents a downgraded build from clobbering a newer-schema bookmarks file with empty content. (Mirrors the schema-newer-cloud quarantine pattern from Plan D `SettingsSyncStore`.)

- [ ] **Step 2: Spec the dedup / normalization rule.** Bookmarks are **remote** SFTP paths, not local filesystem paths. Foundation helpers like `(path as NSString).standardizingPath` and `expandingTildeInPath` resolve `~` against the **local** macOS user (`/Users/zingerbee`) — verified: `("~" as NSString).standardizingPath` → `/Users/zingerbee`. Using them here would corrupt remote-relative paths.

  Define a **lexical-only** normalizer for dedup keys (no I/O, no tilde expansion):

  ```swift
  /// Lexically normalizes a remote SFTP path for dedup comparison.
  /// Preserves `~`, `~user`, relative paths — these resolve on the remote
  /// at use time, not locally. Only collapses runs of `/` and removes a
  /// trailing `/` (except for root "/").
  func normalizeRemotePath(_ raw: String) -> String {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { return trimmed }
      // Collapse "//" → "/" without crossing the "~/" or absolute-root boundary
      // semantically (lexical only — we are not resolving symlinks).
      var out = ""
      var prevSlash = false
      for ch in trimmed {
          if ch == "/" {
              if prevSlash { continue }
              prevSlash = true
          } else {
              prevSlash = false
          }
          out.append(ch)
      }
      // Trim trailing "/" except for the root path itself.
      if out.count > 1, out.hasSuffix("/") { out.removeLast() }
      return out
  }
  ```

  The stored `path` field is the user's literal input (so `~`, `~/projects`, `/var/log` all round-trip exactly as typed). Dedup compares `normalizeRemotePath(stored) == normalizeRemotePath(input)`.

- [ ] **Step 3: Write failing tests.** `RemoteBookmarkStoreTests` covers:
  - Empty state: `bookmarks(for: hostId)` returns `[]` when file missing.
  - Add/list round-trip: `add(_:for:)` then `bookmarks(for:)` returns the inserted entry; stored `path` equals input verbatim (no tilde expansion).
  - Delete: `remove(id:for:)` removes the matching entry.
  - Reorder: `move(from:to:for:)` preserves order across reload.
  - Dedup keeps `~` literal: adding `"~"` then `"~"` is a no-op and returns `false`; the stored value remains `"~"`, NOT `/Users/...`.
  - Dedup is lexical-only: `"~/projects"` and `"~//projects"` collide; `"/var/log"` and `"/var/log/"` collide; `"~/projects"` and `"/Users/foo/projects"` do **not** collide (we don't resolve `~` against any user).
  - Corruption: garbage JSON → recovery to empty list, original quarantined to `<hostId>.json.broken-<timestamp>` (mirrors `SettingsStore` recovery shape).
  - Unknown version (e.g. `version: 2` from a future build): in-memory list is empty, `isQuarantined(for:) == true`, `save(...)` is a no-op (file on disk unchanged), `add(...)` returns `false`. After the user manually moves the file aside, next `add(...)` succeeds with `version: 1`.
  - Per-host isolation: bookmarks for host A do not appear under host B.

- [ ] **Step 4: Implement `RemoteBookmarkStore`** as `@MainActor final class RemoteBookmarkStore: ObservableObject`. Persist debounced (200 ms) so rapid edits don't thrash disk.

- [ ] **Step 5: `swift test --filter RemoteBookmarkStoreTests` green.**

### Task 2.2: Wire `RemoteBookmarkStore` into the app

- [ ] **Step 1: Add a `@StateObject var bookmarkStore: RemoteBookmarkStore` to `CatermApp`.** Inject via `.environmentObject(bookmarkStore)`.

- [ ] **Step 2: Confirm no isolation issues.** `RemoteBookmarkStore` runs on `@MainActor`; the only call sites are SwiftUI views, which are themselves main-actor-isolated.

### Task 2.3: Bookmark popover UI

**Files:** new `apps/macos/Sources/Caterm/Views/RemoteBookmarkPopover.swift`; modify `FileDrawerView.swift`.

- [ ] **Step 1: Add a bookmark toolbar button to `FileDrawerView`.** Place it between the existing breadcrumb path label and the `mkdir`/refresh buttons. Icon: `bookmark`.

- [ ] **Step 2: Build the popover.** Layout:
  ```
  [ + Add current path ]   ← button; saves activeHost.id + current `path`
  ─────────────
  ScrollArea {
    foreach bookmark {
      Row: [bookmark icon] [label]                    [trash icon]
      onTap: navigate FileDrawer to bookmark.path
    }
  }
  ```
  Empty state: `ContentUnavailableView("No bookmarks", systemImage: "bookmark.slash", description: "Click + to save the current folder.")`.

- [ ] **Step 3: Wire navigation.** Tapping a bookmark sets `path = bookmark.path` and triggers `refresh()`.

- [ ] **Step 4: Add inline rename.** Long-press or right-click row → text field for `label`. Submit on Enter. Esc cancels.

- [ ] **Step 5: Manual smoke.** Add 3 bookmarks for Host A, switch to Host B, confirm Host A's bookmarks are not visible. Switch back, confirm A's bookmarks survive app relaunch.

### Task 2.4: Bookmark UX polish

- [ ] **Step 1: Disable Add button when bookmark for this exact path already exists.** Compare via `normalizeRemotePath` (Task 2.1 Step 2). Tooltip: "Already bookmarked".

- [ ] **Step 2: Remote-side tilde resolution.** Stored paths are kept literal (`~`, `~/projects`, etc.). Navigation passes the UI path to `RemoteFileSystem`; `RemoteFileSystem` calls `SFTPCommandBuilder.invocation`, which encodes the path via `SFTPPathEncoder.encodeRemote` (`apps/macos/Sources/SFTPCommandBuilder/SFTPPathEncoder.swift:37`). That encoder, NOT the remote shell, handles tilde:
  - `~` → `"."` (sftp's initial cwd is always `$HOME`)
  - `~/foo` → `"foo"` (strips the `~/` prefix; relative path resolves against `$HOME`)
  - other paths pass through with shell-quoting only

  This is the existing behavior for FileDrawer navigation (`path = "~"` works today). Bookmarks inherit it for free — they store user-typed strings and let the existing encoder do the right thing. Local Foundation tilde-expansion (`expandingTildeInPath`, `standardizingPath`) is **never** called on bookmark paths.

- [ ] **Step 3: Update `apps/macos/Manual/sftp-smoke.md`** with new test cases for bookmark add / navigate / delete / cross-host isolation, plus a "remote `~` survives bookmark round-trip" case (verifies stored `path` is `~` not `/Users/...`). Extend tests #1–#15; add #16–#20.

---

## Phase 3 — Pre-ship live two-Mac smoke

**Prerequisites for the entire phase:**

1. CloudKit container `iCloud.com.caterm.app` Production schema deployed (CK Dashboard → "Deploy to Production" — schema must include `Host` record type queryable on `recordName`, plus the credential blob fields from Plan C). Plan D settings sync travels through `NSUbiquitousKeyValueStore` (`caterm.settings.v1`) which has no CloudKit Dashboard schema — it is provisioned automatically per-account by iCloud KVS and verified at runtime in Task 3.3.
2. Mac App Distribution / Developer ID Application certificate + a **Distribution provisioning profile** issued for the bundle id, with `aps-environment=production` and `com.apple.developer.icloud-container-environment=Production` enabled in the App ID configuration on the Apple developer portal. Per `docs/macos-dev-signing.md` Pitfalls 6/8/9.
3. Two physical Macs (Mac-A, Mac-B), both signed in to the same iCloud account "user-A". A spare iCloud account "user-B" for cross-identity tests.
4. A Distribution-signed `Caterm.app` bundle on both Macs (built per Task 3.0 below).

### Task 3.0: Production signing + bundling pipeline

The current `apps/macos/Resources/Caterm.entitlements:5` hardcodes `com.apple.developer.aps-environment=development` and **does not** declare `com.apple.developer.icloud-container-environment` at all. Per Apple's CKContainer documentation, CloudKit env is selected by the `com.apple.developer.icloud-container-environment` entitlement value; APS env is selected by `com.apple.developer.aps-environment` and the embedded provisioning profile. Neither is "automatic" — both must be present and matching, or AMFI rejects the binary at launch.

The repo's signing pipeline today is **two-stage**:

- `apps/macos/Scripts/dev-codesign.sh` signs the raw `.build/debug/{caterm,caterm-askpass}` binaries (substitutes `$(TeamIdentifierPrefix)` in entitlements, codesigns each binary).
- `apps/macos/Scripts/dev-run-app.sh` assembles a minimal `.app` shell around those signed binaries, copies in the Mac App Development provisioning profile at `Contents/embedded.provisionprofile`, then re-seals at the bundle level (per `docs/macos-dev-signing.md` Pitfall 5: outer codesign must re-pass `--entitlements`, otherwise the main executable gets re-signed with empty entitlements and CKContainer crashes at init).

Plan E adds a **third script** for the release path that mirrors `dev-run-app.sh` but uses Distribution identity, the Production profile, and the new Distribution entitlements — without touching the existing dev pipeline.

**Files:**
- new `apps/macos/Resources/Caterm.distribution.entitlements`
- modify `apps/macos/Scripts/dev-codesign.sh` (add `--profile dev|distribution` flag — selects entitlements + identity for **inner-binary** signing only)
- new `apps/macos/Scripts/dist-package.sh` (Distribution analog of `dev-run-app.sh`: builds release config, assembles `.app` bundle, embeds Distribution profile, re-seals at bundle level with the Distribution entitlements)
- modify `apps/macos/Makefile` (new `make dist` target that runs `swift build -c release` → `dev-codesign.sh --profile distribution` → `dist-package.sh`)
- modify `docs/macos-dev-signing.md` (add Distribution recipe + verification step)

- [ ] **Step 1: Author `Caterm.distribution.entitlements`.** This is the entitlements file for the **main app binary only**. Copy from `Caterm.entitlements` and change two keys, add one. Use the single-string form for `icloud-container-environment` here:

  ```xml
  <!-- changed -->
  <key>com.apple.developer.aps-environment</key>
  <string>production</string>

  <!-- added -->
  <key>com.apple.developer.icloud-container-environment</key>
  <string>Production</string>
  ```

  Keep `keychain-access-groups` and `com.apple.developer.icloud-services` + `icloud-container-identifiers` identical.

  **Why single-string here:** for this app's signed-binary entitlements file, use the single-string form. Do not use the array shape — that form appears in some Apple provisioning-profile contexts but causes mismatches when applied to a binary's own entitlements. The repo's existing `docs/macos-dev-signing.md:69` uses the same single-string convention; stay consistent.

  **Do NOT modify `Resources/CatermAskpass.entitlements`.** The askpass helper is `exec`'d by `/usr/bin/ssh` as a plain nested binary; per `dev-codesign.sh:112-118` and `Manual/end-to-end-smoke.md`, restricted app/team identity entitlements (APS, CloudKit, application-identifier) cause AMFI to SIGKILL it before `main()` runs. CatermAskpass's entitlements file already has only `keychain-access-groups` — that is correct for both dev and distribution. Plan E does not touch it.

- [ ] **Step 2: Extend `Scripts/dev-codesign.sh`** to accept `--profile dev|distribution` (default: `dev`). When `distribution`:
  - require env `CATERM_DIST_IDENTITY` (Developer ID Application or Mac App Distribution cert SHA-1 / CN)
  - sign **release-config** binaries from `.build/release/{caterm,caterm-askpass}`, NOT `.build/debug/...`
  - codesign with `--options runtime` (hardened runtime is required for notarization)
  - **Two different entitlements files for the two binaries:**
    - `caterm` (main app) → substituted `Resources/Caterm.distribution.entitlements`
    - `caterm-askpass` (helper) → substituted `Resources/CatermAskpass.entitlements` (keychain access group only — same file used in dev mode; askpass entitlements are environment-agnostic)
  - **Persist both substituted files** to `.build/release/` so `dist-package.sh` can re-use the exact same bytes when re-sealing (mirrors the dev path at `dev-codesign.sh:137` which writes `.build/debug/Caterm.dev.entitlements`):
    - `.build/release/Caterm.distribution.entitlements` (post-substitution; for outer bundle re-sign)
    - `.build/release/CatermAskpass.distribution.entitlements` (post-substitution; for any nested re-sign of the helper)

  **Do NOT embed the provisioning profile here** — that belongs in the bundle assembly step (Step 3). Inner-binary signing only handles the binaries themselves.

- [ ] **Step 3: Author `Scripts/dist-package.sh`** — Distribution analog of `dev-run-app.sh`:
  - precondition: Step 2 has already signed `.build/release/{caterm,caterm-askpass}` and emitted the substituted entitlements files at `.build/release/Caterm.distribution.entitlements` + `.build/release/CatermAskpass.distribution.entitlements`. Hard-fail if either file is missing — do not re-substitute on the fly.
  - require env `CATERM_DIST_IDENTITY` + `CATERM_DIST_PROFILE_PATH` (path to `.provisionprofile` from Apple developer portal, with `aps-environment=production` and `icloud-container-environment=Production` enabled in the App ID config)
  - assemble `.build/release/Caterm.app` with `Contents/{Info.plist, MacOS/caterm, MacOS/caterm-askpass, embedded.provisionprofile}`
  - copy `$CATERM_DIST_PROFILE_PATH` → `Caterm.app/Contents/embedded.provisionprofile`
  - **Re-seal in two passes** (NOT one outer-only pass — that strips the helper's own entitlements just as Pitfall 5 strips the main exe's):
    1. `codesign --force --sign "$CATERM_DIST_IDENTITY" --entitlements .build/release/CatermAskpass.distribution.entitlements --options runtime Caterm.app/Contents/MacOS/caterm-askpass`
    2. `codesign --force --sign "$CATERM_DIST_IDENTITY" --entitlements .build/release/Caterm.distribution.entitlements --options runtime Caterm.app`
  - DO NOT call `open` — Distribution builds are for the test Macs, not local launch

- [ ] **Step 4: Add `make dist` Makefile target:**

  ```makefile
  .PHONY: dist
  dist:
  	swift build -c release
  	./Scripts/dev-codesign.sh --profile distribution
  	./Scripts/dist-package.sh
  ```

- [ ] **Step 5: Verify each signed component independently.** Three checks — bundle, main binary, askpass helper:

  Use `set -e` so any failed assertion aborts the verification:

  ```bash
  set -e

  BUNDLE=.build/release/Caterm.app
  MAIN=$BUNDLE/Contents/MacOS/caterm
  HELPER=$BUNDLE/Contents/MacOS/caterm-askpass

  bundle_ents=$(codesign -d --entitlements - "$BUNDLE" 2>&1)
  main_ents=$(codesign -d --entitlements - "$MAIN" 2>&1)
  helper_ents=$(codesign -d --entitlements - "$HELPER" 2>&1)

  # Bundle + main binary: expect production APS + Production CK env (positive checks).
  echo "$bundle_ents" | grep -q "<string>production</string>"
  echo "$bundle_ents" | grep -q "<string>Production</string>"
  echo "$main_ents"   | grep -q "<string>production</string>"
  echo "$main_ents"   | grep -q "<string>Production</string>"

  # Askpass: keychain-access-groups MUST be present.
  echo "$helper_ents" | grep -q "keychain-access-groups"

  # Askpass: app/team identity entitlements MUST NOT leak in.
  # AMFI SIGKILLs the helper at exec if any of these appear.
  ! echo "$helper_ents" | grep -Eq \
      "aps-environment|icloud-container-environment|application-identifier|com\.apple\.developer\.team-identifier"
  ```

  Expected:
  - Bundle + main binary: `<string>production</string>` for APS, `<string>Production</string>` for CloudKit env.
  - Askpass: `keychain-access-groups` present; no `aps-environment`, no `icloud-container-environment`, no `application-identifier`, no `com.apple.developer.team-identifier`.

  Any failed assertion aborts the script; Phase 3 is invalid. Re-sign and re-verify before proceeding. **Note:** `dev-codesign.sh:118-122` already strips `application-identifier` and `team-identifier` from the helper in dev mode via `PlistBuddy Delete`; the new distribution path must do the same — the assertions above are the safety net.

- [ ] **Step 6: Verify CloudKit env at runtime.** Add a one-line `os_log` at app launch that prints the resolved CloudKit env: read the `com.apple.developer.icloud-container-environment` value back from the running process via `SecCodeCopySigningInformation`. Confirm `"Production"` appears in `Console.app` filtered on the bundle id at launch. This is verification-only code; it can stay in the binary post-Phase-3 as cheap diagnostics.

- [ ] **Step 7: Update `docs/macos-dev-signing.md`** with the Distribution recipe: the new `make dist` flow, the three-way codesign verification commands from Step 5 (bundle + main binary + askpass helper), the rule that askpass entitlements stay limited to `keychain-access-groups` in both dev and distribution, and a note that this app's entitlements files use the single-string form for `icloud-container-environment` — do not use the array shape on the binary's own entitlements (it appears in some provisioning-profile contexts but mismatches when applied to a binary).

### Task 3.1: B Phase 2 Task 2.5 — silent push live delivery (observability, not gate)

Reference: `docs/superpowers/plans/2026-05-02-cloudkit-push-subscriptions.md` Task 2.5.

Per Apple's `CKQueryNotification` documentation, silent push (`content-available: 1`) is delivered best-effort: the system MAY coalesce, drop, or delay individual notifications. **This task observes push behavior; it is NOT a hard pass/fail gate.** The load-bearing sync triggers per `cloudkit_migration_status.md` are: 60-min forceFull, per-launch incremental, iCloud-account-change observers. Push is acceleration on top.

Both Macs run Caterm in the foreground throughout. We deliberately put the writer on Mac-B (the device whose UI we're driving) and the reader on Mac-A — the same machine cannot be both source and destination of a CloudKit silent push.

- [ ] **Step 1: Mac-A Caterm running, foreground.** Mac-B Caterm running, foreground.
- [ ] **Step 2: On Mac-B, modify Host X's port via the host edit sheet.** Wait for the local push to complete — `Console.app` filtered on `CloudKitSyncClient` should show a successful save record op.
- [ ] **Step 3: Observe Mac-A.** `AppDelegate.application(_:didReceiveRemoteNotification:)` (the AppKit two-arg form per `apps/macos/Sources/Caterm/AppDelegate.swift:62`, NOT the iOS `fetchCompletionHandler:` shape) logs the push, `parsePushUserInfo` dispatches, and the host list reflects the change. **Record the latency** from Mac-B save-success to Mac-A UI update.
- [ ] **Step 4: Repeat 5 times** with different fields (port, label, username). Record each latency. Some MAY exceed 60 s or never arrive — that is acceptable per Apple semantics.
- [ ] **Step 5: Repeat with Mac-A AppNapped** (foreground but demoted: Activity Monitor shows "App Nap: Yes"). Record same metrics.
- [ ] **Step 6: Verify the fallback path actually fires.** Quit Mac-A Caterm; reopen it; confirm the per-launch incremental sync pulls Mac-B's edits regardless of whether push delivered. **This is the gate** — push delivery is not.

**Pass criteria (gate):** Step 6 succeeds — per-launch incremental pulls all of Mac-B's edits within `forceFullInterval` bounds.

**Observability (record but do NOT gate):**
- Step 3 + 4 latency distribution (median / p90 / max). File any p90 > 60 s as an Apple Feedback Assistant report.
- Step 4 delivery count out of 5 attempts.
- Step 5 AppNap behavior — same metrics.

If push delivery rate drops below 50% even on Production, document in `cloudkit_migration_status.md` and ship; the data plane is correct without push.

### Task 3.2: C Task 26 Step 4 — cross-device credential decrypt

Reference: `docs/superpowers/plans/2026-05-02-cloudkit-keychain-sync.md` Task 26 Step 4.

- [ ] **Step 1: Mac-A with credential sync enabled, has 2 hosts with passwords + 1 host with key file.** Confirm via Sync settings: "3 host credentials synced".
- [ ] **Step 2: Mac-B, fresh install of Caterm, signed in to user-A.** Enable credential sync.
- [ ] **Step 3: Mac-B downloads master key from iCloud Keychain (CKKVS), then unwraps and writes the key file to `~/Library/Application Support/Caterm/keys/<hostId>`.**
- [ ] **Step 4: From Mac-B, connect to all 3 hosts. None should prompt for password / key passphrase.**

Pass criteria: 0 prompts; SSH session establishes within ControlMaster handshake bounds. Failures: check `corruptCredentials` 3-strike marker (Plan C) — if hit, the decrypt path is broken at the KDF / AAD layer, not the transport.

### Task 3.3: D scenarios 1–10 — two-Mac settings sync

Reference: `docs/superpowers/plans/2026-05-03-cloudkit-settings-kv-manual-verification.md` (Tests 1–4) **plus** the broader scenarios in `docs/macos-cloudkit-settings-sync.md`.

- [ ] **Step 1: Run Test 1 (basic propagation).**
- [ ] **Step 2: Run Test 2 (offline edit reconciliation, revision LWW).**
- [ ] **Step 3: Run Test 3 (account switch, Y populated, force-apply).**
- [ ] **Step 4: Run Test 4 (account switch, Y empty, no auto-push).**
- [ ] **Step 5: Verify `inInitialSyncGrace` window during fresh install** — after sign-in, first 500 ms of edits suspendUntilFirstEdit, then unfreeze.
- [ ] **Step 6: Verify quarantine path** — manually corrupt the KVS blob via a debug build that writes `Data([0xFF])` to `caterm.settings.v1`; expect Mac-B to enter `.quarantined` state and cease pushing.
- [ ] **Step 7: Verify `.initialSyncChange` write barrier** — sign in to a fresh iCloud on Mac-B with Y populated; Mac-B should NOT push its local Z over Y for the duration of the grace window.
- [ ] **Step 8: Verify reset path** — destructive credential delete on Mac-A propagates tombstone to Mac-B; Mac-B's UI shows "0 host credentials synced" within 30 s.

Pass criteria: 8/8 scenarios pass. Capture `Console.app` filtered on `SettingsSyncStore` for any unexpected `quarantined` / `suspendUntilFirstEdit` transitions.

### Task 3.4: Aggregate sign-off doc

- [ ] **Step 1: Author `apps/macos/Manual/pre-ship-two-mac-smoke.md`** consolidating Tasks 3.1 + 3.2 + 3.3 into a single tester checklist with sign-off table:

```
| Task   | Result | Tester | Date     | Notes                |
|--------|--------|--------|----------|----------------------|
| 3.1    |        |        |          |                      |
| 3.2    |        |        |          |                      |
| 3.3    |        |        |          |                      |
```

- [ ] **Step 2: Tester runs the doc end-to-end.** Both Macs must show all-green before merge.

- [ ] **Step 3: Update `cloudkit_migration_status.md` memory** with sign-off date and test machine identifiers (Mac model + macOS version + Caterm build commit).

---

## Risk + rollback

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Phase 1 deletes a symbol still referenced by production code | Low — Plans A–D have been live in `main` for 2 days; CloudKit path is exercised by every launch | Inventory in Task 1.1 catches it; CI build + test gates each task |
| Phase 2 bookmark file corruption breaks the FileDrawer | Low | Recovery-to-empty mirror of `SettingsStore`; failing test in Task 2.1 Step 2 |
| Phase 3 silent push still drops on Production | Expected — Apple's `CKQueryNotification` docs explicitly say push may be coalesced or dropped | Task 3.1 already treats push as observability not a gate. The actual gate is Step 6 (per-launch incremental fallback). Document p90/max latency in the sign-off doc; ship regardless of push delivery rate. |
| Phase 3 Distribution signing wrong env at runtime | Medium — APS env, CK env, and bundle profile must all match | Task 3.0 Step 5 (three-way `codesign -d --entitlements -` on bundle + main binary + askpass) and Step 6 (runtime `os_log` from `SecCodeCopySigningInformation`) verify both the static entitlements and the runtime CloudKit env before any test runs. If verification fails, smoke is invalid — re-sign and re-verify before proceeding. |
| Phase 3 Distribution signing breaks something dev signing didn't | Medium | Phase 3 is gated behind Task 3.0's `--profile distribution` rebuild; if smoke fails on Distribution but passes on dev, the rollback is "ship under dev signing for internal beta" — defer Distribution to post-launch. |

**Rollback plan for Phase 1:** revert the cleanup PR. The legacy `URLSessionServerSyncClient` / `AuthSession` / `SignInView` are kept on a feature branch (`feature/plan-e-cleanup`); if production users hit issues with the new CloudKit-only path, point them to a hotfix build that brings the old wiring back temporarily. **This is unlikely to be needed** because the wiring has been dormant since Plan A.

---

## Phase exit checklists

**Phase 1 done when:**
- Legacy-symbol greps in `apps/macos/Sources/` return zero:
  - `URLSessionServerSyncClient`
  - `: AuthSession\b` (the concrete-class type annotation; protocol is `AuthSessionProtocol`)
  - `AuthSession(` (constructor calls)
  - `ServerURL\.` (the deleted enum's static members)
  - `SignInView`
  - `ORPCEnvelope` (Task 1.2 deleted the file)
  - `EmptyInput` (defined in the deleted `ORPCEnvelope.swift`)
  - `parseORPCResponse` (defined in the deleted `ORPCEnvelope.swift`)
  - `RemoteHostIdInput` (Task 1.2 stripped this from `RemoteHost.swift`)
- `import ServerSyncClient` is **expected** to remain (the module is kept as a shared types holder; only its concrete classes were deleted) — do not gate on this
- `swift build && swift test` green
- `apps/macos/Manual/plan-e-cleanup-smoke.md` all checkboxes green

**Phase 2 done when:**
- `RemoteBookmarkStoreTests` green
- Bookmark popover smoke #16–#20 in `apps/macos/Manual/sftp-smoke.md` green (matches Task 2.4 Step 3)
- Per-host bookmark file in `~/Library/Application Support/Caterm/bookmarks/<uuid>.json` after first save

**Phase 3 done when:**
- Task 3.0 Step 5 (`codesign -d --entitlements -` on bundle + main binary + askpass) proves the bundle is signed against `aps-environment=production` and `icloud-container-environment=Production`, with the helper carrying only `keychain-access-groups`. Task 3.0 Step 6 (runtime `os_log` from `SecCodeCopySigningInformation`) proves the running process resolves to the Production CloudKit env entitlement at launch. End-to-end "CloudKit is actually hitting the Production container" is proven by the live smoke runs in Tasks 3.1–3.3 (records appear in the Production CK Dashboard, not Development).
- `apps/macos/Manual/pre-ship-two-mac-smoke.md` Tasks 3.1 (gate: Step 6 only — push observability is recorded but not gated) + 3.2 (all 4 steps) + 3.3 (all 8 scenarios) signed off.
- Memory `cloudkit_migration_status.md` updated to **Plan E DONE + LIVE-VERIFIED**, with Task 3.1 push delivery observations attached.

---

## Out of scope (defer to Plan F or beyond)

- CloudKit-syncing of remote bookmarks (Plan E stores them locally only).
- macOS App Sandbox + security-scoped bookmarks for local upload sources. The current binary is not sandboxed; that's a separate notarization-track effort.
- Deletion of `apps/server` from the monorepo. The web app `apps/web` may still depend on it; coordinate with Web track before removing.
- TODO at `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift:74` (`os.Logger` for skipped records). Tag for cleanup; not a Plan E blocker.
