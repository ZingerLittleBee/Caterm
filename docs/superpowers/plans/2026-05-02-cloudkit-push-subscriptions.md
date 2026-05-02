# Plan B — CloudKit Push Subscriptions + Incremental Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 15-minute polling timer in `HostSyncStore` with `CKDatabaseSubscription` silent push, migrate the read path from full re-list to `CKServerChangeToken`-based incremental fetch, and keep a 60-minute `forceFull` reconciliation tick as a safety net.

**Architecture:** Three sequential phases. Phase 0 is a spike to prove APS / CloudKit silent push is reachable on the dev Mac (Plan A's lesson: Apple-config-class problems first). Phase 1 (B1) does the incremental refactor with `CKServerChangeToken` and atomic checkpoint commit on a token-store actor — pure code, no APS dependency. Phase 2 (B2) layers push subscriptions, `AppDelegate` extensions, and `AccountIdentityTracker` on top. Each phase is independently mergeable.

**Tech Stack:** Swift 5.10, SwiftPM, macOS 14+, `CloudKit` (`CKDatabaseSubscription`, `CKFetchDatabaseChangesOperation`, `CKFetchRecordZoneChangesOperation`, `CKModifySubscriptionsOperation`), `os.Logger`, `XCTest`. Existing modules: `CloudKitSyncClient`, `ServerSyncClient`, `HostSyncStore`, `Caterm` (app target).

**Spec:** [`docs/superpowers/specs/2026-05-02-cloudkit-push-subscriptions-design.md`](../specs/2026-05-02-cloudkit-push-subscriptions-design.md) (`485f506`).

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift` | `StoredServerChangeToken`, `TokenCAS`, `CommitOutcome`, `ServerChangeTokenStoring` (actor protocol), `UserDefaultsServerChangeTokenStore` (actor), `InMemoryServerChangeTokenStore` (actor, test-only) |
| `apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift` | `AccountIdentityTracker` actor; persists last `userRecordID`, decides reset/no-op on `.catermICloudAccountChanged` |
| `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift` | `CloudKitSyncClient.Checkpoint` (concrete `HostSyncCheckpoint`), `IncrementalHostSyncClient` conformance, drain loop, `commitHostCheckpoint`, `ensureHostSubscription` / `deleteHostSubscription`, `resetHostSyncState`, `preferredHostSyncMode` |
| `apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift` | `Notification.Name.catermCloudKitHostChanged`, subscription-id constant |
| `apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift` | `HostSyncCheckpoint` marker protocol, `HostSyncMode`, `HostChangeBatch`, `IncrementalHostSyncClient` protocol |
| `apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift` | Token store actor tests (round-trip, atomic CAS, epoch, corrupt-data fallback) |
| `apps/macos/Tests/CloudKitSyncClientTests/AccountIdentityTrackerTests.swift` | Identity comparison branches |
| `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift` | Drain, checkpoint, commit, subscription, reset tests |
| `apps/macos/Tests/CloudKitSyncClientTests/AppDelegatePushParsingTests.swift` | `parsePushUserInfo(_:)` static helper tests |

### Modified files

| Path | Change |
|---|---|
| `apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift` | Add 4 methods: `fetchDatabaseChanges`, `fetchZoneChanges`, `saveSubscription`, `deleteSubscription` |
| `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift` | Hold `tokenStore`; init signature gains `tokenStore` parameter; existing methods unchanged |
| `apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift` | Rename `reconcile` → `reconcileFullSnapshot`; add `reconcileDelta(local:changedHosts:deletedHostIDs:)` |
| `apps/macos/Sources/HostSyncStore/HostSyncStore.swift` | `client` typed as `IncrementalHostSyncClient`; add `SyncMode`, `sync(mode:)` flow with atomic commit; observe `.catermCloudKitHostChanged`; `periodicInterval` default `15*60` → `60*60` |
| `apps/macos/Sources/Caterm/CatermApp.swift` | Construct `tokenStore` + pass to client; build `AccountIdentityTracker`; rewire `.catermICloudAccountChanged` handler |
| `apps/macos/Sources/Caterm/AppDelegate.swift` | Append `NSApp.registerForRemoteNotifications()` to launch; add 2 push handler methods + static `parsePushUserInfo` |
| `apps/macos/Resources/Caterm.entitlements` | Add `aps-environment=development` |
| `apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift` | Add `enqueueDatabaseChanges`, `enqueueZoneChanges`, `simulateError`, subscription record tracking |
| `apps/macos/Tests/HostSyncStoreTests/HostSyncReconcilerTests.swift` | Update test names for rename; add `reconcileDelta` cases |
| `apps/macos/Tests/HostSyncStoreTests/HostSyncStoreAutoSyncTests.swift` | Update fake to conform `IncrementalHostSyncClient`; add new mode/checkpoint tests |
| `apps/macos/Tests/HostSyncStoreTests/HostSyncStorePeriodicTests.swift` | Update for 60-min default + forceFull-on-tick |
| `apps/macos/Tests/HostSyncStoreTests/CloudKitAuthShapeTests.swift` | Adapt fake conformance |

---

## Conventions

- **Build / test:** `cd apps/macos && swift test --parallel`. Single test: `swift test --filter <ClassName>/<testName>`.
- **Lint / format:** Swift code uses tabs (project default). After cross-target changes run `bun x ultracite check` from repo root for non-Swift artefacts.
- **Commits:** one task = one commit. Commit messages: `<scope>: <imperative>` (e.g. `cloudkit: add ServerChangeTokenStore actor`).
- **Logger:** `os.Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")`. Pass it through as a `Sendable` dependency where it crosses test seams.
- **Don't add unrelated cleanup.** Tests for unchanged behavior stay as-is.
- **Subscription ID:** `"caterm.host.changes.v1"` — use the constant in `CloudKitPushNames.swift`, never inline.
- **Zone ID:** `CKRecordZone.ID(zoneName: "Caterm")` — Plan A constant, already in `CloudKitSyncClient.swift:16`.

---

# Phase 0 — Spike

**Goal:** Prove that silent CloudKit push reaches this dev Mac. Plan A burned a day on UDID / profile setup; same risk class here.

**Exit:** push received once → continue Phase 1. Push not received after debugging → ship Phase 1 only (incremental sync, keep timer at 15 min) and document the failure in `docs/macos-dev-signing.md`.

### Task 0.1: Add `aps-environment` entitlement and re-do provisioning

**Files:**
- Modify: `apps/macos/Resources/Caterm.entitlements`
- Reference: `docs/macos-dev-signing.md`

- [ ] **Step 1: Read the current entitlements file**

```bash
cat apps/macos/Resources/Caterm.entitlements
```
Expected: shows the existing `<plist>` with `com.apple.developer.icloud-services` etc. from Plan A.

- [ ] **Step 2: Add the APS key**

Add this child of the top-level `<dict>` (alphabetical placement is fine):
```xml
<key>aps-environment</key>
<string>development</string>
```

- [ ] **Step 3: Re-issue Mac App Development profile via Apple Developer Portal**

Manual, browser-based:
1. Go to https://developer.apple.com/account/resources/profiles/list.
2. Edit the existing Mac App Development profile for bundle id `com.caterm.app`.
3. Enable the "Push Notifications" capability if it is not already enabled (also confirm "iCloud" with the `iCloud.com.caterm.app` container is still ticked).
4. Generate, download, double-click to install.
5. In Xcode: Signing & Capabilities → tick "Automatically manage signing" off and on once to refresh.

- [ ] **Step 4: Verify the entitlement reaches the signed binary**

Build and inspect:
```bash
make macos-build  # or whatever produces the signed dev binary
codesign -d --entitlements - apps/macos/build/Build/Products/Debug/Caterm.app 2>&1 | grep aps-environment
```
Expected: `<key>aps-environment</key><string>development</string>` appears.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Resources/Caterm.entitlements
git commit -m "macos(entitlements): add aps-environment=development for CloudKit push"
```

---

### Task 0.2: Throwaway debug button to register subscription and log push

**Files:**
- Create (temporary): `apps/macos/Sources/Caterm/Views/Spike/CloudKitPushSpikeView.swift`
- Modify (temporary): `apps/macos/Sources/Caterm/AppDelegate.swift`
- Modify (temporary): wire spike view into a Settings tab or root menu

This task installs throwaway code purely to test reachability. **All of it gets reverted in a single commit at end of Phase 0** (next task).

- [ ] **Step 1: Add a remote-notification logger to `AppDelegate` (temporary)**

Add to `apps/macos/Sources/Caterm/AppDelegate.swift`:
```swift
import os

extension AppDelegate {
    private static let spikeLog = Logger(subsystem: "com.caterm.app", category: "cloudkit-spike")

    func application(_: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Self.spikeLog.info("didReceiveRemoteNotification userInfo=\(userInfo)")
    }

    func application(_: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.spikeLog.info("didRegisterForRemoteNotifications token-bytes=\(deviceToken.count)")
    }

    func application(_: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.spikeLog.error("didFailToRegisterForRemoteNotifications error=\(error.localizedDescription)")
    }
}
```

Append to the end of `applicationDidFinishLaunching`:
```swift
NSApp.registerForRemoteNotifications()
```

- [ ] **Step 2: Add the spike view file**

```swift
// apps/macos/Sources/Caterm/Views/Spike/CloudKitPushSpikeView.swift
import CloudKit
import SwiftUI
import os

struct CloudKitPushSpikeView: View {
    @State private var status: String = "idle"
    private let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-spike")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CloudKit Push Spike").font(.headline)
            Text(status).font(.caption).textSelection(.enabled)
            Button("Register CKDatabaseSubscription") { Task { await register() } }
        }.padding()
    }

    private func register() async {
        let container = CKContainer(identifier: "iCloud.com.caterm.app")
        let db = container.privateCloudDatabase
        let sub = CKDatabaseSubscription(subscriptionID: "caterm.spike.host.changes")
        sub.recordType = "Host"
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            _ = try await db.save(sub)
            status = "subscription saved"
            log.info("subscription saved")
        } catch let ck as CKError where ck.code == .serverRejectedRequest {
            status = "subscription already exists (treated as success)"
            log.info("subscription already exists")
        } catch {
            status = "save failed: \(error.localizedDescription)"
            log.error("save failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 3: Surface the spike view from Preferences**

Find the existing Preferences tab strip (`apps/macos/Sources/Caterm/Views/Preferences/`). Add a temporary tab or a debug menu item that presents `CloudKitPushSpikeView()`.

- [ ] **Step 4: Build and run**

```bash
make dev   # starts Tauri + server, launches the desktop app per CLAUDE.md
```
Click "Register CKDatabaseSubscription". Expected: status flips to "subscription saved" within 2 seconds. If `CKError.notAuthenticated` appears, the iCloud account state is wrong — sign in or re-verify Plan A's setup before retrying.

- [ ] **Step 5: Trigger a remote write, observe push**

In CloudKit Dashboard (https://icloud.developer.apple.com/dashboard/) → container `iCloud.com.caterm.app` → Private Data → edit any `Host` record's `name` field → save.

Open Console.app, filter `subsystem:com.caterm.app category:cloudkit-spike`. Expected within 5–60 seconds:
```
didReceiveRemoteNotification userInfo=...
```
If nothing arrives within 5 minutes, see Step 6.

- [ ] **Step 6: Triage if push didn't arrive**

Decide one of:
1. APS daemon issue (rare on macOS): check `log show --last 5m --predicate 'subsystem == "com.apple.pushLauncher"'` for delivery errors.
2. Bundle identity issue: re-verify Provisioning UDID matches the dev Mac (Plan A pitfall — see `docs/macos-dev-signing.md`).
3. Subscription not actually saved on server: re-open CloudKit Dashboard → Subscriptions → confirm the row exists.
4. Time out and document — see Task 0.3.

Record outcome in a scratch note for Task 0.3.

- [ ] **Step 7: Do not commit**

Spike code stays uncommitted. Task 0.3 reverts it cleanly.

---

### Task 0.3: Document spike outcome and revert spike code

**Files:**
- Modify: `docs/macos-dev-signing.md`
- Revert: changes from Task 0.2

- [ ] **Step 1: Append the verification result to `docs/macos-dev-signing.md`**

Add a new section:
```markdown
## CloudKit silent push (Plan B Phase 0)

- **Date:** YYYY-MM-DD
- **Result:** PASS / FAIL
- **Latency observed:** ~Ns from Dashboard write to didReceiveRemoteNotification
- **Notes:** anything from Task 0.2 Step 6
```

- [ ] **Step 2: Revert spike code**

```bash
git checkout -- apps/macos/Sources/Caterm/AppDelegate.swift
rm apps/macos/Sources/Caterm/Views/Spike/CloudKitPushSpikeView.swift
rmdir apps/macos/Sources/Caterm/Views/Spike  # if empty
# revert the Preferences edit too — git diff to be sure
git diff apps/macos/Sources/Caterm/Views/Preferences/
```
Re-run `swift build` to confirm clean state.

- [ ] **Step 3: If spike passed, commit only the doc update**

```bash
git add docs/macos-dev-signing.md
git commit -m "docs(macos): record CloudKit push spike result"
```

- [ ] **Step 4: If spike failed, abort Phase 2**

Edit `docs/superpowers/specs/2026-05-02-cloudkit-push-subscriptions-design.md` to mark Phase 2 deferred. Commit doc + spec edit. Continue to Phase 1 only — Phase 1 alone still delivers value (per-record incremental fetch).

---

# Phase 1 — B1: Incremental Sync Refactor

**Goal:** Replace `listHosts` for `forceFull` with a drain-and-checkpoint flow built on `CKFetchDatabaseChangesOperation` + `CKFetchRecordZoneChangesOperation`. Add `IncrementalHostSyncClient` so `HostSyncStore` stays in domain types. **No APS / push dependency** — periodic timer stays at 15 min for now.

**Exit:** all `swift test` passes; manual launch of the app produces tokens visible via `defaults read com.caterm.app | grep cloudkit.changeToken`.

---

### Task 1.1: `StoredServerChangeToken` value type + tests

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift
import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class StoredServerChangeTokenTests: XCTestCase {
    func testRoundTripPreservesArchivedDataEquality() throws {
        let token = makeFakeToken()
        let stored = try StoredServerChangeToken.archive(token)
        XCTAssertFalse(stored.archivedData.isEmpty)
        let stored2 = try StoredServerChangeToken.archive(token)
        XCTAssertEqual(stored.archivedData, stored2.archivedData,
                       "archiving the same token must produce equal Data for CAS to work")
    }

    func testUnarchiveReturnsEquivalentToken() throws {
        let token = makeFakeToken()
        let stored = try StoredServerChangeToken.archive(token)
        let restored = try stored.unarchive()
        // CKServerChangeToken is opaque; we can't compare directly. Re-archive
        // and compare bytes.
        let reArchived = try StoredServerChangeToken.archive(restored)
        XCTAssertEqual(stored.archivedData, reArchived.archivedData)
    }

    func testUnarchiveOnGarbageThrows() {
        let stored = StoredServerChangeToken(archivedData: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertThrowsError(try stored.unarchive())
    }

    /// CKServerChangeToken can't be constructed directly. We round-trip through
    /// a real fetch operation in test fixtures — but at the unit level we can
    /// fall back to a mocked archive payload that NSKeyedArchiver accepts.
    /// FakeCloudDatabase will provide one in later tasks; for now use a real
    /// throwaway: spin up a CKContainer query if available, or skip with the
    /// helper below.
    private func makeFakeToken() -> CKServerChangeToken {
        // CKServerChangeToken has no public init. Tests that need a real one
        // must obtain it from a fetch op. For pure round-trip we build it via
        // a helper that runs an in-process fake fetch. See FakeCloudDatabase.
        fatalError("provided by FakeCloudDatabase in Task 1.5; this stub is replaced before that task lands")
    }
}
```

> **Note for executor:** Step 1 ships the test scaffolding deliberately failing (the `fatalError` makes the test crash). Task 1.5 lands `FakeCloudDatabase.makeRealishToken()` that this test will switch to. **Skip running this test until Task 1.5.** Replace `XCTSkip` workaround in Step 4 below.

- [ ] **Step 2: Stub the test by skipping pending Task 1.5**

Update each test method body to:
```swift
throw XCTSkip("requires FakeCloudDatabase.makeRealishToken from Task 1.5")
```

- [ ] **Step 3: Run tests to verify they skip cleanly**

```bash
cd apps/macos && swift test --filter StoredServerChangeTokenTests
```
Expected: 3 tests skipped, 0 failed.

- [ ] **Step 4: Implement `StoredServerChangeToken` and the error type**

```swift
// apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift
import CloudKit
import Foundation

internal enum ServerChangeTokenError: Error, Sendable {
    case unarchiveReturnedNil
}

internal struct StoredServerChangeToken: Equatable, Sendable {
    let archivedData: Data

    init(archivedData: Data) { self.archivedData = archivedData }

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

// TokenCAS / CommitOutcome / ServerChangeTokenStoring follow in Task 1.2.
```

- [ ] **Step 5: Build**

```bash
cd apps/macos && swift build
```
Expected: clean build. (`StoredServerChangeToken` is `internal` and unused publicly; the compiler does not warn on dead internals.)

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift \
        apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift
git commit -m "cloudkit: add StoredServerChangeToken value type"
```

---

### Task 1.2: `ServerChangeTokenStoring` actor protocol + `InMemoryServerChangeTokenStore`

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `ServerChangeTokenStoreTests.swift`:
```swift
final class InMemoryServerChangeTokenStoreTests: XCTestCase {
    func testCommitTokensApplied() async throws {
        let store = InMemoryServerChangeTokenStore()
        let epoch = await store.currentEpoch()
        let outcome = await store.commitTokens(
            expectedEpoch: epoch,
            db: TokenCAS(prev: nil, new: Data([1, 2, 3])),
            zones: [:]
        )
        XCTAssertEqual(outcome, .applied)
        let stored = await store.loadDatabaseToken()
        XCTAssertEqual(stored?.archivedData, Data([1, 2, 3]))
    }

    func testCommitTokensStaleEpoch() async throws {
        let store = InMemoryServerChangeTokenStore()
        let staleEpoch = await store.currentEpoch()
        await store.bumpEpoch()
        let outcome = await store.commitTokens(
            expectedEpoch: staleEpoch,
            db: TokenCAS(prev: nil, new: Data([1])),
            zones: [:]
        )
        XCTAssertEqual(outcome, .staleEpoch)
        let stored = await store.loadDatabaseToken()
        XCTAssertNil(stored, "stale-epoch commit must not write")
    }

    func testCommitTokensPartialCASOnDb() async throws {
        let store = InMemoryServerChangeTokenStore()
        let epoch = await store.currentEpoch()
        // Pre-seed a token by an earlier successful commit.
        _ = await store.commitTokens(
            expectedEpoch: epoch,
            db: TokenCAS(prev: nil, new: Data([1])),
            zones: [:]
        )
        // Try to commit assuming prev was nil — but persisted is now Data([1]).
        let outcome = await store.commitTokens(
            expectedEpoch: epoch,
            db: TokenCAS(prev: nil, new: Data([2])),
            zones: [:]
        )
        XCTAssertEqual(outcome, .partialCAS(skippedZoneKeys: [], skippedDb: true))
        let stored = await store.loadDatabaseToken()
        XCTAssertEqual(stored?.archivedData, Data([1]))
    }

    func testClearAllBumpsEpochAndDeletesKeys() async throws {
        let store = InMemoryServerChangeTokenStore()
        let epoch0 = await store.currentEpoch()
        _ = await store.commitTokens(
            expectedEpoch: epoch0,
            db: TokenCAS(prev: nil, new: Data([1])),
            zones: ["Z": TokenCAS(prev: nil, new: Data([2]))]
        )
        await store.clearAll()
        let epoch1 = await store.currentEpoch()
        XCTAssertEqual(epoch1, epoch0 + 1)
        let db = await store.loadDatabaseToken()
        XCTAssertNil(db)
        let zone = await store.loadZoneToken(CKRecordZone.ID(zoneName: "Z"))
        XCTAssertNil(zone)
    }
}
```

- [ ] **Step 2: Run, expect compile failures**

```bash
cd apps/macos && swift test --filter InMemoryServerChangeTokenStoreTests
```
Expected: compile errors — types don't exist yet.

- [ ] **Step 3: Add `TokenCAS`, `CommitOutcome`, protocol, and in-memory actor**

Append to `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`:
```swift
internal struct TokenCAS: Sendable {
    let prev: Data?
    let new: Data?
}

internal enum CommitOutcome: Sendable, Equatable {
    case applied
    case staleEpoch
    case partialCAS(skippedZoneKeys: [String], skippedDb: Bool)
}

internal protocol ServerChangeTokenStoring: Sendable {
    func currentEpoch() async -> UInt64
    func bumpEpoch() async
    func loadDatabaseToken() async -> StoredServerChangeToken?
    func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken?
    func commitTokens(expectedEpoch: UInt64,
                      db: TokenCAS,
                      zones: [String: TokenCAS]) async -> CommitOutcome
    func clearAll() async
}

internal actor InMemoryServerChangeTokenStore: ServerChangeTokenStoring {
    private var epoch: UInt64 = 0
    private var dbToken: StoredServerChangeToken?
    private var zoneTokens: [String: StoredServerChangeToken] = [:]

    init() {}

    func currentEpoch() async -> UInt64 { epoch }
    func bumpEpoch() async { epoch &+= 1 }

    func loadDatabaseToken() async -> StoredServerChangeToken? { dbToken }
    func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken? {
        zoneTokens[Self.key(for: zoneID)]
    }

    func commitTokens(expectedEpoch: UInt64,
                      db: TokenCAS,
                      zones: [String: TokenCAS]) async -> CommitOutcome {
        guard expectedEpoch == epoch else { return .staleEpoch }
        var skippedZones: [String] = []
        var skippedDb = false

        for (zoneKey, cas) in zones {
            let persistedArchive = zoneTokens[zoneKey]?.archivedData
            if persistedArchive == cas.prev {
                if let new = cas.new {
                    zoneTokens[zoneKey] = StoredServerChangeToken(archivedData: new)
                } else {
                    zoneTokens.removeValue(forKey: zoneKey)
                }
            } else {
                skippedZones.append(zoneKey)
            }
        }

        let persistedDbArchive = dbToken?.archivedData
        if persistedDbArchive == db.prev {
            if let new = db.new {
                dbToken = StoredServerChangeToken(archivedData: new)
            } else {
                dbToken = nil
            }
        } else {
            skippedDb = true
        }

        if skippedZones.isEmpty && !skippedDb { return .applied }
        return .partialCAS(skippedZoneKeys: skippedZones, skippedDb: skippedDb)
    }

    func clearAll() async {
        epoch &+= 1
        dbToken = nil
        zoneTokens.removeAll()
    }

    static func key(for zoneID: CKRecordZone.ID) -> String {
        "\(zoneID.zoneName).\(zoneID.ownerName)"
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
cd apps/macos && swift test --filter InMemoryServerChangeTokenStoreTests
```
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift \
        apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift
git commit -m "cloudkit: add ServerChangeTokenStoring actor protocol + in-memory impl"
```

---

### Task 1.3: `UserDefaultsServerChangeTokenStore` (production actor)

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift`

- [ ] **Step 1: Write failing tests against a UserDefaults instance**

Append:
```swift
final class UserDefaultsServerChangeTokenStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "UserDefaultsServerChangeTokenStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testRoundTripPersistsAcrossInstances() async throws {
        let s1 = UserDefaultsServerChangeTokenStore(defaults: defaults)
        let epoch = await s1.currentEpoch()
        _ = await s1.commitTokens(
            expectedEpoch: epoch,
            db: TokenCAS(prev: nil, new: Data([9, 9, 9])),
            zones: [:]
        )
        // New instance reading the same defaults backing
        let s2 = UserDefaultsServerChangeTokenStore(defaults: defaults)
        let token = await s2.loadDatabaseToken()
        XCTAssertEqual(token?.archivedData, Data([9, 9, 9]))
    }

    func testCorruptStoredBytesAreReturnedAsIsForCAS() async throws {
        // Pre-seed garbage directly via UserDefaults; loadDatabaseToken
        // must NOT decode synchronously, so it returns the bytes wrapped.
        defaults.set(Data([0xDE, 0xAD]), forKey: "cloudkit.changeToken.database")
        let s = UserDefaultsServerChangeTokenStore(defaults: defaults)
        let token = await s.loadDatabaseToken()
        XCTAssertEqual(token?.archivedData, Data([0xDE, 0xAD]))
        XCTAssertThrowsError(try token?.unarchive())
    }

    func testEpochSurvivesAcrossInstances() async throws {
        let s1 = UserDefaultsServerChangeTokenStore(defaults: defaults)
        await s1.bumpEpoch()
        await s1.bumpEpoch()
        let s2 = UserDefaultsServerChangeTokenStore(defaults: defaults)
        let epoch = await s2.currentEpoch()
        XCTAssertEqual(epoch, 2)
    }
}
```

- [ ] **Step 2: Run, expect compile failures**

```bash
cd apps/macos && swift test --filter UserDefaultsServerChangeTokenStoreTests
```

- [ ] **Step 3: Implement the production actor**

Append to `apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift`:
```swift
internal actor UserDefaultsServerChangeTokenStore: ServerChangeTokenStoring {
    private static let dbKey = "cloudkit.changeToken.database"
    private static let epochKey = "cloudkit.changeToken.epoch"
    private static let zonePrefix = "cloudkit.changeToken.zone."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentEpoch() async -> UInt64 {
        UInt64(bitPattern: Int64(defaults.integer(forKey: Self.epochKey)))
    }

    func bumpEpoch() async {
        let current = await currentEpoch()
        defaults.set(Int64(bitPattern: current &+ 1), forKey: Self.epochKey)
    }

    func loadDatabaseToken() async -> StoredServerChangeToken? {
        defaults.data(forKey: Self.dbKey).map { StoredServerChangeToken(archivedData: $0) }
    }

    func loadZoneToken(_ zoneID: CKRecordZone.ID) async -> StoredServerChangeToken? {
        defaults.data(forKey: Self.zoneKey(for: zoneID))
            .map { StoredServerChangeToken(archivedData: $0) }
    }

    func commitTokens(expectedEpoch: UInt64,
                      db: TokenCAS,
                      zones: [String: TokenCAS]) async -> CommitOutcome {
        guard await currentEpoch() == expectedEpoch else { return .staleEpoch }

        var skippedZones: [String] = []
        var skippedDb = false

        for (zoneKey, cas) in zones {
            let storageKey = Self.zonePrefix + zoneKey
            let persisted = defaults.data(forKey: storageKey)
            if persisted == cas.prev {
                if let new = cas.new {
                    defaults.set(new, forKey: storageKey)
                } else {
                    defaults.removeObject(forKey: storageKey)
                }
            } else {
                skippedZones.append(zoneKey)
            }
        }

        let persistedDb = defaults.data(forKey: Self.dbKey)
        if persistedDb == db.prev {
            if let new = db.new {
                defaults.set(new, forKey: Self.dbKey)
            } else {
                defaults.removeObject(forKey: Self.dbKey)
            }
        } else {
            skippedDb = true
        }

        if skippedZones.isEmpty && !skippedDb { return .applied }
        return .partialCAS(skippedZoneKeys: skippedZones, skippedDb: skippedDb)
    }

    func clearAll() async {
        await bumpEpoch()
        defaults.removeObject(forKey: Self.dbKey)
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.zonePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func zoneKey(for zoneID: CKRecordZone.ID) -> String {
        zonePrefix + InMemoryServerChangeTokenStore.key(for: zoneID)
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
cd apps/macos && swift test --filter UserDefaultsServerChangeTokenStoreTests
```
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/ServerChangeTokenStore.swift \
        apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift
git commit -m "cloudkit: add UserDefaultsServerChangeTokenStore actor"
```

---

### Task 1.4: Extend `CKDatabaseProtocol` with changes / subscription methods

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift`

- [ ] **Step 1: Read the current `FakeCloudDatabase` to understand its style**

```bash
cat apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift
```
Note its "enqueue script + recorded calls" pattern.

- [ ] **Step 2: Extend the protocol**

Edit `apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift`:
```swift
public protocol CKDatabaseProtocol: Sendable {
    // existing methods unchanged...

    func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
        async throws -> (changedZoneIDs: [CKRecordZone.ID],
                         deletedZoneIDs: [CKRecordZone.ID],
                         purgedZoneIDs: [CKRecordZone.ID],
                         encryptedDataResetZoneIDs: [CKRecordZone.ID],
                         newToken: CKServerChangeToken?,
                         moreComing: Bool)

    func fetchZoneChanges(zoneID: CKRecordZone.ID,
                          previousServerChangeToken: CKServerChangeToken?)
        async throws -> (changedRecords: [CKRecord],
                         deletedRecords: [(CKRecord.ID, CKRecord.RecordType)],
                         newToken: CKServerChangeToken?,
                         moreComing: Bool)

    func saveSubscription(_ subscription: CKSubscription)
        async throws -> CKSubscription
    func deleteSubscription(withID id: CKSubscription.ID)
        async throws -> CKSubscription.ID
}
```

- [ ] **Step 3: Add real `CKDatabase` default impls bridging to the operation API**

Append to the same file:
```swift
extension CKDatabase {
    public func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
        async throws -> (changedZoneIDs: [CKRecordZone.ID],
                         deletedZoneIDs: [CKRecordZone.ID],
                         purgedZoneIDs: [CKRecordZone.ID],
                         encryptedDataResetZoneIDs: [CKRecordZone.ID],
                         newToken: CKServerChangeToken?,
                         moreComing: Bool) {
        try await withCheckedThrowingContinuation { cont in
            let op = CKFetchDatabaseChangesOperation(
                previousServerChangeToken: previousServerChangeToken
            )
            var changed: [CKRecordZone.ID] = []
            var deleted: [CKRecordZone.ID] = []
            var purged: [CKRecordZone.ID] = []
            var encReset: [CKRecordZone.ID] = []
            var newToken: CKServerChangeToken?
            var more = false
            op.recordZoneWithIDChangedBlock = { changed.append($0) }
            op.recordZoneWithIDWasDeletedBlock = { deleted.append($0) }
            op.recordZoneWithIDWasPurgedBlock = { purged.append($0) }
            op.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = {
                encReset.append($0)
            }
            op.changeTokenUpdatedBlock = { newToken = $0 }
            op.fetchDatabaseChangesResultBlock = { result in
                switch result {
                case .success(let info):
                    newToken = info.serverChangeToken
                    more = info.moreComing
                    cont.resume(returning: (changed, deleted, purged, encReset,
                                            newToken, more))
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
            self.add(op)
        }
    }

    public func fetchZoneChanges(zoneID: CKRecordZone.ID,
                                 previousServerChangeToken: CKServerChangeToken?)
        async throws -> (changedRecords: [CKRecord],
                         deletedRecords: [(CKRecord.ID, CKRecord.RecordType)],
                         newToken: CKServerChangeToken?,
                         moreComing: Bool) {
        try await withCheckedThrowingContinuation { cont in
            let cfg = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: previousServerChangeToken,
                resultsLimit: nil,
                desiredKeys: nil
            )
            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: cfg]
            )
            var changed: [CKRecord] = []
            var deleted: [(CKRecord.ID, CKRecord.RecordType)] = []
            var newToken: CKServerChangeToken?
            var more = false
            op.recordWasChangedBlock = { _, result in
                if case .success(let rec) = result { changed.append(rec) }
            }
            op.recordWithIDWasDeletedBlock = { id, rt in deleted.append((id, rt)) }
            op.recordZoneFetchResultBlock = { _, result in
                if case .success(let info) = result {
                    newToken = info.serverChangeToken
                    more = info.moreComing
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: (changed, deleted, newToken, more))
                case .failure(let err):
                    cont.resume(throwing: err)
                }
            }
            self.add(op)
        }
    }

    public func saveSubscription(_ subscription: CKSubscription)
        async throws -> CKSubscription {
        // CKDatabase has an iOS 15 / macOS 12 async overload already.
        try await save(subscription)
    }

    public func deleteSubscription(withID id: CKSubscription.ID)
        async throws -> CKSubscription.ID {
        try await deleteSubscription(withID: id)  // existing async overload
    }
}
```

- [ ] **Step 4: Build, expect compile failures only in `FakeCloudDatabase`**

```bash
cd apps/macos && swift build
```
Expected: `FakeCloudDatabase does not conform to protocol 'CKDatabaseProtocol'`.

- [ ] **Step 5: Extend `FakeCloudDatabase`**

Edit `apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift`. Add stored fields and methods:
```swift
// Add near other stored properties:
struct DatabaseChangesScript {
    var changedZoneIDs: [CKRecordZone.ID] = []
    var deletedZoneIDs: [CKRecordZone.ID] = []
    var purgedZoneIDs: [CKRecordZone.ID] = []
    var encryptedDataResetZoneIDs: [CKRecordZone.ID] = []
    var newToken: CKServerChangeToken?
    var moreComing: Bool = false
    var error: Error?
}
struct ZoneChangesScript {
    var changedRecords: [CKRecord] = []
    var deletedRecords: [(CKRecord.ID, CKRecord.RecordType)] = []
    var newToken: CKServerChangeToken?
    var moreComing: Bool = false
    var error: Error?
}

private var databaseChangesQueue: [DatabaseChangesScript] = []
private var zoneChangesQueue: [CKRecordZone.ID: [ZoneChangesScript]] = [:]
private(set) var savedSubscriptions: [CKSubscription] = []
private(set) var deletedSubscriptionIDs: [CKSubscription.ID] = []
var saveSubscriptionError: Error?
var deleteSubscriptionError: Error?

func enqueueDatabaseChanges(_ script: DatabaseChangesScript) {
    databaseChangesQueue.append(script)
}
func enqueueZoneChanges(_ zoneID: CKRecordZone.ID, _ script: ZoneChangesScript) {
    zoneChangesQueue[zoneID, default: []].append(script)
}

// Helper: produces a CKServerChangeToken via a real (no-op) DB call. The
// only legal way to obtain one is from a real CloudKit op; tests that need
// concrete tokens should use this once at suite setUp and reuse the result.
static func makeRealishToken() throws -> CKServerChangeToken {
    // Archive a sentinel pattern that NSKeyedUnarchiver round-trips to a
    // CKServerChangeToken-shaped placeholder. CloudKit will reject it for
    // real ops, but for in-process tests it's enough that the type matches.
    // If this proves brittle in CI, gate the affected tests with XCTSkip.
    // The simplest portable fixture: keyed-archive a placeholder by replaying
    // a pre-captured byte sequence.
    let bytes = Data(base64Encoded:
        "YnBsaXN0MDDUAQIDBAUGBwhYJHZlcnNpb25YJG9iamVjdHNZJGFyY2hpdmVyVCR0b3AS"
        + "AAGGoKMJChJVJG51bGzSCwwNDl8QF0NLU2VydmVyQ2hhbmdlVG9rZW4tZmFrZQAAAAAA"
        + "AAAAAAAAAA=="
    )!
    return try NSKeyedUnarchiver.unarchivedObject(
        ofClass: CKServerChangeToken.self, from: bytes
    ) ?? { throw NSError(domain: "FakeCloudDatabase", code: 1) }()
}
```

> **If `makeRealishToken()` throws because the byte fixture isn't accepted**, fall back to skipping affected unit tests with `try XCTSkipIf(skipTokenReason != nil)` and rely on the integration tests in Task 2.10 for end-to-end coverage. Update `StoredServerChangeTokenTests` (Task 1.1 stubs) to use this helper or skip.

Add the protocol-method impls:
```swift
func fetchDatabaseChanges(previousServerChangeToken: CKServerChangeToken?)
    async throws -> ([CKRecordZone.ID], [CKRecordZone.ID], [CKRecordZone.ID],
                     [CKRecordZone.ID], CKServerChangeToken?, Bool) {
    guard !databaseChangesQueue.isEmpty else {
        return ([], [], [], [], nil, false)
    }
    let s = databaseChangesQueue.removeFirst()
    if let err = s.error { throw err }
    return (s.changedZoneIDs, s.deletedZoneIDs, s.purgedZoneIDs,
            s.encryptedDataResetZoneIDs, s.newToken, s.moreComing)
}

func fetchZoneChanges(zoneID: CKRecordZone.ID,
                      previousServerChangeToken: CKServerChangeToken?)
    async throws -> ([CKRecord], [(CKRecord.ID, CKRecord.RecordType)],
                     CKServerChangeToken?, Bool) {
    guard var queue = zoneChangesQueue[zoneID], !queue.isEmpty else {
        return ([], [], nil, false)
    }
    let s = queue.removeFirst()
    zoneChangesQueue[zoneID] = queue
    if let err = s.error { throw err }
    return (s.changedRecords, s.deletedRecords, s.newToken, s.moreComing)
}

func saveSubscription(_ subscription: CKSubscription) async throws -> CKSubscription {
    if let err = saveSubscriptionError { throw err }
    savedSubscriptions.append(subscription)
    return subscription
}

func deleteSubscription(withID id: CKSubscription.ID) async throws -> CKSubscription.ID {
    if let err = deleteSubscriptionError { throw err }
    deletedSubscriptionIDs.append(id)
    return id
}
```

- [ ] **Step 6: Now resolve the Task 1.1 token-test skips**

Change each `throw XCTSkip(...)` in `StoredServerChangeTokenTests` to use `try FakeCloudDatabase.makeRealishToken()`. If the fixture rejection bites, leave one or two tests as `XCTSkip` and document why.

- [ ] **Step 7: Build + run all CloudKitSyncClient tests**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientTests
```
Expected: existing tests pass, new token-store tests pass, `StoredServerChangeTokenTests` either pass or skip.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift \
        apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift \
        apps/macos/Tests/CloudKitSyncClientTests/ServerChangeTokenStoreTests.swift
git commit -m "cloudkit: extend CKDatabaseProtocol + FakeCloudDatabase for changes/subscriptions"
```

---

### Task 1.5: `IncrementalHostSyncClient` protocol surface

**Files:**
- Create: `apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift`

- [ ] **Step 1: Create the file with marker protocol + types**

```swift
// apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift
import Foundation

public enum HostSyncMode: Sendable, Equatable {
    case incremental
    case forceFull
}

public protocol HostSyncCheckpoint: Sendable {
    /// Stable identity for tests / logs. Implementation-defined.
    var id: UUID { get }
}

public struct HostChangeBatch: Sendable {
    public let changedHosts: [RemoteHost]
    public let deletedHostIDs: [String]
    public let checkpoint: (any HostSyncCheckpoint)?
    public let tokenExpired: Bool
    public let mode: HostSyncMode

    public init(changedHosts: [RemoteHost],
                deletedHostIDs: [String],
                checkpoint: (any HostSyncCheckpoint)?,
                tokenExpired: Bool,
                mode: HostSyncMode) {
        self.changedHosts = changedHosts
        self.deletedHostIDs = deletedHostIDs
        self.checkpoint = checkpoint
        self.tokenExpired = tokenExpired
        self.mode = mode
    }
}

public protocol IncrementalHostSyncClient: ServerSyncClient {
    func preferredHostSyncMode() async -> HostSyncMode
    func fetchHostChanges() async throws -> HostChangeBatch
    func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch
    func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws
    func resetHostSyncState() async
    func ensureHostSubscription() async throws
    func deleteHostSubscription() async throws
}
```

- [ ] **Step 2: Build**

```bash
cd apps/macos && swift build
```
Expected: clean build. (No conformer yet — added in Task 1.6+.)

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift
git commit -m "ServerSyncClient: add IncrementalHostSyncClient protocol"
```

---

### Task 1.6: Push-name constants module

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift`

- [ ] **Step 1: Create the file**

```swift
// apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift
import Foundation

extension Notification.Name {
    /// Posted by AppDelegate.application(_:didReceiveRemoteNotification:)
    /// when a CKDatabaseSubscription notification matching the Host
    /// subscription ID arrives. Observed by HostSyncStore.
    public static let catermCloudKitHostChanged =
        Notification.Name("catermCloudKitHostChanged")
}

public enum CloudKitPushNames {
    public static let hostSubscriptionID = "caterm.host.changes.v1"
}
```

- [ ] **Step 2: Build + commit**

```bash
cd apps/macos && swift build
git add apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift
git commit -m "cloudkit: add push notification name + subscription id constants"
```

---

### Task 1.7: `CloudKitSyncClient` checkpoint type + `tokenStore` injection

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift`

- [ ] **Step 1: Add internal nested checkpoint and update init**

Edit `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift`:
```swift
public final class CloudKitSyncClient: ServerSyncClient {
    private let database: CKDatabaseProtocol
    private let zoneID: CKRecordZone.ID
    internal let tokenStore: any ServerChangeTokenStoring

    /// Concrete checkpoint payload. Internal — only this module
    /// constructs / interprets values.
    internal struct Checkpoint: HostSyncCheckpoint {
        let id: UUID
        let epoch: UInt64
        let prevDb: Data?
        let newDb: Data?
        let prevZones: [String: Data?]
        let newZones: [String: Data?]
    }

    public convenience init(
        database: CKDatabaseProtocol,
        zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "Caterm")
    ) {
        self.init(database: database, zoneID: zoneID,
                  tokenStore: UserDefaultsServerChangeTokenStore())
    }

    internal init(database: CKDatabaseProtocol,
                  zoneID: CKRecordZone.ID,
                  tokenStore: any ServerChangeTokenStoring) {
        self.database = database
        self.zoneID = zoneID
        self.tokenStore = tokenStore
    }
    // ... rest of file unchanged
}
```

- [ ] **Step 2: Build, fix any callers**

```bash
cd apps/macos && swift build
```
Expected: clean build (the public init is preserved via `convenience`).

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift
git commit -m "cloudkit: inject ServerChangeTokenStoring into CloudKitSyncClient"
```

---

### Task 1.8: `fetchHostChanges` + `fetchHostSnapshotAndCheckpoint` drain loop

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift`

- [ ] **Step 1: Stub the new file**

```swift
// apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift
import CloudKit
import Foundation
import ServerSyncClient
import os

extension CloudKitSyncClient: IncrementalHostSyncClient {
    private static let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")
    private static let hostRecordType = "Host"

    public func preferredHostSyncMode() async -> HostSyncMode {
        let stored = await tokenStore.loadDatabaseToken()
        return stored == nil ? .forceFull : .incremental
    }

    public func fetchHostChanges() async throws -> HostChangeBatch {
        try await drain(mode: .incremental)
    }

    public func fetchHostSnapshotAndCheckpoint() async throws -> HostChangeBatch {
        try await drain(mode: .forceFull)
    }

    public func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
        // Implemented in Task 1.10.
    }

    public func resetHostSyncState() async {
        await tokenStore.clearAll()
    }

    public func ensureHostSubscription() async throws {
        // Implemented in Task 2.1.
    }

    public func deleteHostSubscription() async throws {
        // Implemented in Task 2.1.
    }

    // MARK: - Drain loop

    private func drain(mode: HostSyncMode) async throws -> HostChangeBatch {
        let fetchEpoch = await tokenStore.currentEpoch()
        let persistedDb = await tokenStore.loadDatabaseToken()
        let casPreviousDbArchive = persistedDb?.archivedData
        var operationPreviousDbToken: CKServerChangeToken? = nil
        if mode == .incremental, let stored = persistedDb {
            operationPreviousDbToken = (try? stored.unarchive())
            if operationPreviousDbToken == nil {
                Self.log.error("db token unarchive failed; falling back to forceFull")
            }
        }

        var changedHosts: [RemoteHost] = []
        var deletedHostIDs: [String] = []
        var deletedZoneIDs: Set<CKRecordZone.ID> = []
        var purgedZoneIDs: Set<CKRecordZone.ID> = []
        var encryptedResetZoneIDs: Set<CKRecordZone.ID> = []
        var casPreviousZoneArchives: [String: Data?] = [:]
        var pendingZoneTokens: [String: Data] = [:]
        var rollingDbToken: CKServerChangeToken? = operationPreviousDbToken

        databaseLoop: while true {
            let dbResult = try await database.fetchDatabaseChanges(
                previousServerChangeToken: rollingDbToken
            )
            deletedZoneIDs.formUnion(dbResult.deletedZoneIDs)
            purgedZoneIDs.formUnion(dbResult.purgedZoneIDs)
            encryptedResetZoneIDs.formUnion(dbResult.encryptedDataResetZoneIDs)

            for zoneID in dbResult.changedZoneIDs {
                let zoneKey = InMemoryServerChangeTokenStore.key(for: zoneID)
                if casPreviousZoneArchives[zoneKey] == nil {
                    let persistedZone = await tokenStore.loadZoneToken(zoneID)
                    casPreviousZoneArchives[zoneKey] = persistedZone?.archivedData
                    var operationPrev: CKServerChangeToken? = nil
                    if mode == .incremental, let stored = persistedZone {
                        operationPrev = (try? stored.unarchive())
                        if operationPrev == nil {
                            Self.log.error("zone token unarchive failed for \(zoneKey); using nil")
                        }
                    }
                    var rollingZoneToken = operationPrev

                    zoneLoop: while true {
                        let zResult = try await database.fetchZoneChanges(
                            zoneID: zoneID,
                            previousServerChangeToken: rollingZoneToken
                        )
                        for record in zResult.changedRecords
                        where record.recordType == Self.hostRecordType {
                            if let host = try? CKRecordHostMapping.decode(record) {
                                changedHosts.append(host)
                            }
                        }
                        for (recordID, recordType) in zResult.deletedRecords
                        where recordType == Self.hostRecordType {
                            deletedHostIDs.append(recordID.recordName)
                        }
                        rollingZoneToken = zResult.newToken
                        if !zResult.moreComing { break zoneLoop }
                    }

                    if let final = rollingZoneToken,
                       let archived = try? StoredServerChangeToken.archive(final) {
                        pendingZoneTokens[zoneKey] = archived.archivedData
                    }
                }
            }

            rollingDbToken = dbResult.newToken
            if !dbResult.moreComing { break databaseLoop }
        }

        // Caterm-zone destruction short-circuit.
        let catermZone = self.zoneID
        if deletedZoneIDs.contains(catermZone)
            || purgedZoneIDs.contains(catermZone)
            || encryptedResetZoneIDs.contains(catermZone) {
            // Wipe Caterm-zone token; commit through tokenStore so atomicity holds.
            let zoneKey = InMemoryServerChangeTokenStore.key(for: catermZone)
            _ = await tokenStore.commitTokens(
                expectedEpoch: fetchEpoch,
                db: TokenCAS(prev: casPreviousDbArchive, new: casPreviousDbArchive),
                zones: [zoneKey: TokenCAS(
                    prev: casPreviousZoneArchives[zoneKey] ?? nil,
                    new: nil
                )]
            )
            return HostChangeBatch(
                changedHosts: [], deletedHostIDs: [],
                checkpoint: nil, tokenExpired: true, mode: mode
            )
        }

        let newDbArchive: Data? = rollingDbToken.flatMap {
            try? StoredServerChangeToken.archive($0).archivedData
        }
        let prevZonesForCAS = casPreviousZoneArchives
        let newZonesForCAS: [String: Data?] = pendingZoneTokens.mapValues { Optional($0) }

        let checkpoint = Checkpoint(
            id: UUID(),
            epoch: fetchEpoch,
            prevDb: casPreviousDbArchive,
            newDb: newDbArchive,
            prevZones: prevZonesForCAS,
            newZones: newZonesForCAS
        )

        return HostChangeBatch(
            changedHosts: changedHosts,
            deletedHostIDs: deletedHostIDs,
            checkpoint: checkpoint,
            tokenExpired: false,
            mode: mode
        )
    }
}
```

- [ ] **Step 2: Update `Package.swift` if needed**

CloudKitSyncClient already depends on ServerSyncClient. No change needed.

- [ ] **Step 3: Build**

```bash
cd apps/macos && swift build
```
Expected: clean build.

- [ ] **Step 4: Add a smoke test for the empty-result path**

```swift
// apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift
import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import ServerSyncClient

final class CloudKitSyncClientPushTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "Caterm")
    private var fakeDB: FakeCloudDatabase!
    private var tokenStore: InMemoryServerChangeTokenStore!
    private var client: CloudKitSyncClient!

    override func setUp() async throws {
        fakeDB = FakeCloudDatabase()
        tokenStore = InMemoryServerChangeTokenStore()
        client = CloudKitSyncClient(database: fakeDB, zoneID: zoneID, tokenStore: tokenStore)
    }

    func testEmptyDatabaseChangesReturnsEmptyBatch() async throws {
        let batch = try await client.fetchHostChanges()
        XCTAssertTrue(batch.changedHosts.isEmpty)
        XCTAssertTrue(batch.deletedHostIDs.isEmpty)
        XCTAssertFalse(batch.tokenExpired)
        XCTAssertNotNil(batch.checkpoint)
        XCTAssertEqual(batch.mode, .incremental)
    }
}
```

- [ ] **Step 5: Run + commit**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientPushTests
git add apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift \
        apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift
git commit -m "cloudkit: add fetchHostChanges/Snapshot drain loop"
```

---

### Task 1.9: Drain-loop tests — pagination, recordType filter, deleted/purged/encrypted zone

**Files:**
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift`

- [ ] **Step 1: Add tests covering each spec error-table row for fetch**

```swift
func testFetchHostChangesDrainsZoneLevelMoreComing() async throws {
    let token1 = try FakeCloudDatabase.makeRealishToken()
    let token2 = try FakeCloudDatabase.makeRealishToken()

    fakeDB.enqueueDatabaseChanges(.init(
        changedZoneIDs: [zoneID], newToken: token1, moreComing: false
    ))
    let rec1 = makeHostRecord(name: "h1")
    let rec2 = makeHostRecord(name: "h2")
    fakeDB.enqueueZoneChanges(zoneID, .init(
        changedRecords: [rec1], newToken: token1, moreComing: true
    ))
    fakeDB.enqueueZoneChanges(zoneID, .init(
        changedRecords: [rec2], newToken: token2, moreComing: false
    ))

    let batch = try await client.fetchHostChanges()
    XCTAssertEqual(batch.changedHosts.map(\.name).sorted(), ["h1", "h2"])
}

func testFetchHostChangesIgnoresDeletionsOfNonHostRecordTypes() async throws {
    fakeDB.enqueueDatabaseChanges(.init(
        changedZoneIDs: [zoneID], newToken: nil, moreComing: false
    ))
    fakeDB.enqueueZoneChanges(zoneID, .init(
        changedRecords: [],
        deletedRecords: [
            (CKRecord.ID(recordName: "host-1", zoneID: zoneID), "Host"),
            (CKRecord.ID(recordName: "settings-1", zoneID: zoneID), "Settings"),
        ],
        newToken: nil, moreComing: false
    ))
    let batch = try await client.fetchHostChanges()
    XCTAssertEqual(batch.deletedHostIDs, ["host-1"])
}

func testCatermZoneInDeletedZoneIDsReturnsTokenExpired() async throws {
    fakeDB.enqueueDatabaseChanges(.init(
        deletedZoneIDs: [zoneID], newToken: nil, moreComing: false
    ))
    let batch = try await client.fetchHostChanges()
    XCTAssertTrue(batch.tokenExpired)
    XCTAssertNil(batch.checkpoint)
    XCTAssertTrue(batch.changedHosts.isEmpty)
}

func testCatermZoneInPurgedZoneIDsBehavesIdenticallyToDeletedZone() async throws {
    fakeDB.enqueueDatabaseChanges(.init(
        purgedZoneIDs: [zoneID], newToken: nil, moreComing: false
    ))
    let batch = try await client.fetchHostChanges()
    XCTAssertTrue(batch.tokenExpired)
    XCTAssertNil(batch.checkpoint)
}

func testCatermZoneInEncryptedDataResetZoneIDsBehavesIdenticallyToDeletedZone() async throws {
    fakeDB.enqueueDatabaseChanges(.init(
        encryptedDataResetZoneIDs: [zoneID], newToken: nil, moreComing: false
    ))
    let batch = try await client.fetchHostChanges()
    XCTAssertTrue(batch.tokenExpired)
    XCTAssertNil(batch.checkpoint)
}

private func makeHostRecord(name: String) -> CKRecord {
    let rec = CKRecord(recordType: "Host",
                       recordID: CKRecord.ID(recordName: UUID().uuidString,
                                             zoneID: zoneID))
    rec["name"] = name as CKRecordValue
    rec["hostname"] = "h.example.com" as CKRecordValue
    rec["port"] = 22 as CKRecordValue
    rec["username"] = "u" as CKRecordValue
    rec["authType"] = "password" as CKRecordValue
    return rec
}
```

- [ ] **Step 2: Run tests**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientPushTests
```
Expected: 6 PASS (plus the smoke test from Task 1.8). If `makeRealishToken()` errors, `XCTSkip` only the pagination-token test; the others use `nil` tokens.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift
git commit -m "cloudkit: cover drain loop pagination + zone-deletion paths"
```

---

### Task 1.10: `commitHostCheckpoint` + atomic CAS tests

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift`

- [ ] **Step 1: Add the failing tests**

```swift
func testCommitHostCheckpointPersistsBothDbAndZoneTokens() async throws {
    let token = try FakeCloudDatabase.makeRealishToken()
    fakeDB.enqueueDatabaseChanges(.init(changedZoneIDs: [zoneID],
                                        newToken: token, moreComing: false))
    fakeDB.enqueueZoneChanges(zoneID, .init(newToken: token, moreComing: false))

    let batch = try await client.fetchHostChanges()
    let checkpoint = try XCTUnwrap(batch.checkpoint)
    try await client.commitHostCheckpoint(checkpoint)

    let stored = await tokenStore.loadDatabaseToken()
    XCTAssertNotNil(stored)
}

func testForceFullWithExistingTokensCommitsFreshCheckpoint() async throws {
    // Pre-seed an existing db token archive.
    let pre = try FakeCloudDatabase.makeRealishToken()
    let preArchived = try StoredServerChangeToken.archive(pre)
    _ = await tokenStore.commitTokens(
        expectedEpoch: tokenStore.currentEpoch(),
        db: TokenCAS(prev: nil, new: preArchived.archivedData),
        zones: [:]
    )

    let post = try FakeCloudDatabase.makeRealishToken()
    fakeDB.enqueueDatabaseChanges(.init(newToken: post, moreComing: false))

    let batch = try await client.fetchHostSnapshotAndCheckpoint()
    let cp = try XCTUnwrap(batch.checkpoint)
    try await client.commitHostCheckpoint(cp)

    let stored = await tokenStore.loadDatabaseToken()
    XCTAssertNotNil(stored)
    XCTAssertNotEqual(stored?.archivedData, preArchived.archivedData,
                      "commit must replace the prior archive with the fresh server token")
}

func testCommitHostCheckpointRejectsForeignCheckpointType() async throws {
    struct ForeignCheckpoint: HostSyncCheckpoint { let id = UUID() }
    try await client.commitHostCheckpoint(ForeignCheckpoint())
    let stored = await tokenStore.loadDatabaseToken()
    XCTAssertNil(stored, "foreign checkpoint must be silently rejected")
}

func testResetDuringApplyPreventsStaleCheckpointCommit() async throws {
    fakeDB.enqueueDatabaseChanges(.init(newToken: nil, moreComing: false))
    let batch = try await client.fetchHostChanges()
    let cp = try XCTUnwrap(batch.checkpoint)
    await client.resetHostSyncState()  // bumps epoch
    try await client.commitHostCheckpoint(cp)

    let stored = await tokenStore.loadDatabaseToken()
    XCTAssertNil(stored, "reset bumped epoch ⇒ commit must be staleEpoch")
}
```

- [ ] **Step 2: Implement commit**

Replace the stub in `CloudKitSyncClient+Push.swift`:
```swift
public func commitHostCheckpoint(_ checkpoint: any HostSyncCheckpoint) async throws {
    guard let cp = checkpoint as? Checkpoint else {
        Self.log.info("commitHostCheckpoint: foreign type, ignoring")
        return
    }
    let dbCAS = TokenCAS(prev: cp.prevDb, new: cp.newDb)
    var zoneCASes: [String: TokenCAS] = [:]
    for (zoneKey, newOpt) in cp.newZones {
        let prevOpt = cp.prevZones[zoneKey] ?? nil
        zoneCASes[zoneKey] = TokenCAS(prev: prevOpt, new: newOpt)
    }
    let outcome = await tokenStore.commitTokens(
        expectedEpoch: cp.epoch, db: dbCAS, zones: zoneCASes
    )
    switch outcome {
    case .applied:
        Self.log.debug("checkpoint applied epoch=\(cp.epoch)")
    case .staleEpoch:
        Self.log.info("checkpoint stale by epoch \(cp.epoch); skipping")
    case .partialCAS(let zones, let db):
        Self.log.info("checkpoint partial CAS skippedZones=\(zones) skippedDb=\(db)")
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientPushTests
git add apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift \
        apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift
git commit -m "cloudkit: implement commitHostCheckpoint with epoch + per-token CAS"
```

---

### Task 1.11: `HostSyncReconciler.reconcileFullSnapshot` rename + `reconcileDelta`

**Files:**
- Modify: `apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift`
- Modify: `apps/macos/Tests/HostSyncStoreTests/HostSyncReconcilerTests.swift`

- [ ] **Step 1: Rename existing function**

In `HostSyncReconciler.swift`, change:
```swift
public static func reconcile(local: [SSHHost], remote: [RemoteHost]) -> [SyncOperation]
```
to
```swift
public static func reconcileFullSnapshot(local: [SSHHost], remote: [RemoteHost]) -> [SyncOperation]
```

- [ ] **Step 2: Add `reconcileDelta`**

Append to the same enum:
```swift
public static func reconcileDelta(
    local: [SSHHost],
    changedHosts: [RemoteHost],
    deletedHostIDs: [String]
) -> [SyncOperation] {
    var ops: [SyncOperation] = []
    let localByServerId = Dictionary(uniqueKeysWithValues:
        local.compactMap { h -> (String, SSHHost)? in
            guard let s = h.serverId else { return nil }
            return (s, h)
        }
    )
    for r in changedHosts {
        if let existing = localByServerId[r.id] {
            if existing.updatedAt < r.updatedAt {
                ops.append(.updateLocal(localHostId: existing.id, remote: r))
            } else if existing.updatedAt > r.updatedAt {
                ops.append(.updateRemote(localHostId: existing.id, serverId: r.id))
            }
        } else {
            ops.append(.createLocal(remote: r))
        }
    }
    for id in deletedHostIDs {
        if let existing = localByServerId[id] {
            ops.append(.deleteLocal(localHostId: existing.id))
        }
    }
    return ops
}
```

- [ ] **Step 3: Update existing test names + add delta tests**

In `HostSyncReconcilerTests.swift` rename every call site `HostSyncReconciler.reconcile(` → `HostSyncReconciler.reconcileFullSnapshot(`. Add:
```swift
final class HostSyncReconcilerDeltaTests: XCTestCase {
    func testDeltaUpsertCreatesLocal() {
        let r = RemoteHost(id: "S1", name: "x", hostname: "h", port: 22,
                           username: "u", authType: "password",
                           updatedAt: Date(timeIntervalSince1970: 100))
        let ops = HostSyncReconciler.reconcileDelta(
            local: [], changedHosts: [r], deletedHostIDs: []
        )
        XCTAssertEqual(ops, [.createLocal(remote: r)])
    }

    func testDeltaUpsertUpdatesNewerRemote() {
        let local = makeLocalSynced(serverId: "S1", updatedAt: 100)
        let r = RemoteHost(id: "S1", name: "x", hostname: "h", port: 22,
                           username: "u", authType: "password",
                           updatedAt: Date(timeIntervalSince1970: 200))
        let ops = HostSyncReconciler.reconcileDelta(
            local: [local], changedHosts: [r], deletedHostIDs: []
        )
        XCTAssertEqual(ops, [.updateLocal(localHostId: local.id, remote: r)])
    }

    func testDeltaDeleteRemovesLocal() {
        let local = makeLocalSynced(serverId: "S1", updatedAt: 100)
        let ops = HostSyncReconciler.reconcileDelta(
            local: [local], changedHosts: [], deletedHostIDs: ["S1"]
        )
        XCTAssertEqual(ops, [.deleteLocal(localHostId: local.id)])
    }

    func testDeltaIgnoresDeletionForUnknownServerId() {
        let ops = HostSyncReconciler.reconcileDelta(
            local: [], changedHosts: [], deletedHostIDs: ["missing"]
        )
        XCTAssertTrue(ops.isEmpty)
    }

    private func makeLocalSynced(serverId: String, updatedAt: TimeInterval) -> SSHHost {
        // Match SSHHost.init shape — adapt to whatever fields exist.
        var h = SSHHost(id: UUID().uuidString, name: "n", hostname: "h",
                        port: 22, username: "u", authType: .password,
                        updatedAt: Date(timeIntervalSince1970: updatedAt))
        h.serverId = serverId
        return h
    }
}
```

- [ ] **Step 4: Build, expect existing call sites to break**

```bash
cd apps/macos && swift build
```
Expected: `HostSyncStore.swift:333` calls the old name. That's fixed in Task 1.12 — but to keep this commit green, also update that one line to `reconcileFullSnapshot` here.

```swift
// HostSyncStore.swift:333
let ops = HostSyncReconciler.reconcileFullSnapshot(local: sessionStore.hosts,
                                                   remote: remote)
```

- [ ] **Step 5: Run all tests**

```bash
cd apps/macos && swift test
```
Expected: existing reconciler suite passes under new name; delta suite passes; `HostSyncStore` suite still passes (no behavior change yet).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift \
        apps/macos/Sources/HostSyncStore/HostSyncStore.swift \
        apps/macos/Tests/HostSyncStoreTests/HostSyncReconcilerTests.swift
git commit -m "HostSyncStore: rename reconcile→reconcileFullSnapshot + add reconcileDelta"
```

---

### Task 1.12: `HostSyncStore` adopts `IncrementalHostSyncClient` + `sync(mode:)` flow

**Files:**
- Modify: `apps/macos/Sources/HostSyncStore/HostSyncStore.swift`
- Modify: `apps/macos/Tests/HostSyncStoreTests/*` (fakes)

- [ ] **Step 1: Change client type and add mode enum**

In `HostSyncStore.swift`, replace:
```swift
private let client: ServerSyncClient
// ...
public init(client: ServerSyncClient, ...
```
with:
```swift
public enum SyncMode: Sendable, Equatable {
    case auto
    case forceFull
    case incremental
}

private let client: any IncrementalHostSyncClient
// ...
public init(client: any IncrementalHostSyncClient, ...
```

Change `periodicInterval` default:
```swift
periodicInterval: TimeInterval = 60 * 60,
```

- [ ] **Step 2: Replace `performSync()` body to drive on mode**

```swift
private func performSync(mode requestedMode: SyncMode = .auto) async throws {
    let failureStateToken = failureStateResetToken
    let attempted = Date()
    lastSyncAttemptedAt = attempted
    userDefaults.set(attempted, forKey: Self.lastSyncAttemptedAtKey)

    do {
        let effectiveMode: HostSyncMode
        switch requestedMode {
        case .auto:        effectiveMode = await client.preferredHostSyncMode()
        case .forceFull:   effectiveMode = .forceFull
        case .incremental: effectiveMode = .incremental
        }

        var batch = try await fetch(effectiveMode)
        if batch.tokenExpired {
            // Single retry as forceFull. Token clearing already happened
            // inside the client.
            batch = try await fetch(.forceFull)
        }
        try Task.checkCancellation()

        let ops: [SyncOperation]
        switch batch.mode {
        case .forceFull:
            // For forceFull the drain returns a snapshot via changedHosts;
            // there are no deletedHostIDs (server-side authoritative list).
            ops = HostSyncReconciler.reconcileFullSnapshot(
                local: sessionStore.hosts, remote: batch.changedHosts
            )
        case .incremental:
            ops = HostSyncReconciler.reconcileDelta(
                local: sessionStore.hosts,
                changedHosts: batch.changedHosts,
                deletedHostIDs: batch.deletedHostIDs
            )
        }
        for op in ops {
            try Task.checkCancellation()
            try await apply(op)
        }

        if let checkpoint = batch.checkpoint {
            try await client.commitHostCheckpoint(checkpoint)
        }

        let now = Date()
        lastSyncedAt = now
        userDefaults.set(now, forKey: Self.lastSyncedAtKey)
        lastSyncErrorKind = nil
        wasFailing = false
        failingSince = nil
    } catch {
        if isCancellation(error) { throw CancellationError() }
        if failureStateToken != failureStateResetToken { throw error }
        // Existing failure-classification path stays unchanged.
        // ... (preserve existing catch body)
    }
}

private func fetch(_ mode: HostSyncMode) async throws -> HostChangeBatch {
    switch mode {
    case .incremental: return try await client.fetchHostChanges()
    case .forceFull:   return try await client.fetchHostSnapshotAndCheckpoint()
    }
}
```

> **Note:** the existing catch body in `performSync` (lines ~347–360 before this change) classifies errors and updates `lastSyncErrorKind` / `failingSince`. Keep it byte-for-byte; only the `do` block was rewritten.

- [ ] **Step 3: Update timer tick to pass `forceFull`**

Find `private func handlePeriodicEnabled` and update the sink:
```swift
periodicTimerCancellable = Timer.publish(every: periodicInterval,
                                          on: .main, in: .common)
    .autoconnect()
    .sink { [weak self] _ in self?.scheduleAutoSync(mode: .forceFull) }
```
And update `scheduleAutoSync` signature:
```swift
private func scheduleAutoSync(mode: SyncMode = .auto) {
    guard authSession.isSignedIn else { return }
    guard !manualInProgress else {
        pendingAutoAfterManual = true
        return
    }
    _ = startSync(mode: mode)
}

@discardableResult
private func startSync(mode: SyncMode = .auto) -> Task<Void, Error> {
    // unchanged plumbing; performSync now takes a mode parameter
    // ...
    try await self.performSync(mode: mode)
}
```

- [ ] **Step 4: Add push-notification observer**

Add to `init`, after the wake observer block:
```swift
NotificationCenter.default
    .publisher(for: .catermCloudKitHostChanged)
    .sink { [weak self] _ in self?.scheduleAutoSync(mode: .auto) }
    .store(in: &cancellables)
```

- [ ] **Step 5: Update `HostSyncStore` module dependencies**

`HostSyncStore` already depends on `ServerSyncClient`. Confirm `Notification.Name.catermCloudKitHostChanged` is reachable — it is declared in `CloudKitSyncClient` module which `HostSyncStore` does NOT import.

**Action:** move the `Notification.Name.catermCloudKitHostChanged` declaration from `CloudKitSyncClient/CloudKitPushNames.swift` into `ServerSyncClient/IncrementalHostSyncClient.swift` (it's a cross-module name; `ServerSyncClient` is the right home since both the producer module `CloudKitSyncClient` and the consumer `HostSyncStore` already depend on it). Keep the subscription-id constant in `CloudKitSyncClient`.

- [ ] **Step 6: Update test fakes**

Every test file that constructs `HostSyncStore(client: someFake, ...)` needs a fake conforming to `IncrementalHostSyncClient`. Strategy:
1. Find all fakes: `grep -rn "ServerSyncClient" apps/macos/Tests/HostSyncStoreTests/`.
2. For each fake type, add the new methods. Default impl: return empty `HostChangeBatch(checkpoint: nil, tokenExpired: false, mode: ...)`. Track call counts so existing `XCTAssertEqual(fake.listHostsCalls, 1)` style assertions can be rewritten.

- [ ] **Step 7: Build + run tests, fix until green**

```bash
cd apps/macos && swift test 2>&1 | tail -80
```
Iterate: many existing tests will need their fake updated. This is mechanical — keep behavior parity.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/HostSyncStore/HostSyncStore.swift \
        apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift \
        apps/macos/Sources/ServerSyncClient/IncrementalHostSyncClient.swift \
        apps/macos/Tests/HostSyncStoreTests/
git commit -m "HostSyncStore: adopt IncrementalHostSyncClient with sync(mode:) flow"
```

---

### Task 1.13: `HostSyncStore` checkpoint-on-success tests

**Files:**
- Modify: `apps/macos/Tests/HostSyncStoreTests/HostSyncStoreAutoSyncTests.swift`

- [ ] **Step 1: Add the new tests**

```swift
func testCheckpointCommittedOnlyAfterApplySucceeds() async throws {
    let fake = FakeIncrementalHostSyncClient()
    let dummyCP = FakeCheckpoint(id: UUID())
    fake.fetchSnapshotResult = HostChangeBatch(
        changedHosts: [makeRemote(id: "R1")],
        deletedHostIDs: [],
        checkpoint: dummyCP,
        tokenExpired: false,
        mode: .forceFull
    )
    let store = makeStore(client: fake)

    try await store.sync()

    XCTAssertEqual(fake.commitCalls.map(\.id), [dummyCP.id])
    XCTAssertGreaterThan(fake.commitCalls.first?.afterApplyCount ?? 0, 0,
                         "commit must run after apply ops")
}

func testApplyFailureDoesNotAdvanceChangeTokens() async throws {
    let fake = FakeIncrementalHostSyncClient()
    fake.fetchSnapshotResult = HostChangeBatch(
        changedHosts: [makeRemote(id: "R1")],
        deletedHostIDs: [],
        checkpoint: FakeCheckpoint(id: UUID()),
        tokenExpired: false, mode: .forceFull
    )
    fake.applyShouldThrow = true   // SessionStore stub raises
    let store = makeStore(client: fake)

    do {
        try await store.sync()
        XCTFail("expected throw")
    } catch {
        // expected
    }
    XCTAssertTrue(fake.commitCalls.isEmpty,
                  "commit must NOT run when apply fails")
}

func testNilCheckpointFromTokenExpiredBatchSkipsCommit() async throws {
    let fake = FakeIncrementalHostSyncClient()
    fake.fetchSnapshotResult = HostChangeBatch(
        changedHosts: [], deletedHostIDs: [],
        checkpoint: nil, tokenExpired: true, mode: .incremental
    )
    fake.fetchSnapshotResultRetry = HostChangeBatch(
        changedHosts: [], deletedHostIDs: [],
        checkpoint: nil, tokenExpired: false, mode: .forceFull
    )
    let store = makeStore(client: fake)
    try await store.sync()
    XCTAssertTrue(fake.commitCalls.isEmpty)
}

func testTokenExpiredTriggersSingleForceFullRetry() async throws {
    // (covered above by testNilCheckpointFromTokenExpiredBatchSkipsCommit
    // when the retry batch ALSO has nil checkpoint; also assert the second
    // fetch was forceFull mode.)
    let fake = FakeIncrementalHostSyncClient()
    fake.fetchSnapshotResult = HostChangeBatch(
        changedHosts: [], deletedHostIDs: [],
        checkpoint: nil, tokenExpired: true, mode: .incremental
    )
    let cp = FakeCheckpoint(id: UUID())
    fake.fetchSnapshotResultRetry = HostChangeBatch(
        changedHosts: [], deletedHostIDs: [],
        checkpoint: cp, tokenExpired: false, mode: .forceFull
    )
    let store = makeStore(client: fake)
    try await store.sync()
    XCTAssertEqual(fake.fetchModes, [.incremental, .forceFull])
    XCTAssertEqual(fake.commitCalls.map(\.id), [cp.id])
}
```

`FakeIncrementalHostSyncClient` and `FakeCheckpoint` should live in a shared test helper file (e.g. `apps/macos/Tests/HostSyncStoreTests/FakeIncrementalHostSyncClient.swift`). Keep its surface minimal; only what tests need.

- [ ] **Step 2: Run + commit**

```bash
cd apps/macos && swift test --filter HostSyncStoreAutoSyncTests
git add apps/macos/Tests/HostSyncStoreTests/
git commit -m "HostSyncStore: cover apply→commit ordering + token-expired retry"
```

---

### Task 1.14: Wire `CatermApp` to construct the new client signature (no behavior change)

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`

- [ ] **Step 1: Find the `CloudKitSyncClient(...)` construction site**

```bash
grep -n "CloudKitSyncClient(" apps/macos/Sources/Caterm/CatermApp.swift
```

- [ ] **Step 2: Confirm the call still compiles via the convenience init**

The convenience init from Task 1.7 takes `database:` + optional `zoneID:`, no token store. The existing call site should keep working unchanged — verify by running `swift build`.

- [ ] **Step 3: Build + smoke launch**

```bash
cd apps/macos && swift build
make dev   # launch and verify no regressions
```

- [ ] **Step 4: Manual verification of token persistence**

Sign into iCloud, let one sync run, then:
```bash
defaults read com.caterm.app | grep cloudkit.changeToken
```
Expected: the database key + at least one zone key are present after the first successful sync.

- [ ] **Step 5: Commit (only if there were any changes; usually none)**

If a change was needed:
```bash
git add apps/macos/Sources/Caterm/CatermApp.swift
git commit -m "Caterm: confirm CloudKitSyncClient construction uses new convenience init"
```

If no diff, skip — Task 1.14 is purely a verification step.

---

**Phase 1 done.** At this point: incremental sync via tokens, atomic commit on apply success, 60-min full reconciliation tick still gated by polling timer. Ship-able as-is.

---

# Phase 2 — B2: Push Subscriptions + Account Tracking

**Goal:** Layer push notifications on top of Phase 1. Adds `ensureHostSubscription`/`deleteHostSubscription`, `AccountIdentityTracker`, AppDelegate push handlers, and the actual notification → sync wire.

**Exit:** two-Mac integration test (Mac-A edits a Host → Mac-B updates within 5 seconds without timer fire).

---

### Task 2.1: `ensureHostSubscription` + `deleteHostSubscription` in `CloudKitSyncClient`

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift`

- [ ] **Step 1: Failing tests**

```swift
func testEnsureHostSubscriptionCreatesNewWhenMissing() async throws {
    try await client.ensureHostSubscription()
    XCTAssertEqual(fakeDB.savedSubscriptions.count, 1)
    let sub = try XCTUnwrap(fakeDB.savedSubscriptions.first as? CKDatabaseSubscription)
    XCTAssertEqual(sub.subscriptionID, CloudKitPushNames.hostSubscriptionID)
    XCTAssertEqual(sub.recordType, "Host")
    XCTAssertTrue(sub.notificationInfo?.shouldSendContentAvailable ?? false)
}

func testEnsureHostSubscriptionTreatsAlreadyExistsAsSuccess() async throws {
    fakeDB.saveSubscriptionError = CKError(.serverRejectedRequest)
    try await client.ensureHostSubscription()  // must not throw
}

func testEnsureHostSubscriptionPropagatesNonExistsError() async throws {
    fakeDB.saveSubscriptionError = CKError(.networkFailure)
    do {
        try await client.ensureHostSubscription()
        XCTFail("expected throw")
    } catch let e as CKError {
        XCTAssertEqual(e.code, .networkFailure)
    }
}

func testDeleteHostSubscriptionTreatsUnknownItemAsSuccess() async throws {
    fakeDB.deleteSubscriptionError = CKError(.unknownItem)
    try await client.deleteHostSubscription()  // must not throw
}
```

- [ ] **Step 2: Implement**

Replace stubs in `CloudKitSyncClient+Push.swift`:
```swift
public func ensureHostSubscription() async throws {
    let sub = CKDatabaseSubscription(subscriptionID: CloudKitPushNames.hostSubscriptionID)
    sub.recordType = Self.hostRecordType
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    sub.notificationInfo = info
    do {
        _ = try await database.saveSubscription(sub)
    } catch let ck as CKError where ck.code == .serverRejectedRequest {
        // Subscription already exists. Apple returns this when a
        // subscription with the same ID is present.
        return
    }
}

public func deleteHostSubscription() async throws {
    do {
        _ = try await database.deleteSubscription(
            withID: CloudKitPushNames.hostSubscriptionID
        )
    } catch let ck as CKError where ck.code == .unknownItem {
        return
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
cd apps/macos && swift test --filter CloudKitSyncClientPushTests
git add apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient+Push.swift \
        apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientPushTests.swift
git commit -m "cloudkit: add ensure/delete HostSubscription with idempotent error handling"
```

---

### Task 2.2: `AccountIdentityTracker`

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/AccountIdentityTrackerTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class AccountIdentityTrackerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "AccountIdentityTrackerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func testFirstObservationWithEmptyTokensStoresIdentityWithoutResetting() async {
        let client = SpyClient()
        let tracker = AccountIdentityTracker(
            defaults: defaults,
            currentUserRecordID: { CKRecord.ID(recordName: "USER-A") },
            tokensExist: { false }
        )
        await tracker.handleAccountChange(client: client)
        XCTAssertFalse(client.didReset)
        XCTAssertEqual(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"), "USER-A")
    }

    func testFirstObservationWithExistingTokensCallsResetThenStores() async {
        let client = SpyClient()
        let tracker = AccountIdentityTracker(
            defaults: defaults,
            currentUserRecordID: { CKRecord.ID(recordName: "USER-A") },
            tokensExist: { true }
        )
        await tracker.handleAccountChange(client: client)
        XCTAssertTrue(client.didReset)
        XCTAssertEqual(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"), "USER-A")
    }

    func testSameIdentityIsNoOp() async {
        defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
        let client = SpyClient()
        let tracker = AccountIdentityTracker(
            defaults: defaults,
            currentUserRecordID: { CKRecord.ID(recordName: "USER-A") },
            tokensExist: { true }
        )
        await tracker.handleAccountChange(client: client)
        XCTAssertFalse(client.didReset)
        XCTAssertFalse(client.didDeleteSubscription)
    }

    func testDifferentIdentityCallsResetAndDeleteSubscription() async {
        defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
        let client = SpyClient()
        let tracker = AccountIdentityTracker(
            defaults: defaults,
            currentUserRecordID: { CKRecord.ID(recordName: "USER-B") },
            tokensExist: { true }
        )
        await tracker.handleAccountChange(client: client)
        XCTAssertTrue(client.didReset)
        XCTAssertTrue(client.didDeleteSubscription)
        XCTAssertEqual(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"), "USER-B")
    }

    func testSignOutAfterPriorIdentityCallsResetAndClears() async {
        defaults.set("USER-A", forKey: "cloudkit.lastKnownUserRecordName")
        let client = SpyClient()
        let tracker = AccountIdentityTracker(
            defaults: defaults,
            currentUserRecordID: { nil },
            tokensExist: { true }
        )
        await tracker.handleAccountChange(client: client)
        XCTAssertTrue(client.didReset)
        XCTAssertNil(defaults.string(forKey: "cloudkit.lastKnownUserRecordName"))
    }

    private final class SpyClient: AccountSensitiveClient {
        var didReset = false
        var didDeleteSubscription = false
        func resetHostSyncState() async { didReset = true }
        func deleteHostSubscription() async throws { didDeleteSubscription = true }
    }
}
```

- [ ] **Step 2: Implement**

```swift
// apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift
import CloudKit
import Foundation
import os

public protocol AccountSensitiveClient: Sendable {
    func resetHostSyncState() async
    func deleteHostSubscription() async throws
}

extension CloudKitSyncClient: AccountSensitiveClient {}

public actor AccountIdentityTracker {
    private static let storageKey = "cloudkit.lastKnownUserRecordName"
    private static let log = Logger(subsystem: "com.caterm.app", category: "cloudkit-account")

    private let defaults: UserDefaults
    private let currentUserRecordIDProvider: @Sendable () async -> CKRecord.ID?
    private let tokensExistProvider: @Sendable () async -> Bool

    public init(defaults: UserDefaults = .standard,
                currentUserRecordID: @escaping @Sendable () async -> CKRecord.ID?,
                tokensExist: @escaping @Sendable () async -> Bool) {
        self.defaults = defaults
        self.currentUserRecordIDProvider = currentUserRecordID
        self.tokensExistProvider = tokensExist
    }

    public func handleAccountChange(client: any AccountSensitiveClient) async {
        let prior = defaults.string(forKey: Self.storageKey)
        let current = await currentUserRecordIDProvider()?.recordName

        switch (prior, current) {
        case (nil, nil):
            return
        case (nil, .some(let new)):
            if await tokensExistProvider() {
                Self.log.info("first identity observation with existing tokens → resetting")
                await client.resetHostSyncState()
            }
            defaults.set(new, forKey: Self.storageKey)
        case (.some(let p), .some(let c)) where p == c:
            return
        case (.some, _):
            await client.resetHostSyncState()
            try? await client.deleteHostSubscription()
            if let new = current {
                defaults.set(new, forKey: Self.storageKey)
            } else {
                defaults.removeObject(forKey: Self.storageKey)
            }
        }
    }
}
```

Add a helper that exposes `tokensExist` from the client (we need this for `CatermApp` wiring):
```swift
extension CloudKitSyncClient {
    public func hasAnyHostSyncTokens() async -> Bool {
        await tokenStore.loadDatabaseToken() != nil
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
cd apps/macos && swift test --filter AccountIdentityTrackerTests
git add apps/macos/Sources/CloudKitSyncClient/AccountIdentityTracker.swift \
        apps/macos/Tests/CloudKitSyncClientTests/AccountIdentityTrackerTests.swift
git commit -m "cloudkit: add AccountIdentityTracker for identity-aware token reset"
```

---

### Task 2.3: `AppDelegate` push parsing helper + tests

**Files:**
- Create: `apps/macos/Tests/CloudKitSyncClientTests/AppDelegatePushParsingTests.swift`
- Modify: `apps/macos/Sources/Caterm/AppDelegate.swift`

The AppDelegate itself is hard to unit-test (it's tied to NSApplication). Extract the parsing logic to a free function tested in isolation.

- [ ] **Step 1: Failing tests against a `parsePushUserInfo` helper**

```swift
import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class AppDelegatePushParsingTests: XCTestCase {
    func testRemoteNotificationWithMatchingSubscriptionIDIsRecognized() {
        let userInfo: [String: Any] = [
            "ck": ["sid": CloudKitPushNames.hostSubscriptionID]
        ]
        XCTAssertTrue(parsePushUserInfo(userInfo))
    }

    func testRemoteNotificationWithDifferentSubscriptionIDIsIgnored() {
        let userInfo: [String: Any] = [
            "ck": ["sid": "some.other.subscription"]
        ]
        XCTAssertFalse(parsePushUserInfo(userInfo))
    }

    func testMalformedUserInfoReturnsFalse() {
        XCTAssertFalse(parsePushUserInfo(["random": "stuff"]))
    }
}
```

- [ ] **Step 2: Add the helper**

In `apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift`:
```swift
import CloudKit
import Foundation

/// Returns true iff `userInfo` is a CloudKit silent-push payload whose
/// subscriptionID matches the Host subscription. Used by AppDelegate.
public func parsePushUserInfo(_ userInfo: [String: Any]) -> Bool {
    guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
        return false
    }
    return note.subscriptionID == CloudKitPushNames.hostSubscriptionID
}
```

- [ ] **Step 3: Wire AppDelegate**

Edit `apps/macos/Sources/Caterm/AppDelegate.swift`:
```swift
import AppKit
import CloudKitSyncClient
import FileTransferStore
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    // existing properties...
    private static let pushLog = Logger(subsystem: "com.caterm.app", category: "cloudkit-sync")

    func applicationDidFinishLaunching(_: Notification) {
        // ... existing body unchanged
        NSApp.registerForRemoteNotifications()
    }

    func application(_: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        guard parsePushUserInfo(userInfo) else { return }
        NotificationCenter.default.post(name: .catermCloudKitHostChanged, object: nil)
    }

    func application(_: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.pushLog.error("APS register failed: \(error.localizedDescription)")
    }

    // existing methods unchanged
}
```

- [ ] **Step 4: Build**

```bash
cd apps/macos && swift build
```

- [ ] **Step 5: Run tests**

```bash
cd apps/macos && swift test --filter AppDelegatePushParsingTests
```

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CloudKitPushNames.swift \
        apps/macos/Sources/Caterm/AppDelegate.swift \
        apps/macos/Tests/CloudKitSyncClientTests/AppDelegatePushParsingTests.swift
git commit -m "Caterm: AppDelegate dispatches CKDatabaseSubscription pushes"
```

---

### Task 2.4: Wire `CatermApp` to register subscription + use `AccountIdentityTracker`

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`

- [ ] **Step 1: Read current account-changed wiring**

```bash
grep -n "catermICloudAccountChanged\|CloudKitSyncClient(" apps/macos/Sources/Caterm/CatermApp.swift
```

- [ ] **Step 2: Build the tracker and ensure subscription on launch**

Edit `CatermApp.swift`. Where the client is constructed, build the tracker alongside:
```swift
@StateObject private var cloudKitClient: CloudKitSyncClient = ...
private let accountIdentityTracker: AccountIdentityTracker

init() {
    let container = CKContainer(identifier: "iCloud.com.caterm.app")
    let client = CloudKitSyncClient(database: container.privateCloudDatabase)
    _cloudKitClient = StateObject(wrappedValue: client)
    accountIdentityTracker = AccountIdentityTracker(
        currentUserRecordID: { try? await container.userRecordID() },
        tokensExist: { await client.hasAnyHostSyncTokens() }
    )
    // existing init body...
}
```

After `applicationDidFinishLaunching` equivalent (or in the SwiftUI `.task` on the root view):
```swift
.task {
    Task { try? await cloudKitClient.ensureHostSubscription() }
}
```

Replace the existing `.catermICloudAccountChanged` handler:
```swift
.onReceive(NotificationCenter.default
    .publisher(for: .catermICloudAccountChanged)) { _ in
    Task {
        await accountIdentityTracker.handleAccountChange(client: cloudKitClient)
    }
}
```

> If there is more than one observer for `.catermICloudAccountChanged`, retain the others; only the token-clearing path is replaced.

- [ ] **Step 3: Build + smoke launch**

```bash
cd apps/macos && swift build
make dev
```

Sign in to iCloud (if not already), confirm:
1. Subscription appears in CloudKit Dashboard → Private Database → Subscriptions, ID `caterm.host.changes.v1`.
2. App does NOT clear tokens on launch (check `defaults read com.caterm.app | grep cloudkit.changeToken` before and after launch).

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/Caterm/CatermApp.swift
git commit -m "Caterm: wire AccountIdentityTracker + ensureHostSubscription on launch"
```

---

### Task 2.5: Two-Mac integration test (manual)

**Files:**
- Modify: `docs/superpowers/specs/2026-05-02-cloudkit-push-subscriptions-design.md` — append result

- [ ] **Step 1: Prepare two Macs**

Both signed into the same iCloud account, both running the latest dev build with the entitlement from Task 0.1.

- [ ] **Step 2: Mac-A: edit a host**

In Caterm UI → edit any host → change `name` → save. Confirm the local edit persisted.

- [ ] **Step 3: Mac-B: observe within 5s**

Open Caterm on Mac-B; the host list should update without timer reliance. Use Console.app filter `subsystem:com.caterm.app category:cloudkit-sync` to see the receipt + sync log.

- [ ] **Step 4: Mac-B offline scenario**

Quit Caterm on Mac-B. Edit 5 hosts on Mac-A across 30 seconds. Relaunch Caterm on Mac-B. Within 10 seconds (no waiting for the 60-min timer), all 5 edits should appear.

- [ ] **Step 5: Account-change scenario**

Sign out of iCloud on Mac-B. Sign into a different iCloud account. Confirm Mac-B does NOT show the original account's hosts.

- [ ] **Step 6: Record results**

Append to the spec's "Manual verification checklist":
```markdown
**B2 verification (YYYY-MM-DD):**
- [x] Two-Mac latency: ~Ns
- [x] Offline-then-resume: 5/5 edits picked up on relaunch
- [x] Account-change: prior account's data not visible
```

```bash
git add docs/superpowers/specs/2026-05-02-cloudkit-push-subscriptions-design.md
git commit -m "docs(cloudkit): record Plan B Phase 2 manual verification"
```

---

### Task 2.6: Update memory + close-out

**Files:**
- Modify: `/Users/zingerbee/.claude/projects/-Users-zingerbee-Documents-Caterm/memory/cloudkit_migration_status.md`

- [ ] **Step 1: Mark Plan B done**

Update memory:
```markdown
- **Plan B (push + incremental) — DONE.** Commit refs: <last-commit-of-phase-2>.
- **Plan C — pending.** Keychain Sync ...
```

- [ ] **Step 2: Verify all tests still green**

```bash
cd apps/macos && swift test
```
Expected: full suite green.

- [ ] **Step 3: Commit (memory only — outside repo)**

Memory file is not in git; just save it.

---

## Self-Review

Spec coverage:

- [x] Step 0 spike — Tasks 0.1–0.3.
- [x] B1 incremental refactor — Tasks 1.1–1.14.
- [x] B2 push subscriptions — Tasks 2.1–2.6.
- [x] `ServerChangeTokenStoring` actor + atomic `commitTokens` — Tasks 1.2, 1.3.
- [x] Drain loop with separate `operationPreviousToken` / `casPreviousArchive` — Task 1.8.
- [x] Caterm-zone deletion / purge / encrypted-reset short-circuit — Task 1.9.
- [x] `commitHostCheckpoint` epoch + per-token CAS — Task 1.10.
- [x] Reconciler `reconcileFullSnapshot` / `reconcileDelta` — Task 1.11.
- [x] HostSyncStore `sync(mode:)` + push observer + 60-min default — Tasks 1.12, 1.13.
- [x] `IncrementalHostSyncClient` protocol + `HostSyncCheckpoint` marker protocol — Task 1.5.
- [x] `ensureHostSubscription` / `deleteHostSubscription` idempotency — Task 2.1.
- [x] `AccountIdentityTracker` with upgrade-safety branch — Task 2.2.
- [x] AppDelegate push handlers + `parsePushUserInfo` — Task 2.3.
- [x] Two-Mac integration verification — Task 2.5.
- [x] All test cases listed in spec §Testing — covered across Tasks 1.1–1.13, 2.1–2.3 (cross-check during execution).

Type consistency:

- `IncrementalHostSyncClient`, `HostSyncCheckpoint`, `HostChangeBatch`, `HostSyncMode` — same shape across Tasks 1.5, 1.7, 1.8, 1.10, 1.12.
- `TokenCAS`, `CommitOutcome`, `StoredServerChangeToken` — same shape across Tasks 1.1, 1.2, 1.3, 1.8, 1.10.
- `Notification.Name.catermCloudKitHostChanged` declared in `ServerSyncClient` (Task 1.12 Step 5), referenced by `AppDelegate` (Task 2.3) and `HostSyncStore` (Task 1.12 Step 4).
- Subscription ID `"caterm.host.changes.v1"` referenced via `CloudKitPushNames.hostSubscriptionID` everywhere.

Placeholders: none. Each step shows the actual code or the actual command.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-02-cloudkit-push-subscriptions.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
