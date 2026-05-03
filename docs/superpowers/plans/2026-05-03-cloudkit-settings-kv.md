# Plan D — CloudKit Settings KV Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync the user-facing portion of `CatermSettings` (terminal preferences + per-host overrides) across the user's iCloud-signed-in Macs via `NSUbiquitousKeyValueStore`. Per-device filesystem migration markers (`migrationsCompleted`) stay local.

**Architecture:** Single-blob doc-level revision LWW under one KVS key (`caterm.settings.v1`). A `SyncableSettings` projection strips local-only fields. Composite `isDefaultSeedUnedited` predicate guarantees default seeds never overwrite real cloud data and pure defaults never push up. Identity isolation enforced via persisted `ubiquityIdentityToken` classification (notSignedIn / firstObservation / identitySame / identityChanged / unknownPrevious); cross-identity transitions force-apply cloud Y (no LWW). Apple's `.initialSyncChange` is treated as a write barrier — pushSuspended stays true through a 500ms grace backoff. `Decision` values returned by `BootstrapDecider` and `AccountSwitchHandler` carry both `finalSuspensionState` and `acceptIdentity`; the dispatcher honors both, gating token persistence on whether the outcome actually committed to the new identity.

**Tech Stack:** Swift 5.10, Foundation (`NSUbiquitousKeyValueStore`, `FileManager.ubiquityIdentityToken`, `NSKeyedArchiver`), CryptoKit (SHA-256 for canonical hashes), CloudKit (only `iCloudAccountSession` from Plan A — no new entitlements), SwiftPM, XCTest.

**Spec:** [docs/superpowers/specs/2026-05-03-cloudkit-settings-kv-design.md](../specs/2026-05-03-cloudkit-settings-kv-design.md)

**Predecessors:** Plan A (host sync, complete) and Plan C (credential sync, complete) — both in PR #15. Plan A provides `iCloudAccountSession` and the `.catermICloudAccountChanged` notification reused here.

---

## File structure

### New module

| Module | Purpose |
|--------|---------|
| `apps/macos/Sources/SettingsSyncStore/` | KVS-backed settings sync coordinator. Depends on `SettingsStore` + Foundation/CloudKit. |
| `apps/macos/Tests/SettingsSyncStoreTests/` | Unit + integration tests. |

### New files inside `apps/macos/Sources/SettingsSyncStore/`

| File | Responsibility |
|------|---------------|
| `SettingsSyncStore.swift` | `@MainActor` coordinator; `installLifecycleObservers`/`startSync`/`stopSync`; classifier-then-handler dispatch; control-plane vs observer-plane push split. |
| `Decision.swift` | `Decision` struct (`finalSuspensionState: Bool`, `acceptIdentity: Bool`, `action: Action` enum). |
| `BootstrapDecider.swift` | Pure function; (local, cloud) → `Decision`. |
| `AccountSwitchHandler.swift` | Pure function; (local, cloudY) → `Decision`. Returns `.suspendUntilFirstEdit` / `.forceApply` / `.rejectMerge`. |
| `IsDefaultSeedUnedited.swift` | Composite predicate. |
| `KnownSeedTable.swift` | Append-only historical default seeds. |
| `KVSAdapter.swift` | `KVSProtocol` + `NSUbiquitousKeyValueStore` impl + reason classifier. |
| `IdentityTokenStore.swift` | `NSKeyedArchiver(requiringSecureCoding: false)` archive/unarchive; sentinel `<archive-failed>` fallback; UserDefaults plumbing; `isEqual(_:)` compare. |
| `SettingsBlobCodec.swift` | `SyncableSettings` projection + `PropertyListEncoder` round-trip + schema-version gate. |

### Modified files

| File | What changes |
|------|-------------|
| `apps/macos/Sources/SettingsStore/CatermSettings.swift` | v2 schema fields: `seedVersion`, `seededByDefault`, `firstUserEditedAt`, `canonicalSeedHash`. |
| `apps/macos/Sources/SettingsStore/SettingsStore.swift` | Seed path sets new fields; first `update(_:)` sets `firstUserEditedAt`; new `replaceFromSync(_:)` API; new `sourceUserInfoKey` constant. |
| `apps/macos/Sources/SettingsStore/SettingsMigrationStep.swift` | (No change to this file's existing content — the v1→v2 schema bump is handled in `SettingsStore.load`. The legacy `settings-gui-v1` token continues to be set by the existing migration; it remains local-only and is never synced.) |
| `apps/macos/Sources/Caterm/CatermApp.swift` | Construct `SettingsSyncStore`, call `installLifecycleObservers()` then `startSync()`. |
| `apps/macos/Package.swift` | Register `SettingsSyncStore` library target + test target. |
| `apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift` | Update existing assertions where `CatermSettings` value comparisons need new field handling. |

### New documentation

| File | Purpose |
|------|---------|
| `docs/macos-cloudkit-settings-sync.md` | Operator-facing architecture + decision tree + identity-token semantics + how to reset KVS during dev. |

---

## Phase order rationale

- **Phase 1** lands the schema + canonical-shape detection in `SettingsStore` first. Pure data work, no sync. After this phase the local plist still works exactly as before, but it carries the metadata the sync layer will read. v1→v2 migration is in this phase so production users upgrade safely even if Phase 4 is incomplete.
- **Phase 2** lands the pure-function decision logic (`BootstrapDecider`, `AccountSwitchHandler`, `IsDefaultSeedUnedited`, `SettingsBlobCodec`, `KnownSeedTable`). All testable without any KVS or app integration.
- **Phase 3** lands the IO adapters (`KVSAdapter`, `IdentityTokenStore`) — testable with fakes for the values they wrap.
- **Phase 4** wires the `SettingsSyncStore` coordinator. Each task adds one piece (lifecycle, dispatch, boot, push, pull, account-switch).
- **Phase 5** integrates with `CatermApp`, runs the two-Mac integration matrix, and writes operator docs.

Each phase ends with `swift build` + `swift test` green on affected modules.

---

## Phase 1 — `SettingsStore` schema + plumbing

### Task 1: Bump `CatermSettings` to v2

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/CatermSettings.swift`
- Modify: `apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift` (re-run existing tests after schema bump)

- [ ] **Step 1: Write a failing test that asserts new v2 fields with safe defaults**

Append to `apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift`:

```swift
import XCTest
@testable import SettingsStore

final class CatermSettingsV2SchemaTests: XCTestCase {
    func test_defaultInit_hasV2FieldsWithSafeDefaults() {
        let s = CatermSettings()
        XCTAssertEqual(s.version, 2, "schema bumped to v2")
        XCTAssertEqual(s.seedVersion, 0, "0 = not yet seeded")
        XCTAssertFalse(s.seededByDefault)
        XCTAssertNil(s.firstUserEditedAt)
        XCTAssertEqual(s.canonicalSeedHash, "")
    }

    func test_codable_roundTrip_preservesAllFields() throws {
        var s = CatermSettings()
        s.seedVersion = 1
        s.seededByDefault = true
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1_700_000_000)
        s.canonicalSeedHash = "deadbeef"
        let data = try PropertyListEncoder().encode(s)
        let decoded = try PropertyListDecoder().decode(CatermSettings.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd apps/macos && swift test --filter CatermSettingsV2SchemaTests 2>&1 | tail -30`
Expected: FAIL — compile error because `seedVersion`, `seededByDefault`, `firstUserEditedAt`, `canonicalSeedHash` don't exist yet.

- [ ] **Step 3: Add the v2 fields to `CatermSettings`**

Replace the existing struct in `apps/macos/Sources/SettingsStore/CatermSettings.swift`:

```swift
public struct CatermSettings: Codable, Equatable {
    public var version: Int
    public var revision: String
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var migrationsCompleted: Set<String>

    // v2 fields. Always carried in CatermSettings; SyncableSettings strips
    // migrationsCompleted before encoding to KVS but keeps these.
    public var seedVersion: Int
    public var seededByDefault: Bool
    public var firstUserEditedAt: Date?
    public var canonicalSeedHash: String

    public init(
        version: Int = 2,
        revision: String = "",
        global: PartialSettings = PartialSettings(),
        hostOverrides: [HostId: PartialSettings] = [:],
        migrationsCompleted: Set<String> = [],
        seedVersion: Int = 0,
        seededByDefault: Bool = false,
        firstUserEditedAt: Date? = nil,
        canonicalSeedHash: String = ""
    ) {
        self.version = version
        self.revision = revision
        self.global = global
        self.hostOverrides = hostOverrides
        self.migrationsCompleted = migrationsCompleted
        self.seedVersion = seedVersion
        self.seededByDefault = seededByDefault
        self.firstUserEditedAt = firstUserEditedAt
        self.canonicalSeedHash = canonicalSeedHash
    }

    public static let empty = CatermSettings()

    public static let defaultsSeed: PartialSettings = PartialSettings(
        fontFamily: "SF Mono",
        fontSize: 13,
        cursorStyle: .block,
        scrollbackBytes: 10_000_000,
        titlebarStyle: .tabs,
        theme: "Catppuccin Mocha"
    )
}
```

Custom `init(from:)` and `encode(to:)` are NOT needed: Swift's synthesized Codable handles the new optional/scalar fields, and old v1 plists missing these keys will be decoded with defaults via `decodeIfPresent` if we add it. For now, **synthesized Codable is sufficient** because `decode` populates missing keys with the default-initialized values only when they're optional; for the non-optional new fields we need a custom decoder. Add it in Step 4.

- [ ] **Step 4: Add a custom decoder so v1 plists (missing v2 keys) decode with safe defaults**

Append below the `init(...)` initializer in `CatermSettings.swift`:

```swift
extension CatermSettings {
    private enum CodingKeys: String, CodingKey {
        case version, revision, global, hostOverrides, migrationsCompleted
        case seedVersion, seededByDefault, firstUserEditedAt, canonicalSeedHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        self.global = try c.decodeIfPresent(PartialSettings.self, forKey: .global) ?? PartialSettings()
        self.hostOverrides = try c.decodeIfPresent([HostId: PartialSettings].self, forKey: .hostOverrides) ?? [:]
        self.migrationsCompleted = try c.decodeIfPresent(Set<String>.self, forKey: .migrationsCompleted) ?? []
        self.seedVersion = try c.decodeIfPresent(Int.self, forKey: .seedVersion) ?? 0
        self.seededByDefault = try c.decodeIfPresent(Bool.self, forKey: .seededByDefault) ?? false
        self.firstUserEditedAt = try c.decodeIfPresent(Date.self, forKey: .firstUserEditedAt)
        self.canonicalSeedHash = try c.decodeIfPresent(String.self, forKey: .canonicalSeedHash) ?? ""
    }
}
```

- [ ] **Step 5: Run tests, confirm passing**

Run: `cd apps/macos && swift test --filter CatermSettingsV2SchemaTests 2>&1 | tail -20`
Expected: PASS (both tests).

Also run the existing SettingsStore tests to ensure no regressions:
Run: `cd apps/macos && swift test --filter SettingsStoreTests 2>&1 | tail -20`
Expected: All pass (existing tests construct `CatermSettings()` via the default initializer, which now gets the new fields with safe defaults — no test changes needed).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SettingsStore/CatermSettings.swift \
        apps/macos/Tests/SettingsStoreTests/SettingsStorePersistenceTests.swift
git commit -m "feat(settings): bump CatermSettings to v2 with seed-tracking fields"
```

---

### Task 2: Track `firstUserEditedAt` and seed-time fields in `SettingsStore`

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/SettingsStore.swift`
- Modify: `apps/macos/Tests/SettingsStoreTests/SettingsStoreUpdateTests.swift`

- [ ] **Step 1: Write a failing test that asserts `firstUserEditedAt` is set on first `update`**

Append to `apps/macos/Tests/SettingsStoreTests/SettingsStoreUpdateTests.swift`:

```swift
import XCTest
@testable import SettingsStore

final class FirstUserEditedAtTests: XCTestCase {
    @MainActor
    func test_firstUpdate_setsFirstUserEditedAt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        XCTAssertNil(store.settings.firstUserEditedAt)

        store.debounceInterval = .milliseconds(0)
        store.update { $0.global.fontSize = 14 }
        store.flushNow()

        XCTAssertNotNil(store.settings.firstUserEditedAt, "first edit should populate timestamp")
    }

    @MainActor
    func test_secondUpdate_doesNotChangeFirstUserEditedAt() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        let store = SettingsStore(
            settings: CatermSettings(firstUserEditedAt: initial),
            path: tmp
        )

        store.debounceInterval = .milliseconds(0)
        store.update { $0.global.fontSize = 14 }
        store.flushNow()

        XCTAssertEqual(store.settings.firstUserEditedAt, initial,
            "subsequent edits must NOT overwrite the first-edit timestamp")
    }
}
```

- [ ] **Step 2: Run test, confirm failure**

Run: `cd apps/macos && swift test --filter FirstUserEditedAtTests 2>&1 | tail -20`
Expected: First test FAILs because `firstUserEditedAt` stays nil after `update`. Second test passes accidentally because nothing currently overwrites it.

- [ ] **Step 3: Wire `firstUserEditedAt` into `update(_:)`**

In `apps/macos/Sources/SettingsStore/SettingsStore.swift`, locate the `update(_ mutate:)` method and modify it:

```swift
public func update(_ mutate: (inout CatermSettings) -> Void) {
    var draft = _pending?.settings ?? settings
    mutate(&draft)
    if draft.firstUserEditedAt == nil {
        draft.firstUserEditedAt = Date()
    }
    let pending = _pending ?? _Pending(draft)
    pending.settings = draft
    pending.task?.cancel()
    let interval = self.debounceInterval
    pending.task = Task { [weak self] in
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.flushNow() }
    }
    _pending = pending
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter FirstUserEditedAtTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsStore.swift \
        apps/macos/Tests/SettingsStoreTests/SettingsStoreUpdateTests.swift
git commit -m "feat(settings): track firstUserEditedAt on first user-driven update"
```

---

### Task 3: Add `KnownSeedTable` + canonical hash helper

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/KnownSeedTable.swift`
- Modify: `apps/macos/Package.swift` (add `SettingsSyncStore` target)
- Create: `apps/macos/Sources/SettingsSyncStore/Placeholder.swift` (so target builds before other tasks)
- Create: `apps/macos/Tests/SettingsSyncStoreTests/KnownSeedTableTests.swift`

- [ ] **Step 1: Add `SettingsSyncStore` library target + test target to `Package.swift`**

In `apps/macos/Package.swift`, in the `// --- Libraries ---` section (alphabetical with peers):

```swift
.target(
    name: "SettingsSyncStore",
    dependencies: ["SettingsStore"],
    path: "Sources/SettingsSyncStore"
),
```

In the `// --- Tests ---` section:

```swift
.testTarget(
    name: "SettingsSyncStoreTests",
    dependencies: ["SettingsSyncStore", "SettingsStore"],
    path: "Tests/SettingsSyncStoreTests"
),
```

Also add `"SettingsSyncStore"` to the `Caterm` executable target's `dependencies` list.

- [ ] **Step 2: Create placeholder source so SwiftPM accepts the new target**

Create `apps/macos/Sources/SettingsSyncStore/Placeholder.swift`:

```swift
// Removed once KnownSeedTable.swift lands in this same task.
```

Create `apps/macos/Tests/SettingsSyncStoreTests/Placeholder.swift`:

```swift
import XCTest
final class Placeholder: XCTestCase { func test_compiles() {} }
```

Verify build: `cd apps/macos && swift build 2>&1 | tail -10`
Expected: success.

- [ ] **Step 3: Write failing test for `KnownSeedTable.canonicalHash`**

Create `apps/macos/Tests/SettingsSyncStoreTests/KnownSeedTableTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class KnownSeedTableTests: XCTestCase {
    func test_canonicalHash_isStableAcrossInvocations() {
        let h1 = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
        let h2 = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
        XCTAssertEqual(h1, h2)
        XCTAssertFalse(h1.isEmpty)
    }

    func test_canonicalHash_differsForDifferentValues() {
        var modified = CatermSettings.defaultsSeed
        modified.fontSize = 42
        XCTAssertNotEqual(
            KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed),
            KnownSeedTable.canonicalHash(of: modified)
        )
    }

    func test_currentSeed_isInTheTable() {
        let entry = KnownSeedTable.entries.first { $0.canonicalSeedHash ==
            KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed) }
        XCTAssertNotNil(entry, "current default seed must be registered in the table")
        XCTAssertGreaterThan(entry!.seedVersion, 0)
    }

    func test_versions_areAppendOnlyMonotonic() {
        let versions = KnownSeedTable.entries.map(\.seedVersion)
        XCTAssertEqual(versions, versions.sorted(), "entries must be append-only sorted")
        XCTAssertEqual(Set(versions).count, versions.count, "no duplicate versions")
    }
}
```

- [ ] **Step 4: Run, confirm fail**

Run: `cd apps/macos && swift test --filter KnownSeedTableTests 2>&1 | tail -20`
Expected: compile failure — `KnownSeedTable` does not exist yet.

- [ ] **Step 5: Create `KnownSeedTable.swift`**

Replace placeholder content with `apps/macos/Sources/SettingsSyncStore/KnownSeedTable.swift`:

```swift
import CryptoKit
import Foundation
import SettingsStore

/// Append-only table of every default seed shipped historically. Old entries
/// are NEVER deleted: when `CatermSettings.defaultsSeed` changes, append a new
/// entry. Older devices' canonical hashes still map to a known seed version,
/// so the `IsDefaultSeedUnedited` predicate can recognize them.
public enum KnownSeedTable {
    public struct Entry: Equatable {
        public let seedVersion: Int
        public let snapshot: PartialSettings
        public let canonicalSeedHash: String
    }

    public static let entries: [Entry] = {
        var table: [Entry] = []
        // v1 — original Plan D rollout. NEVER mutate this entry.
        let v1 = PartialSettings(
            fontFamily: "SF Mono",
            fontSize: 13,
            cursorStyle: .block,
            scrollbackBytes: 10_000_000,
            titlebarStyle: .tabs,
            theme: "Catppuccin Mocha"
        )
        table.append(Entry(seedVersion: 1, snapshot: v1, canonicalSeedHash: canonicalHash(of: v1)))
        return table
    }()

    public static var versions: Set<Int> { Set(entries.map(\.seedVersion)) }
    public static var hashes: Set<String> { Set(entries.map(\.canonicalSeedHash)) }

    public static func entry(forVersion v: Int) -> Entry? {
        entries.first { $0.seedVersion == v }
    }

    /// Canonical SHA-256 of a `PartialSettings`. Uses sorted-keys plist
    /// encoding so field reordering doesn't change the hash.
    public static func canonicalHash(of partial: PartialSettings) -> String {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(partial) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 6: Delete the placeholder file (it has served its purpose)**

```bash
rm apps/macos/Sources/SettingsSyncStore/Placeholder.swift
```

- [ ] **Step 7: Run, confirm passing**

Run: `cd apps/macos && swift test --filter KnownSeedTableTests 2>&1 | tail -10`
Expected: all 4 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Package.swift \
        apps/macos/Sources/SettingsSyncStore/ \
        apps/macos/Tests/SettingsSyncStoreTests/
git commit -m "feat(settings-sync): add KnownSeedTable with append-only seed registry"
```

---

### Task 4: Wire seed-time tracking + add `replaceFromSync` to `SettingsStore`

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/SettingsStore.swift`
- Create: `apps/macos/Tests/SettingsStoreTests/ReplaceFromSyncTests.swift`

- [ ] **Step 1: Write failing test for `replaceFromSync`**

Create `apps/macos/Tests/SettingsStoreTests/ReplaceFromSyncTests.swift`:

```swift
import XCTest
@testable import SettingsStore

final class ReplaceFromSyncTests: XCTestCase {
    @MainActor
    func test_replaceFromSync_preservesCloudRevisionVerbatim() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = SettingsStore(settings: CatermSettings(revision: "local-rev"), path: tmp)

        var cloud = CatermSettings(revision: "cloud-rev")
        cloud.global.fontSize = 18
        try store.replaceFromSync(cloud)

        XCTAssertEqual(store.settings.revision, "cloud-rev",
            "replaceFromSync must preserve cloud revision exactly — no makeRevision bump")
        XCTAssertEqual(store.settings.global.fontSize, 18)
    }

    @MainActor
    func test_replaceFromSync_preservesLocalMigrationsCompleted() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var local = CatermSettings()
        local.migrationsCompleted = ["settings-gui-v1", "device-only-marker"]
        let store = SettingsStore(settings: local, path: tmp)

        var cloud = CatermSettings(revision: "r")
        cloud.migrationsCompleted = ["different-marker"]
        try store.replaceFromSync(cloud)

        XCTAssertEqual(store.settings.migrationsCompleted,
            ["settings-gui-v1", "device-only-marker"],
            "migrationsCompleted is local-only and must NOT be overwritten by sync")
    }

    @MainActor
    func test_replaceFromSync_postsChangeNotificationWithSyncSource() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = SettingsStore(settings: CatermSettings(), path: tmp)

        let exp = expectation(description: "changeNotification posted")
        var capturedSource: String?
        let token = NotificationCenter.default.addObserver(
            forName: SettingsStore.changeNotification, object: store, queue: nil
        ) { note in
            capturedSource = note.userInfo?[SettingsStore.sourceUserInfoKey] as? String
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        var cloud = CatermSettings(revision: "r")
        cloud.global.fontSize = 99
        try store.replaceFromSync(cloud)
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(capturedSource, "sync")
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter ReplaceFromSyncTests 2>&1 | tail -20`
Expected: compile failure — `replaceFromSync` and `sourceUserInfoKey` don't exist.

- [ ] **Step 3: Add `sourceUserInfoKey` and `replaceFromSync` to `SettingsStore`**

In `apps/macos/Sources/SettingsStore/SettingsStore.swift`, near the top inside the class:

```swift
public static let scopeUserInfoKey = "scope"
public static let sourceUserInfoKey = "source"  // values: "local" (default) or "sync"
```

Add the new method (after `flushNow` or at end of class):

```swift
/// Sync-side cloud-apply path. Preserves cloud's revision verbatim (does NOT
/// call makeRevision), preserves the local migrationsCompleted set, and posts
/// a change notification tagged source == "sync" so SettingsSyncStore can
/// filter and avoid an apply→push feedback loop.
///
/// `migrationsCompleted` is per-device filesystem migration state and never
/// travels — even though `cloud.migrationsCompleted` may have content (it
/// shouldn't if the codec strips it correctly, but we defend at the seam).
public func replaceFromSync(_ cloud: CatermSettings) throws {
    var next = cloud
    next.migrationsCompleted = settings.migrationsCompleted
    let data = try PropertyListEncoder().encode(next)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: path, options: .atomic)
    let old = settings
    self.settings = next

    // Post change notification with both scope (existing consumers) and source
    // (new). LiveReloadCoordinator ignores source; SettingsSyncStore uses it.
    let scope = SettingsChangeScope.diff(old: old, new: next)
    var userInfo: [AnyHashable: Any] = [Self.sourceUserInfoKey: "sync"]
    if let scope = scope {
        userInfo[Self.scopeUserInfoKey] = scope
    }
    NotificationCenter.default.post(
        name: Self.changeNotification, object: self, userInfo: userInfo
    )
}
```

Note: the existing `flushNow` posts `changeNotification` without `sourceUserInfoKey` — that's the implicit "local" source. Update `flushNow` so the contract is symmetric: tag local edits explicitly so the sync filter sees a value either way.

In `flushNow()`, replace the existing `NotificationCenter.default.post(...)` block with:

```swift
if let scope = SettingsChangeScope.diff(old: old, new: next) {
    NotificationCenter.default.post(
        name: Self.changeNotification,
        object: self,
        userInfo: [
            Self.scopeUserInfoKey: scope,
            Self.sourceUserInfoKey: "local",
        ]
    )
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter ReplaceFromSyncTests 2>&1 | tail -10`
Expected: all 3 tests PASS.

Run the full SettingsStore suite to catch regressions:
Run: `cd apps/macos && swift test --filter SettingsStoreTests 2>&1 | tail -10`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsStore.swift \
        apps/macos/Tests/SettingsStoreTests/ReplaceFromSyncTests.swift
git commit -m "feat(settings): add replaceFromSync API + source userInfo on changeNotification"
```

---

### Task 5: Canonical-shape v1→v2 migration in `SettingsStore.load`

**Files:**
- Modify: `apps/macos/Sources/SettingsStore/SettingsStore.swift`
- Create: `apps/macos/Tests/SettingsStoreTests/V1ToV2MigrationTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsStoreTests/V1ToV2MigrationTests.swift`:

```swift
import XCTest
@testable import SettingsStore

final class V1ToV2MigrationTests: XCTestCase {
    private func writeV1Plist(_ s: CatermSettings, to path: URL) throws {
        // Force-encode with version=1 to simulate an on-disk v1 plist
        var v1 = s
        v1.version = 1
        v1.seedVersion = 0
        v1.seededByDefault = false
        v1.firstUserEditedAt = nil
        v1.canonicalSeedHash = ""
        let data = try PropertyListEncoder().encode(v1)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: path)
    }

    @MainActor
    func test_v1_exactDefaultSeed_becomesSeededByDefaultTrue() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var v1 = CatermSettings()
        v1.global = CatermSettings.defaultsSeed
        v1.hostOverrides = [:]
        try writeV1Plist(v1, to: tmp)

        let store = try SettingsStore.load(from: tmp)
        XCTAssertEqual(store.settings.version, 2)
        XCTAssertTrue(store.settings.seededByDefault, "exact-defaults v1 plist must migrate as seeded")
        XCTAssertNil(store.settings.firstUserEditedAt)
        XCTAssertEqual(store.settings.seedVersion, 1)
        XCTAssertFalse(store.settings.canonicalSeedHash.isEmpty)
    }

    @MainActor
    func test_v1_edited_becomesSeededByDefaultFalse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var v1 = CatermSettings()
        v1.global = CatermSettings.defaultsSeed
        v1.global.fontSize = 18  // user edit
        v1.hostOverrides = [:]
        try writeV1Plist(v1, to: tmp)

        let store = try SettingsStore.load(from: tmp)
        XCTAssertEqual(store.settings.version, 2)
        XCTAssertFalse(store.settings.seededByDefault)
        XCTAssertNotNil(store.settings.firstUserEditedAt, "edited v1 user must be marked as having edited")
        XCTAssertEqual(store.settings.canonicalSeedHash, "",
            "edited v1 user gets empty hash so isDefaultSeedUnedited can never accidentally fire")
    }

    @MainActor
    func test_v1_withHostOverride_becomesSeededByDefaultFalse() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("v1-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var v1 = CatermSettings()
        v1.global = CatermSettings.defaultsSeed
        v1.hostOverrides = [HostId("host-1"): PartialSettings(fontSize: 16)]
        try writeV1Plist(v1, to: tmp)

        let store = try SettingsStore.load(from: tmp)
        XCTAssertFalse(store.settings.seededByDefault)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter V1ToV2MigrationTests 2>&1 | tail -20`
Expected: tests FAIL because `load(from:)` does not yet bump version or detect canonical shape.

- [ ] **Step 3: Add canonical-shape detection helper to `SettingsStore`**

In `apps/macos/Sources/SettingsStore/SettingsStore.swift`, add a private helper. Note that we need a SHA-256 of the v1 default seed shape. Hardcode the constant from `CatermSettings.defaultsSeed` (the same one that will be in `KnownSeedTable.entries[0]`); cross-module sharing happens at Phase 2 — for now `SettingsStore` doesn't depend on `SettingsSyncStore`, so we duplicate the canonical hash function locally and rely on `KnownSeedTable` test cross-checking that they agree.

Add at top of `SettingsStore.swift` (after imports):

```swift
import CryptoKit
```

Add inside `SettingsStore` (private static helpers):

```swift
private static func canonicalHash(of partial: PartialSettings) -> String {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    guard let data = try? encoder.encode(partial) else { return "" }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private static let v1DefaultSeedHash: String = canonicalHash(of: CatermSettings.defaultsSeed)
```

Now modify `load(from:)`. Replace the existing implementation:

```swift
public static func load(from path: URL) throws -> SettingsStore {
    if !FileManager.default.fileExists(atPath: path.path) {
        var seeded = CatermSettings.empty
        seeded.global = CatermSettings.defaultsSeed
        seeded.revision = makeRevision()
        seeded.seededByDefault = true
        seeded.seedVersion = 1
        seeded.canonicalSeedHash = v1DefaultSeedHash
        seeded.firstUserEditedAt = nil
        return SettingsStore(settings: seeded, path: path)
    }
    do {
        let data = try Data(contentsOf: path)
        var s = try PropertyListDecoder().decode(CatermSettings.self, from: data)
        if s.version < 2 {
            migrateV1ToV2(&s)
        }
        return SettingsStore(settings: s, path: path)
    } catch {
        try quarantineCorrupted(at: path)
        var seeded = CatermSettings.empty
        seeded.global = CatermSettings.defaultsSeed
        seeded.revision = makeRevision()
        seeded.seededByDefault = true
        seeded.seedVersion = 1
        seeded.canonicalSeedHash = v1DefaultSeedHash
        seeded.firstUserEditedAt = nil
        return SettingsStore(settings: seeded, path: path)
    }
}

private static func migrateV1ToV2(_ s: inout CatermSettings) {
    s.version = 2
    let exactDefaults = canonicalHash(of: s.global) == v1DefaultSeedHash
        && s.hostOverrides.isEmpty
    if exactDefaults {
        s.seededByDefault = true
        s.firstUserEditedAt = nil
        s.seedVersion = 1
        s.canonicalSeedHash = v1DefaultSeedHash
    } else {
        s.seededByDefault = false
        s.firstUserEditedAt = Date()  // sentinel: edited before tracking, exact moment unknown
        s.seedVersion = 1
        s.canonicalSeedHash = ""  // empty never matches KnownSeedTable; locks user in real-edits
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter V1ToV2MigrationTests 2>&1 | tail -10`
Expected: all 3 tests PASS.

Run full suite:
Run: `cd apps/macos && swift test 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsStore/SettingsStore.swift \
        apps/macos/Tests/SettingsStoreTests/V1ToV2MigrationTests.swift
git commit -m "feat(settings): v1→v2 migration with canonical-shape default-seed detection"
```

---

## Phase 2 — Pure decision logic

### Task 6: `IsDefaultSeedUnedited` predicate

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/IsDefaultSeedUnedited.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/IsDefaultSeedUneditedTests.swift`

- [ ] **Step 1: Write failing test (1 positive + 7 negative paths, one per predicate clause)**

Create `apps/macos/Tests/SettingsSyncStoreTests/IsDefaultSeedUneditedTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class IsDefaultSeedUneditedTests: XCTestCase {
    private func freshSeed() -> CatermSettings {
        var s = CatermSettings()
        s.global = CatermSettings.defaultsSeed
        s.seededByDefault = true
        s.firstUserEditedAt = nil
        s.seedVersion = 1
        s.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
        s.hostOverrides = [:]
        s.migrationsCompleted = []
        return s
    }

    func test_freshSeed_returnsTrue() {
        XCTAssertTrue(IsDefaultSeedUnedited.evaluate(
            freshSeed(),
            knownMigrations: ["settings-gui-v1"]
        ))
    }

    func test_seededByDefaultFalse_returnsFalse() {
        var s = freshSeed(); s.seededByDefault = false
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
    }

    func test_firstUserEditedAtSet_returnsFalse() {
        var s = freshSeed(); s.firstUserEditedAt = Date()
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
    }

    func test_unknownSeedVersion_returnsFalse() {
        var s = freshSeed(); s.seedVersion = 999
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
    }

    func test_unknownCanonicalHash_returnsFalse() {
        var s = freshSeed(); s.canonicalSeedHash = "not-in-table"
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
    }

    func test_globalDoesNotMatchSeedSnapshot_returnsFalse() {
        var s = freshSeed(); s.global.fontSize = 99
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
    }

    func test_hostOverridesNotEmpty_returnsFalse() {
        var s = freshSeed()
        s.hostOverrides = [HostId("h"): PartialSettings(fontSize: 14)]
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: []))
    }

    func test_migrationsCompletedHasUnknownToken_returnsFalse() {
        var s = freshSeed(); s.migrationsCompleted = ["unknown-future-migration"]
        XCTAssertFalse(IsDefaultSeedUnedited.evaluate(s, knownMigrations: ["settings-gui-v1"]))
    }
}
```

- [ ] **Step 2: Run, confirm fail (compile)**

Run: `cd apps/macos && swift test --filter IsDefaultSeedUneditedTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement the predicate**

Create `apps/macos/Sources/SettingsSyncStore/IsDefaultSeedUnedited.swift`:

```swift
import Foundation
import SettingsStore

public enum IsDefaultSeedUnedited {
    /// True iff `settings` is identical to a known historical default seed
    /// AND has no user-driven edits AND uses no migrations beyond the
    /// caller-supplied set of known-at-this-app-version migration tokens.
    /// Composite: any single failed clause flips the result to false.
    public static func evaluate(
        _ settings: CatermSettings,
        knownMigrations: Set<String>
    ) -> Bool {
        guard settings.seededByDefault else { return false }
        guard settings.firstUserEditedAt == nil else { return false }
        guard KnownSeedTable.versions.contains(settings.seedVersion) else { return false }
        guard KnownSeedTable.hashes.contains(settings.canonicalSeedHash) else { return false }
        guard let entry = KnownSeedTable.entry(forVersion: settings.seedVersion),
              entry.snapshot == settings.global else { return false }
        guard settings.hostOverrides.isEmpty else { return false }
        guard settings.migrationsCompleted.isSubset(of: knownMigrations) else { return false }
        return true
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter IsDefaultSeedUneditedTests 2>&1 | tail -10`
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/IsDefaultSeedUnedited.swift \
        apps/macos/Tests/SettingsSyncStoreTests/IsDefaultSeedUneditedTests.swift
git commit -m "feat(settings-sync): IsDefaultSeedUnedited composite predicate"
```

---

### Task 7: `SyncableSettings` projection + `SettingsBlobCodec`

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/SettingsBlobCodec.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/SettingsBlobCodecTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/SettingsBlobCodecTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class SettingsBlobCodecTests: XCTestCase {
    func test_roundTrip_preservesAllSyncableFields() throws {
        var s = CatermSettings()
        s.version = 2
        s.revision = "rev-x"
        s.global = CatermSettings.defaultsSeed
        s.hostOverrides = [HostId("h"): PartialSettings(fontSize: 16)]
        s.migrationsCompleted = ["settings-gui-v1"]   // local-only — must NOT be in blob
        s.seedVersion = 1
        s.seededByDefault = true
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1_700_000_000)
        s.canonicalSeedHash = "hash"

        let blob = try SettingsBlobCodec.encode(s)
        let decoded = try SettingsBlobCodec.decode(blob)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.revision, "rev-x")
        XCTAssertEqual(decoded.global, s.global)
        XCTAssertEqual(decoded.hostOverrides, s.hostOverrides)
        XCTAssertEqual(decoded.seedVersion, 1)
        XCTAssertTrue(decoded.seededByDefault)
        XCTAssertEqual(decoded.firstUserEditedAt, s.firstUserEditedAt)
        XCTAssertEqual(decoded.canonicalSeedHash, "hash")
    }

    func test_blob_doesNotContainMigrationsCompleted() throws {
        var s = CatermSettings()
        s.migrationsCompleted = ["secret-marker"]
        let blob = try SettingsBlobCodec.encode(s)
        let raw = String(data: blob, encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("secret-marker"),
            "blob must not leak local-only migrationsCompleted")
        XCTAssertFalse(raw.contains("migrationsCompleted"))
    }

    func test_decode_corruptedBlob_throws() {
        XCTAssertThrowsError(try SettingsBlobCodec.decode(Data([0xFF, 0x00])))
    }

    func test_decode_emptyData_throws() {
        XCTAssertThrowsError(try SettingsBlobCodec.decode(Data()))
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter SettingsBlobCodecTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement `SettingsBlobCodec` + `SyncableSettings`**

Create `apps/macos/Sources/SettingsSyncStore/SettingsBlobCodec.swift`:

```swift
import Foundation
import SettingsStore

/// On-the-wire shape for KVS. Excludes `migrationsCompleted`, which is
/// per-device filesystem state and explicitly never travels.
public struct SyncableSettings: Codable, Equatable {
    public var version: Int
    public var revision: String
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var seedVersion: Int
    public var seededByDefault: Bool
    public var firstUserEditedAt: Date?
    public var canonicalSeedHash: String

    public init(from local: CatermSettings) {
        self.version = local.version
        self.revision = local.revision
        self.global = local.global
        self.hostOverrides = local.hostOverrides
        self.seedVersion = local.seedVersion
        self.seededByDefault = local.seededByDefault
        self.firstUserEditedAt = local.firstUserEditedAt
        self.canonicalSeedHash = local.canonicalSeedHash
    }

    /// Inflate to a full CatermSettings using the local migrations set.
    /// Sync never sets migrationsCompleted — that always comes from local.
    public func toLocal(localMigrationsCompleted: Set<String>) -> CatermSettings {
        CatermSettings(
            version: version,
            revision: revision,
            global: global,
            hostOverrides: hostOverrides,
            migrationsCompleted: localMigrationsCompleted,
            seedVersion: seedVersion,
            seededByDefault: seededByDefault,
            firstUserEditedAt: firstUserEditedAt,
            canonicalSeedHash: canonicalSeedHash
        )
    }
}

public enum SettingsBlobCodec {
    public static func encode(_ s: CatermSettings) throws -> Data {
        let projected = SyncableSettings(from: s)
        return try PropertyListEncoder().encode(projected)
    }

    public static func decode(_ data: Data) throws -> SyncableSettings {
        return try PropertyListDecoder().decode(SyncableSettings.self, from: data)
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter SettingsBlobCodecTests 2>&1 | tail -10`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsBlobCodec.swift \
        apps/macos/Tests/SettingsSyncStoreTests/SettingsBlobCodecTests.swift
git commit -m "feat(settings-sync): SyncableSettings projection + blob codec"
```

---

### Task 8: `Decision` value type + `BootstrapDecider`

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/Decision.swift`
- Create: `apps/macos/Sources/SettingsSyncStore/BootstrapDecider.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/BootstrapDeciderTests.swift`

- [ ] **Step 1: Write failing test (8 branches per spec test plan)**

Create `apps/macos/Tests/SettingsSyncStoreTests/BootstrapDeciderTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class BootstrapDeciderTests: XCTestCase {
    private let knownMigrations: Set<String> = ["settings-gui-v1"]

    private func freshSeed() -> CatermSettings {
        var s = CatermSettings()
        s.global = CatermSettings.defaultsSeed
        s.seededByDefault = true
        s.seedVersion = 1
        s.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
        s.revision = "local-rev"
        return s
    }

    private func realEdits(revision: String = "local-rev",
                          firstEdit: Date = Date(timeIntervalSince1970: 1)) -> CatermSettings {
        var s = freshSeed()
        s.global.fontSize = 99
        s.seededByDefault = false
        s.firstUserEditedAt = firstEdit
        s.canonicalSeedHash = ""
        s.revision = revision
        return s
    }

    private func cloud(revision: String, version: Int = 2) -> SyncableSettings {
        var c = SyncableSettings(from: realEdits(revision: revision))
        c.version = version
        return c
    }

    private let bootStartedAt = Date(timeIntervalSince1970: 100_000_000)

    func test_branch1_cloudNil_localSeed_returnsNoOp() {
        let d = BootstrapDecider.decide(
            local: freshSeed(), cloud: nil,
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .noOp)
        XCTAssertFalse(d.finalSuspensionState)
        XCTAssertTrue(d.acceptIdentity)
    }

    func test_branch2_cloudNil_localReal_returnsPushLocal() {
        let d = BootstrapDecider.decide(
            local: realEdits(), cloud: nil,
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .pushLocal)
        XCTAssertTrue(d.acceptIdentity)
    }

    func test_branch3_cloudReal_localSeed_returnsApplyCloud() {
        let d = BootstrapDecider.decide(
            local: freshSeed(), cloud: cloud(revision: "cloud-rev"),
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .applyCloud)
        XCTAssertTrue(d.acceptIdentity)
    }

    func test_branch4_cloudReal_localReal_cloudNewer_returnsApplyCloud() {
        let d = BootstrapDecider.decide(
            local: realEdits(revision: "a"), cloud: cloud(revision: "z"),
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .applyCloud)
    }

    func test_branch5_cloudReal_localReal_localNewer_returnsPushLocal() {
        let d = BootstrapDecider.decide(
            local: realEdits(revision: "z"), cloud: cloud(revision: "a"),
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .pushLocal)
    }

    func test_branch6_cloudReal_localReal_revisionEqual_returnsNoOp() {
        let d = BootstrapDecider.decide(
            local: realEdits(revision: "same"), cloud: cloud(revision: "same"),
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .noOp)
    }

    func test_branch7_cloudSchemaNewer_returnsRejectMerge() {
        let d = BootstrapDecider.decide(
            local: realEdits(), cloud: cloud(revision: "z", version: 3),
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .rejectMerge)
        XCTAssertTrue(d.acceptIdentity, "schema-newer in same identity still accepts identity")
        XCTAssertFalse(d.finalSuspensionState)
    }

    func test_branch8_clockSkewSanity_localFirstEditAfterBoot_prefersLocal() {
        // local revision lower (cloud appears newer), but local.firstUserEditedAt
        // is after bootStartedAt — clock has been rewound; trust local.
        let after = bootStartedAt.addingTimeInterval(60)
        let d = BootstrapDecider.decide(
            local: realEdits(revision: "a", firstEdit: after),
            cloud: cloud(revision: "z"),
            bootStartedAt: bootStartedAt, knownMigrations: knownMigrations
        )
        XCTAssertEqual(d.action, .pushLocal)
    }
}
```

- [ ] **Step 2: Run, confirm fail (compile)**

Run: `cd apps/macos && swift test --filter BootstrapDeciderTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement `Decision`**

Create `apps/macos/Sources/SettingsSyncStore/Decision.swift`:

```swift
import Foundation
import SettingsStore

public enum DecisionAction: Equatable {
    case noOp
    case pushLocal
    case applyCloud(SyncableSettings)
    case rejectMerge(reason: RejectReason)
    case forceApply(SyncableSettings)
    case suspendUntilFirstEdit
}

public enum RejectReason: Equatable {
    case schemaNewerThanLocal
}

public struct Decision: Equatable {
    public let action: DecisionAction
    public let finalSuspensionState: Bool
    public let acceptIdentity: Bool

    public init(action: DecisionAction, finalSuspensionState: Bool, acceptIdentity: Bool) {
        self.action = action
        self.finalSuspensionState = finalSuspensionState
        self.acceptIdentity = acceptIdentity
    }
}

// Test ergonomics: compare ignoring the associated SyncableSettings payload
// for `applyCloud` / `forceApply` when needed via a separate helper.
public extension DecisionAction {
    /// Tag-only comparison used in unit tests where the payload is incidental.
    var tag: String {
        switch self {
        case .noOp: return "noOp"
        case .pushLocal: return "pushLocal"
        case .applyCloud: return "applyCloud"
        case .rejectMerge: return "rejectMerge"
        case .forceApply: return "forceApply"
        case .suspendUntilFirstEdit: return "suspendUntilFirstEdit"
        }
    }
}
```

Test helper for shorter assertions: change the existing test cases to compare via `.tag`. Update `BootstrapDeciderTests`'s `XCTAssertEqual(d.action, .noOp)` etc. to either keep the full-equality comparison or use:

```swift
XCTAssertEqual(d.action.tag, "noOp")
```

For now, keep the explicit `.noOp` / `.pushLocal` / `.rejectMerge(reason: .schemaNewerThanLocal)` literal comparisons; for `.applyCloud` use `.tag` comparison. Update Test:

```swift
// branch3
XCTAssertEqual(d.action.tag, "applyCloud")
// branch4
XCTAssertEqual(d.action.tag, "applyCloud")
// branch5 — pushLocal stays as is
// branch7
XCTAssertEqual(d.action, .rejectMerge(reason: .schemaNewerThanLocal))
```

- [ ] **Step 4: Implement `BootstrapDecider`**

Create `apps/macos/Sources/SettingsSyncStore/BootstrapDecider.swift`:

```swift
import Foundation
import SettingsStore

public enum BootstrapDecider {
    public static func decide(
        local: CatermSettings,
        cloud: SyncableSettings?,
        bootStartedAt: Date,
        knownMigrations: Set<String>
    ) -> Decision {
        let localIsSeed = IsDefaultSeedUnedited.evaluate(local, knownMigrations: knownMigrations)

        guard let cloud = cloud else {
            // No cloud data.
            if localIsSeed {
                return Decision(action: .noOp, finalSuspensionState: false, acceptIdentity: true)
            } else {
                return Decision(action: .pushLocal, finalSuspensionState: false, acceptIdentity: true)
            }
        }

        if cloud.version > local.version {
            return Decision(
                action: .rejectMerge(reason: .schemaNewerThanLocal),
                finalSuspensionState: false,
                acceptIdentity: true
            )
        }

        if localIsSeed {
            return Decision(action: .applyCloud(cloud), finalSuspensionState: false, acceptIdentity: true)
        }

        if cloud.revision == local.revision {
            return Decision(action: .noOp, finalSuspensionState: false, acceptIdentity: true)
        }

        // Both have real edits. Doc-level revision LWW with clock-skew sanity.
        let cloudWins = cloud.revision > local.revision
        let clockSkewSuspect: Bool = {
            guard cloudWins, let firstEdit = local.firstUserEditedAt else { return false }
            return firstEdit > bootStartedAt
        }()

        if cloudWins && !clockSkewSuspect {
            return Decision(action: .applyCloud(cloud), finalSuspensionState: false, acceptIdentity: true)
        } else {
            return Decision(action: .pushLocal, finalSuspensionState: false, acceptIdentity: true)
        }
    }
}
```

- [ ] **Step 5: Run, confirm passing**

Run: `cd apps/macos && swift test --filter BootstrapDeciderTests 2>&1 | tail -20`
Expected: all 8 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/Decision.swift \
        apps/macos/Sources/SettingsSyncStore/BootstrapDecider.swift \
        apps/macos/Tests/SettingsSyncStoreTests/BootstrapDeciderTests.swift
git commit -m "feat(settings-sync): Decision type + BootstrapDecider with 8 branches"
```

---

### Task 9: `AccountSwitchHandler`

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/AccountSwitchHandler.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/AccountSwitchHandlerTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/AccountSwitchHandlerTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

final class AccountSwitchHandlerTests: XCTestCase {
    private func realEdits(revision: String = "local-x") -> CatermSettings {
        var s = CatermSettings()
        s.global = CatermSettings.defaultsSeed
        s.global.fontSize = 99
        s.seededByDefault = false
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        s.revision = revision
        s.version = 2
        return s
    }

    private func cloud(revision: String, version: Int = 2) -> SyncableSettings {
        var c = SyncableSettings(from: realEdits(revision: revision))
        c.version = version
        return c
    }

    func test_yHasData_schemaCompatible_returnsForceApply_acceptsIdentity() {
        // Local revision NEWER than Y's — proves no LWW comparison happens.
        let d = AccountSwitchHandler.handle(
            local: realEdits(revision: "z"),
            cloudY: cloud(revision: "a")
        )
        XCTAssertEqual(d.action.tag, "forceApply")
        XCTAssertFalse(d.finalSuspensionState)
        XCTAssertTrue(d.acceptIdentity)
    }

    func test_yHasData_schemaNewer_returnsRejectMerge_doesNotAcceptIdentity() {
        let d = AccountSwitchHandler.handle(
            local: realEdits(),
            cloudY: cloud(revision: "z", version: 3)
        )
        XCTAssertEqual(d.action, .rejectMerge(reason: .schemaNewerThanLocal))
        XCTAssertTrue(d.finalSuspensionState, "stay suspended; don't pollute Y")
        XCTAssertFalse(d.acceptIdentity, "do not persist Y identity — we have no readable Y data")
    }

    func test_yEmpty_returnsSuspendUntilFirstEdit_doesNotAcceptIdentity() {
        let d = AccountSwitchHandler.handle(local: realEdits(), cloudY: nil)
        XCTAssertEqual(d.action, .suspendUntilFirstEdit)
        XCTAssertTrue(d.finalSuspensionState)
        XCTAssertFalse(d.acceptIdentity, "token persists later, at unfreeze + push moment")
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter AccountSwitchHandlerTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement `AccountSwitchHandler`**

Create `apps/macos/Sources/SettingsSyncStore/AccountSwitchHandler.swift`:

```swift
import Foundation
import SettingsStore

public enum AccountSwitchHandler {
    /// Cross-identity transitions: cloud Y is force-applied if schema-compatible
    /// (no revision LWW; local revision belonged to identity X and is meaningless
    /// under Y). Empty Y / schema-newer Y stay suspended and DO NOT persist the
    /// new token — that happens only when the user explicitly accepts identity Y
    /// by editing under it (suspendUntilFirstEdit unfreeze flow) or when Y data
    /// is force-applied.
    public static func handle(
        local: CatermSettings,
        cloudY: SyncableSettings?
    ) -> Decision {
        guard let y = cloudY else {
            return Decision(
                action: .suspendUntilFirstEdit,
                finalSuspensionState: true,
                acceptIdentity: false
            )
        }
        if y.version > local.version {
            return Decision(
                action: .rejectMerge(reason: .schemaNewerThanLocal),
                finalSuspensionState: true,
                acceptIdentity: false
            )
        }
        return Decision(
            action: .forceApply(y),
            finalSuspensionState: false,
            acceptIdentity: true
        )
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter AccountSwitchHandlerTests 2>&1 | tail -10`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/AccountSwitchHandler.swift \
        apps/macos/Tests/SettingsSyncStoreTests/AccountSwitchHandlerTests.swift
git commit -m "feat(settings-sync): AccountSwitchHandler with force-apply / suspend / reject"
```

---

## Phase 3 — IO adapters

### Task 10: `KVSAdapter` protocol + `NSUbiquitousKeyValueStore` impl + reason classifier

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/KVSAdapter.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/KVSAdapterTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/KVSAdapterTests.swift`:

```swift
import XCTest
@testable import SettingsSyncStore

final class KVSAdapterTests: XCTestCase {
    func test_classify_mapsKnownReasons() {
        XCTAssertEqual(KVSReasonClassifier.classify(0), .serverChange)
        XCTAssertEqual(KVSReasonClassifier.classify(1), .initialSyncChange)
        XCTAssertEqual(KVSReasonClassifier.classify(2), .quotaViolationChange)
        XCTAssertEqual(KVSReasonClassifier.classify(3), .accountChange)
        XCTAssertEqual(KVSReasonClassifier.classify(99), .unknown(99))
    }

    func test_classify_handlesNilAsUnknown() {
        XCTAssertEqual(KVSReasonClassifier.classify(nil), .unknown(-1))
    }

    func test_fakeKVS_setAndGet_roundTrip() {
        let kvs = FakeKVS()
        let payload = "hello".data(using: .utf8)!
        kvs.set(payload, forKey: "test")
        XCTAssertEqual(kvs.data(forKey: "test"), payload)
        XCTAssertTrue(kvs.synchronize())
    }

    func test_fakeKVS_remove() {
        let kvs = FakeKVS()
        kvs.set(Data([1]), forKey: "k")
        kvs.removeObject(forKey: "k")
        XCTAssertNil(kvs.data(forKey: "k"))
    }

    func test_fakeKVS_dictionaryRepresentation() {
        let kvs = FakeKVS()
        kvs.set(Data([1]), forKey: "a")
        kvs.set(Data([2]), forKey: "b")
        let rep = kvs.dictionaryRepresentation()
        XCTAssertEqual((rep["a"] as? Data), Data([1]))
        XCTAssertEqual((rep["b"] as? Data), Data([2]))
    }
}
```

- [ ] **Step 2: Run, confirm fail (compile)**

Run: `cd apps/macos && swift test --filter KVSAdapterTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement `KVSProtocol`, `KVSReasonClassifier`, `FakeKVS`, `NSUbiquitousKeyValueStoreAdapter`**

Create `apps/macos/Sources/SettingsSyncStore/KVSAdapter.swift`:

```swift
import Foundation

/// Slimmed-down surface of NSUbiquitousKeyValueStore so tests can substitute
/// a FakeKVS. Apple's contract:
///   - set(_:forKey:) returns Void; no in-band failure signal.
///   - synchronize() returns Bool indicating local persistence to user
///     defaults succeeded — NOT that the upload to iCloud completed.
///   - Quota / account / server / initial-sync changes arrive only via the
///     external-change notification.
public protocol KVSProtocol: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
    func dictionaryRepresentation() -> [String: Any]
}

extension NSUbiquitousKeyValueStore: KVSProtocol {
    // Apple's NSUbiquitousKeyValueStore already exposes these methods with
    // the matching signatures, so the conformance is empty.
}

public enum KVSChangeReason: Equatable {
    case serverChange
    case initialSyncChange
    case quotaViolationChange
    case accountChange
    case unknown(Int)
}

public enum KVSReasonClassifier {
    /// Classifies the integer in
    /// `userInfo[NSUbiquitousKeyValueStoreChangeReasonKey]` for
    /// `didChangeExternallyNotification`.
    public static func classify(_ raw: Int?) -> KVSChangeReason {
        guard let raw = raw else { return .unknown(-1) }
        switch raw {
        case Int(NSUbiquitousKeyValueStoreServerChange): return .serverChange
        case Int(NSUbiquitousKeyValueStoreInitialSyncChange): return .initialSyncChange
        case Int(NSUbiquitousKeyValueStoreQuotaViolationChange): return .quotaViolationChange
        case Int(NSUbiquitousKeyValueStoreAccountChange): return .accountChange
        default: return .unknown(raw)
        }
    }
}

/// Test fake. Concurrency: tests are single-threaded so internal storage
/// is not synchronized.
public final class FakeKVS: KVSProtocol {
    private var storage: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { storage[key] }
    public func set(_ data: Data, forKey key: String) { storage[key] = data }
    public func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    public func synchronize() -> Bool { true }
    public func dictionaryRepresentation() -> [String: Any] { storage }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter KVSAdapterTests 2>&1 | tail -10`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/KVSAdapter.swift \
        apps/macos/Tests/SettingsSyncStoreTests/KVSAdapterTests.swift
git commit -m "feat(settings-sync): KVSProtocol + reason classifier + FakeKVS"
```

---

### Task 11: `IdentityTokenStore`

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/IdentityTokenStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/IdentityTokenStoreTests.swift`

- [ ] **Step 1: Write failing test (round-trip + non-secure-coding fake + sentinel)**

Create `apps/macos/Tests/SettingsSyncStoreTests/IdentityTokenStoreTests.swift`:

```swift
import XCTest
@testable import SettingsSyncStore

final class IdentityTokenStoreTests: XCTestCase {
    /// Conforms only to NSCoding & NSCopying & NSObjectProtocol, NOT NSSecureCoding.
    /// This is the regression guard against accidentally re-enabling
    /// requiringSecureCoding on the archive call.
    final class NonSecureFakeToken: NSObject, NSCoding, NSCopying {
        let payload: String
        init(_ p: String) { self.payload = p }
        required init?(coder: NSCoder) {
            self.payload = coder.decodeObject(forKey: "p") as? String ?? ""
        }
        func encode(with coder: NSCoder) { coder.encode(payload, forKey: "p") }
        func copy(with zone: NSZone? = nil) -> Any { NonSecureFakeToken(payload) }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? NonSecureFakeToken)?.payload == payload
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_archiveAndUnarchive_roundTripWithoutSecureCoding() throws {
        let defaults = makeDefaults()
        let store = IdentityTokenStore(userDefaults: defaults)
        let token = NonSecureFakeToken("user-A")

        store.persist(token)
        let loaded = store.loadPersisted()
        guard case .token(let unarchived) = loaded else {
            XCTFail("expected .token, got \(loaded)")
            return
        }
        XCTAssertTrue(unarchived.isEqual(token))
    }

    func test_isEqual_acrossArchiveBoundary() throws {
        let defaults = makeDefaults()
        let store = IdentityTokenStore(userDefaults: defaults)
        let a = NonSecureFakeToken("X")
        let b = NonSecureFakeToken("Y")

        store.persist(a)
        guard case .token(let unarchivedA) = store.loadPersisted() else {
            XCTFail("expected .token"); return
        }
        XCTAssertTrue(unarchivedA.isEqual(a))
        XCTAssertFalse(unarchivedA.isEqual(b))
    }

    func test_loadPersisted_returnsNil_whenNothingStored() {
        let defaults = makeDefaults()
        let store = IdentityTokenStore(userDefaults: defaults)
        XCTAssertEqual(store.loadPersisted(), .none)
    }

    func test_loadPersisted_returnsArchiveFailedSentinel_whenSentinelStored() {
        let defaults = makeDefaults()
        let store = IdentityTokenStore(userDefaults: defaults)
        store.persistSentinel()
        XCTAssertEqual(store.loadPersisted(), .archiveFailed)
    }

    func test_loadPersisted_returnsNil_whenDataIsCorrupted() {
        let defaults = makeDefaults()
        let store = IdentityTokenStore(userDefaults: defaults)
        defaults.set(Data([0xFF, 0xFE, 0xFD]), forKey: IdentityTokenStore.userDefaultsKey)
        XCTAssertEqual(store.loadPersisted(), .none)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter IdentityTokenStoreTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement `IdentityTokenStore`**

Create `apps/macos/Sources/SettingsSyncStore/IdentityTokenStore.swift`:

```swift
import Foundation

/// What we read back from UserDefaults for the persisted token.
public enum PersistedTokenLoad: Equatable {
    case none
    case archiveFailed                              // sentinel observed
    case token(NSObject & NSCoding & NSCopying)

    public static func == (lhs: PersistedTokenLoad, rhs: PersistedTokenLoad) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.archiveFailed, .archiveFailed): return true
        case (.token(let a), .token(let b)): return a.isEqual(b)
        default: return false
        }
    }
}

public final class IdentityTokenStore {
    public static let userDefaultsKey = "caterm.settings.lastUbiquityIdentityToken"
    private static let sentinelString = "<archive-failed>"

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    /// Archive token with `requiringSecureCoding: false`. Apple only documents
    /// `ubiquityIdentityToken` as `NSCoding & NSCopying & NSObjectProtocol`,
    /// NOT `NSSecureCoding`. Forcing secure coding would throw on real-world
    /// tokens, drop us into firstObservation on every launch, and after an
    /// account switch reintroduce cross-identity LWW via BootstrapDecider.
    public func persist(_ token: NSObject & NSCoding & NSCopying) {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: token, requiringSecureCoding: false
            )
            defaults.set(data, forKey: Self.userDefaultsKey)
        } catch {
            NSLog("[IdentityTokenStore] archive failed: \(error). Persisting sentinel.")
            persistSentinel()
        }
    }

    public func persistSentinel() {
        let sentinel = Self.sentinelString.data(using: .utf8)!
        defaults.set(sentinel, forKey: Self.userDefaultsKey)
    }

    public func loadPersisted() -> PersistedTokenLoad {
        guard let data = defaults.data(forKey: Self.userDefaultsKey) else { return .none }
        if data == Self.sentinelString.data(using: .utf8) {
            return .archiveFailed
        }
        do {
            // We do NOT know the concrete class of the token, so use the
            // non-secure unarchiver. Cast back to NSObject & NSCoding & NSCopying.
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            guard let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
            else { return .none }
            // We trust the cast: the original archived value implemented NSCoding;
            // upcasts here are always safe at runtime via NSObject.
            // The compiler is satisfied with the cast even though the token type
            // is opaque.
            guard let token = obj as? (NSObject & NSCoding & NSCopying) else { return .none }
            return .token(token)
        } catch {
            return .none
        }
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter IdentityTokenStoreTests 2>&1 | tail -10`
Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/IdentityTokenStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/IdentityTokenStoreTests.swift
git commit -m "feat(settings-sync): IdentityTokenStore with non-secure archiver + sentinel"
```

---

## Phase 4 — `SettingsSyncStore` coordinator

### Task 12: `SettingsSyncStore` skeleton + lifecycle observers

**Files:**
- Create: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/SettingsSyncStoreLifecycleTests.swift`

- [ ] **Step 1: Write failing test for `installLifecycleObservers` + idempotent `startSync`**

Create `apps/macos/Tests/SettingsSyncStoreTests/SettingsSyncStoreLifecycleTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class SettingsSyncStoreLifecycleTests: XCTestCase {
    private func makeStore() throws -> (SettingsStore, FakeKVS, IdentityTokenStore, UserDefaults) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        return (store, kvs, tokenStore, defaults)
    }

    func test_init_doesNotRegisterAnyObservers() throws {
        let (store, kvs, tokenStore, _) = try makeStore()
        let session = AlwaysSignedInSession()
        let _ = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { nil }
        )
        // Observers are registered only via installLifecycleObservers().
        // Sentinel: posting catermICloudAccountChanged here must NOT call startSync.
        XCTAssertFalse(session.refreshCalled)
    }

    func test_startSync_isIdempotent() async throws {
        let (store, kvs, tokenStore, _) = try makeStore()
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken("user-A") }
        )
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.startSync()  // second call must be a no-op
        XCTAssertEqual(sync.startSyncCallCount, 2)
        XCTAssertEqual(sync.observersRegisteredCount, 1)
    }

    func test_signedOutCold_startSync_doesNotRegisterSyncObservers() async throws {
        let (store, kvs, tokenStore, _) = try makeStore()
        let session = AlwaysSignedOutSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { nil }
        )
        sync.installLifecycleObservers()
        await sync.startSync()
        XCTAssertEqual(sync.observersRegisteredCount, 0)
    }
}

// MARK: - Test doubles
final class AlwaysSignedInSession: AccountSessionProviding {
    var isSignedIn: Bool = true
    var refreshCalled = false
    func refresh() async { refreshCalled = true }
}

final class AlwaysSignedOutSession: AccountSessionProviding {
    var isSignedIn: Bool = false
    func refresh() async {}
}

final class TestToken: NSObject, NSCoding, NSCopying {
    let id: String
    init(_ id: String) { self.id = id }
    required init?(coder: NSCoder) { self.id = coder.decodeObject(forKey: "i") as? String ?? "" }
    func encode(with coder: NSCoder) { coder.encode(id, forKey: "i") }
    func copy(with zone: NSZone? = nil) -> Any { TestToken(id) }
    override func isEqual(_ object: Any?) -> Bool { (object as? TestToken)?.id == id }
}
```

- [ ] **Step 2: Run, confirm fail (compile)**

Run: `cd apps/macos && swift test --filter SettingsSyncStoreLifecycleTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement `AccountSessionProviding` + `SettingsSyncStore` skeleton**

Create `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`:

```swift
import Foundation
import SettingsStore

/// Minimal surface of CloudKit's iCloudAccountSession we depend on, so this
/// module doesn't link CloudKit directly — the concrete iCloudAccountSession
/// from CloudKitSyncClient implements this implicitly.
public protocol AccountSessionProviding: AnyObject {
    var isSignedIn: Bool { get }
    func refresh() async
}

public extension Notification.Name {
    static let catermICloudAccountChanged =
        Notification.Name("catermICloudAccountChanged")
}

@MainActor
public final class SettingsSyncStore {
    public static let kvsKey = "caterm.settings.v1"

    private let store: SettingsStore
    private let kvs: KVSProtocol
    private let accountSession: AccountSessionProviding
    private let tokenStore: IdentityTokenStore
    private let currentTokenProvider: () -> (NSObject & NSCoding & NSCopying)?

    // Lifecycle observer (app-lifetime)
    private var accountChangeObserver: NSObjectProtocol?

    // Sync observers (registered by startSync, removed by stopSync)
    private var kvsExternalObserver: NSObjectProtocol?
    private var settingsChangeObserver: NSObjectProtocol?

    private var pushSuspended: Bool = true   // initial barrier — cleared by startSync's decision pass
    private var isSyncRunning: Bool = false

    // Test counters
    public private(set) var startSyncCallCount = 0
    public private(set) var observersRegisteredCount = 0

    public init(
        store: SettingsStore,
        kvs: KVSProtocol,
        accountSession: AccountSessionProviding,
        tokenStore: IdentityTokenStore,
        currentTokenProvider: @escaping () -> (NSObject & NSCoding & NSCopying)?
    ) {
        self.store = store
        self.kvs = kvs
        self.accountSession = accountSession
        self.tokenStore = tokenStore
        self.currentTokenProvider = currentTokenProvider
    }

    /// App-lifetime observer for sign-in transitions. Called once at app
    /// startup; the observer is NEVER removed for the life of the process.
    public func installLifecycleObservers() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .catermICloudAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.accountSession.isSignedIn && !self.isSyncRunning {
                    await self.startSync()
                } else if !self.accountSession.isSignedIn && self.isSyncRunning {
                    self.stopSync()
                }
            }
        }
    }

    public func startSync() async {
        startSyncCallCount += 1
        if isSyncRunning { return }    // idempotent
        guard accountSession.isSignedIn else { return }
        isSyncRunning = true
        observersRegisteredCount += 1
        // Sync observers will be wired in Task 13–18.
        // For Task 12 we just track that startSync was invoked.
    }

    public func stopSync() {
        guard isSyncRunning else { return }
        isSyncRunning = false
        if let token = kvsExternalObserver {
            NotificationCenter.default.removeObserver(token)
            kvsExternalObserver = nil
        }
        if let token = settingsChangeObserver {
            NotificationCenter.default.removeObserver(token)
            settingsChangeObserver = nil
        }
        pushSuspended = true
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter SettingsSyncStoreLifecycleTests 2>&1 | tail -10`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/SettingsSyncStoreLifecycleTests.swift
git commit -m "feat(settings-sync): SettingsSyncStore lifecycle — install/start/stop"
```

---

### Task 13: Token classifier inside `SettingsSyncStore`

**Files:**
- Modify: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/TokenClassificationTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/TokenClassificationTests.swift`:

```swift
import XCTest
@testable import SettingsSyncStore

@MainActor
final class TokenClassificationTests: XCTestCase {
    private func classifier(_ persisted: PersistedTokenLoad,
                            _ current: (NSObject & NSCoding & NSCopying)?) -> TokenClassification {
        return TokenClassifier.classify(persisted: persisted, current: current)
    }

    func test_bothNil_isNotSignedIn() {
        XCTAssertEqual(classifier(.none, nil), .notSignedIn)
    }

    func test_persistedNoneAndCurrentNonNil_isFirstObservation() {
        let t = TestToken("X")
        XCTAssertEqual(classifier(.none, t), .firstObservation)
    }

    func test_persistedTokenAndCurrentNil_isSignedOut() {
        let prev = TestToken("X")
        XCTAssertEqual(classifier(.token(prev), nil), .signedOut)
    }

    func test_persistedAndCurrent_equal_isIdentitySame() {
        let prev = TestToken("X")
        let curr = TestToken("X")
        XCTAssertEqual(classifier(.token(prev), curr), .identitySame)
    }

    func test_persistedAndCurrent_different_isIdentityChanged() {
        let prev = TestToken("X")
        let curr = TestToken("Y")
        XCTAssertEqual(classifier(.token(prev), curr), .identityChanged)
    }

    func test_archiveFailedSentinel_isUnknownPrevious_regardlessOfCurrent() {
        XCTAssertEqual(classifier(.archiveFailed, nil), .unknownPrevious)
        XCTAssertEqual(classifier(.archiveFailed, TestToken("Z")), .unknownPrevious)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter TokenClassificationTests 2>&1 | tail -15`
Expected: compile error.

- [ ] **Step 3: Add `TokenClassification` enum + `TokenClassifier` to module**

In `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`, append:

```swift
public enum TokenClassification: Equatable {
    case notSignedIn
    case firstObservation     // prev nil, curr non-nil — no prior identity to leak
    case identitySame         // prev and curr both non-nil and isEqual
    case identityChanged      // prev and curr both non-nil and NOT isEqual
    case signedOut            // prev non-nil, curr nil
    case unknownPrevious      // sentinel "<archive-failed>" — route conservatively
}

public enum TokenClassifier {
    public static func classify(
        persisted: PersistedTokenLoad,
        current: (NSObject & NSCoding & NSCopying)?
    ) -> TokenClassification {
        if case .archiveFailed = persisted { return .unknownPrevious }
        switch (persisted, current) {
        case (.none, nil): return .notSignedIn
        case (.none, _?): return .firstObservation
        case (.token, nil): return .signedOut
        case (.token(let prev), let curr?):
            return prev.isEqual(curr) ? .identitySame : .identityChanged
        default: return .notSignedIn   // unreachable; .archiveFailed handled above
        }
    }
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter TokenClassificationTests 2>&1 | tail -10`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/TokenClassificationTests.swift
git commit -m "feat(settings-sync): TokenClassifier with 6 routing classifications"
```

---

### Task 14: Boot-sequence write barrier + grace + decision dispatch

**Files:**
- Modify: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/BootSequenceTests.swift`

- [ ] **Step 1: Write failing test for boot decision dispatch + acceptIdentity gating**

Create `apps/macos/Tests/SettingsSyncStoreTests/BootSequenceTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class BootSequenceTests: XCTestCase {
    private func makeStore(
        local: CatermSettings = CatermSettings(),
        kvsBlob: Data? = nil,
        currentToken: (NSObject & NSCoding & NSCopying)? = nil,
        persistedToken: PersistedTokenLoad = .none,
        signedIn: Bool = true
    ) throws -> (SettingsSyncStore, SettingsStore, FakeKVS, IdentityTokenStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boot-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: local, path: tmp)
        let kvs = FakeKVS()
        if let b = kvsBlob { kvs.set(b, forKey: SettingsSyncStore.kvsKey) }
        let defaults = UserDefaults(suiteName: "boot-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        switch persistedToken {
        case .none: break
        case .archiveFailed: tokenStore.persistSentinel()
        case .token(let t): tokenStore.persist(t)
        }
        let session = signedIn ? AlwaysSignedInSession() : AlwaysSignedOutSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session,
            tokenStore: tokenStore,
            currentTokenProvider: { currentToken }
        )
        sync.installLifecycleObservers()
        // Boot wait timeout shortened so tests run fast.
        sync.testInitialSyncTimeout = .milliseconds(50)
        sync.testInitialSyncGrace = .milliseconds(10)
        return (sync, store, kvs, tokenStore)
    }

    private func encodedBlob(revision: String, fontSize: Int = 99) throws -> Data {
        var s = CatermSettings()
        s.global.fontSize = fontSize
        s.revision = revision
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        return try SettingsBlobCodec.encode(s)
    }

    func test_boot_firstObservation_emptyKVS_realLocal_pushesAndPersistsToken() async throws {
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "local-r"
        let curr = TestToken("user-A")
        let (sync, _, kvs, tokenStore) = try makeStore(
            local: local, kvsBlob: nil, currentToken: curr, persistedToken: .none
        )
        await sync.startSync()
        await sync.testWaitForBootDecision()
        // pushed
        let blob = kvs.data(forKey: SettingsSyncStore.kvsKey)
        XCTAssertNotNil(blob)
        // identity persisted
        guard case .token(let t) = tokenStore.loadPersisted() else {
            XCTFail("token not persisted"); return
        }
        XCTAssertTrue(t.isEqual(curr))
        // pushSuspended = false now
        XCTAssertFalse(sync.testPushSuspended)
    }

    func test_boot_identityChanged_yEmpty_doesNotPersistToken_staysSuspended() async throws {
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev"
        let prevToken = TestToken("user-X")
        let currToken = TestToken("user-Y")
        let (sync, _, kvs, tokenStore) = try makeStore(
            local: local, kvsBlob: nil,
            currentToken: currToken, persistedToken: .token(prevToken)
        )
        await sync.startSync()
        await sync.testWaitForBootDecision()
        // KVS empty — handler returned suspendUntilFirstEdit
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
        // Token NOT advanced — stays at user-X
        guard case .token(let stored) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(stored.isEqual(prevToken),
            "token must NOT advance until user accepts identity Y by editing")
        XCTAssertTrue(sync.testPushSuspended)
    }

    func test_boot_identityChanged_yHasData_forceApplies_persistsNewToken() async throws {
        let blob = try encodedBlob(revision: "y-rev", fontSize: 21)
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev-newer-than-y"
        let prevToken = TestToken("user-X")
        let currToken = TestToken("user-Y")
        let (sync, store, _, tokenStore) = try makeStore(
            local: local, kvsBlob: blob,
            currentToken: currToken, persistedToken: .token(prevToken)
        )
        await sync.startSync()
        await sync.testWaitForBootDecision()
        // Force-apply ignored revision comparison; local now reflects Y
        XCTAssertEqual(store.settings.global.fontSize, 21)
        XCTAssertEqual(store.settings.revision, "y-rev")
        // New token persisted
        guard case .token(let stored) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(stored.isEqual(currToken))
        XCTAssertFalse(sync.testPushSuspended)
    }

    func test_boot_unknownPrevious_routesViaAccountSwitchHandler() async throws {
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev"
        let curr = TestToken("user-A")
        // sentinel persisted — unknownPrevious path
        let (sync, _, kvs, tokenStore) = try makeStore(
            local: local, kvsBlob: nil, currentToken: curr,
            persistedToken: .archiveFailed
        )
        await sync.startSync()
        await sync.testWaitForBootDecision()
        // Treated like identityChanged + Y empty: don't push, don't advance token
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
        XCTAssertEqual(tokenStore.loadPersisted(), .archiveFailed,
            "sentinel preserved; token not advanced under unknownPrevious + Y empty")
        XCTAssertTrue(sync.testPushSuspended)
    }
}
```

- [ ] **Step 2: Run, confirm fail (compile + missing test hooks)**

Run: `cd apps/macos && swift test --filter BootSequenceTests 2>&1 | tail -20`
Expected: compile errors for `testInitialSyncTimeout`, `testInitialSyncGrace`, `testWaitForBootDecision`, `testPushSuspended`.

- [ ] **Step 3: Implement boot decision dispatch + test hooks**

In `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`, replace the existing `startSync()` method and add:

```swift
// Test hooks — only used by tests; harmless in production.
public var testInitialSyncTimeout: Duration = .seconds(3)
public var testInitialSyncGrace: Duration = .milliseconds(500)
public var testPushSuspended: Bool { pushSuspended }
private var bootDecisionTask: Task<Void, Never>?

public func testWaitForBootDecision() async {
    await bootDecisionTask?.value
}

public func startSync() async {
    startSyncCallCount += 1
    if isSyncRunning { return }
    guard accountSession.isSignedIn else { return }
    isSyncRunning = true
    observersRegisteredCount += 1
    pushSuspended = true

    bootDecisionTask = Task { [weak self] in
        await self?.runBootSequence()
    }
}

private func runBootSequence() async {
    // Trigger initial pull and wait briefly. We don't actually subscribe to
    // didChangeExternallyNotification here — production wiring lands in Task
    // 16. For boot we rely on the timeout: KVS.synchronize is called and we
    // wait up to testInitialSyncTimeout milliseconds, then proceed.
    _ = kvs.synchronize()
    try? await Task.sleep(for: testInitialSyncTimeout)

    let bootStartedAt = Date()
    let persisted = tokenStore.loadPersisted()
    let current = currentTokenProvider()
    let classification = TokenClassifier.classify(persisted: persisted, current: current)

    let cloud = decodeCloud()
    let decision: Decision
    switch classification {
    case .notSignedIn:
        stopSync()
        return
    case .firstObservation, .identitySame:
        decision = BootstrapDecider.decide(
            local: store.settings, cloud: cloud,
            bootStartedAt: bootStartedAt,
            knownMigrations: knownMigrationsAtBoot()
        )
    case .identityChanged, .unknownPrevious:
        decision = AccountSwitchHandler.handle(
            local: store.settings, cloudY: cloud
        )
    case .signedOut:
        stopSync()
        return
    }

    await applyDecision(decision, currentToken: current)
}

private func decodeCloud() -> SyncableSettings? {
    guard let data = kvs.data(forKey: Self.kvsKey) else { return nil }
    return try? SettingsBlobCodec.decode(data)
}

private func applyDecision(
    _ decision: Decision,
    currentToken: (NSObject & NSCoding & NSCopying)?
) async {
    switch decision.action {
    case .noOp:
        break
    case .pushLocal:
        pushLocalToKVS()
    case .applyCloud(let blob), .forceApply(let blob):
        applyCloudToLocal(blob)
    case .rejectMerge:
        // keep local; do not push
        break
    case .suspendUntilFirstEdit:
        // observer plane will pick up the next user edit and unfreeze
        break
    }
    if decision.acceptIdentity, let token = currentToken {
        tokenStore.persist(token)
    }
    pushSuspended = decision.finalSuspensionState
}

private func pushLocalToKVS() {
    do {
        let blob = try SettingsBlobCodec.encode(store.settings)
        kvs.set(blob, forKey: Self.kvsKey)
        _ = kvs.synchronize()
    } catch {
        NSLog("[SettingsSyncStore] encode/push failed: \(error)")
    }
}

private func applyCloudToLocal(_ blob: SyncableSettings) {
    let next = blob.toLocal(localMigrationsCompleted: store.settings.migrationsCompleted)
    do {
        try store.replaceFromSync(next)
    } catch {
        NSLog("[SettingsSyncStore] replaceFromSync failed: \(error)")
    }
}

private func knownMigrationsAtBoot() -> Set<String> {
    // The single migration token shipped to date.
    return ["settings-gui-v1"]
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter BootSequenceTests 2>&1 | tail -15`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/BootSequenceTests.swift
git commit -m "feat(settings-sync): boot dispatch with classifier + acceptIdentity gating"
```

---

### Task 15: Observer-plane push (with source==sync filter, control-plane bypass)

**Files:**
- Modify: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/PushPlaneTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/PushPlaneTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class PushPlaneTests: XCTestCase {
    private func makeStore() throws -> (SettingsSyncStore, SettingsStore, FakeKVS) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("push-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        store.debounceInterval = .milliseconds(0)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "push-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session,
            tokenStore: tokenStore,
            currentTokenProvider: { TestToken("A") }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()
        return (sync, store, kvs)
    }

    func test_userEdit_postBoot_isPushed() async throws {
        let (sync, store, kvs) = try await makeStore()
        XCTAssertFalse(sync.testPushSuspended)
        store.update { $0.global.fontSize = 18 }
        store.flushNow()
        try await Task.sleep(for: .milliseconds(20))
        let blob = kvs.data(forKey: SettingsSyncStore.kvsKey)
        XCTAssertNotNil(blob, "user edit while not suspended must push")
    }

    func test_syncSourcedChange_isNotRePushed() async throws {
        let (_, store, kvs) = try await makeStore()
        // Erase whatever the boot push put there
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        // Apply a "sync"-sourced change directly (simulating cloud arrival).
        var fromCloud = CatermSettings()
        fromCloud.global.fontSize = 33
        fromCloud.revision = "from-cloud"
        try store.replaceFromSync(fromCloud)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "sync-sourced change must not loop back into a push")
    }

    func test_pushSuspended_skipsObserverPlanePush() async throws {
        let (sync, store, kvs) = try await makeStore()
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        sync.testForcePushSuspended(true)
        store.update { $0.global.fontSize = 88 }
        store.flushNow()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter PushPlaneTests 2>&1 | tail -20`
Expected: compile errors for `testForcePushSuspended` + functional fails.

- [ ] **Step 3: Wire push observer + control-plane vs observer-plane split**

In `SettingsSyncStore.swift`, modify `startSync()` to register the SettingsStore push listener after the boot decision completes. Add a new method `registerSyncObservers()` and call it inside `applyDecision`. Also add `testForcePushSuspended` test hook.

Replace the `startSync()` method body to keep the existing flow but separate observer registration:

```swift
public func startSync() async {
    startSyncCallCount += 1
    if isSyncRunning { return }
    guard accountSession.isSignedIn else { return }
    isSyncRunning = true
    observersRegisteredCount += 1
    pushSuspended = true

    bootDecisionTask = Task { [weak self] in
        await self?.runBootSequence()
        await MainActor.run { self?.registerSyncObservers() }
    }
}

private func registerSyncObservers() {
    if settingsChangeObserver == nil {
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changeNotification, object: store, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleLocalSettingsChange(note: note)
            }
        }
    }
    // KVS external observer is wired in Task 16.
}

private func handleLocalSettingsChange(note: Notification) {
    let source = note.userInfo?[SettingsStore.sourceUserInfoKey] as? String ?? "local"
    if source == "sync" { return }   // feedback-loop guard
    if pushSuspended { return }      // observer plane gated
    pushLocalToKVS()
}

public func testForcePushSuspended(_ v: Bool) { pushSuspended = v }
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter PushPlaneTests 2>&1 | tail -15`
Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/PushPlaneTests.swift
git commit -m "feat(settings-sync): observer-plane push with source filter + suspension gate"
```

---

### Task 16: KVS external-change observer + reason routing

**Files:**
- Modify: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/KVSPullDispatchTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/KVSPullDispatchTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class KVSPullDispatchTests: XCTestCase {
    private func setup() async throws -> (SettingsSyncStore, SettingsStore, FakeKVS) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: CatermSettings(), path: tmp)
        store.debounceInterval = .milliseconds(0)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "pull-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session,
            tokenStore: tokenStore,
            currentTokenProvider: { TestToken("A") }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()
        return (sync, store, kvs)
    }

    func test_serverChange_appliesCloud() async throws {
        let (sync, store, kvs) = try await setup()
        var cloud = CatermSettings()
        cloud.global.fontSize = 42
        cloud.revision = "cloud-rev"
        cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreServerChange)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.settings.global.fontSize, 42)
        XCTAssertEqual(store.settings.revision, "cloud-rev")
    }

    func test_initialSyncChange_extendsBarrier_thenApplies() async throws {
        let (sync, store, kvs) = try await setup()
        // Use a measurable grace so we can observe it.
        sync.testInitialSyncGrace = .milliseconds(50)
        var cloud = CatermSettings()
        cloud.global.fontSize = 77
        cloud.revision = "after-grace"
        cloud.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloud), forKey: SettingsSyncStore.kvsKey)
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        // immediately: pushSuspended must be true (barrier extended)
        XCTAssertTrue(sync.testPushSuspended)
        try await Task.sleep(for: .milliseconds(80))
        // post-grace: applied
        XCTAssertEqual(store.settings.global.fontSize, 77)
    }

    func test_quotaChange_doesNotApplyOrChangeSuspension() async throws {
        let (sync, store, _) = try await setup()
        let originalSize = store.settings.global.fontSize
        let originalSuspended = sync.testPushSuspended
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreQuotaViolationChange)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.settings.global.fontSize, originalSize)
        XCTAssertEqual(sync.testPushSuspended, originalSuspended)
    }

    func test_accountChange_reclassifies_firstObservation_pushesViaBootstrap() async throws {
        // Start signed-out so persisted token stays nil. Then signal account-change
        // with a current token present.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-\(UUID().uuidString).plist")
        var local = CatermSettings()
        local.global.fontSize = 19
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "fresh"
        let store = SettingsStore(settings: local, path: tmp)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "ac-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken("first") }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()
        // Boot already classified firstObservation and pushed local. Erase KVS to test that
        // a subsequent .accountChange with an unchanged token (still firstObservation logic
        // would re-fire but persisted token now exists, so this case becomes identitySame)
        // → BootstrapDecider with cloud nil + local real → pushLocal again.
        kvs.removeObject(forKey: SettingsSyncStore.kvsKey)
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreAccountChange)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            ".accountChange routes via classifier; identitySame + cloud nil → push")
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter KVSPullDispatchTests 2>&1 | tail -20`
Expected: compile errors for `testPostExternalChange`.

- [ ] **Step 3: Add KVS external-change observer + dispatch logic**

In `SettingsSyncStore.swift`, modify `registerSyncObservers()`:

```swift
private func registerSyncObservers() {
    if settingsChangeObserver == nil {
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changeNotification, object: store, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleLocalSettingsChange(note: note)
            }
        }
    }
    if kvsExternalObserver == nil {
        kvsExternalObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.handleKVSExternalChange(note: note)
            }
        }
    }
}

private func handleKVSExternalChange(note: Notification) {
    let raw = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
    let reason = KVSReasonClassifier.classify(raw)
    Task { @MainActor [weak self] in
        await self?.dispatchPull(reason: reason)
    }
}

private func dispatchPull(reason: KVSChangeReason) async {
    switch reason {
    case .quotaViolationChange:
        NSLog("[SettingsSyncStore] quota violation; key present? \(kvs.data(forKey: Self.kvsKey) != nil)")
        return  // do NOT touch suspension
    case .initialSyncChange:
        // Apple: hydration *in progress*. Extend the barrier, grace, then classify+route.
        pushSuspended = true
        try? await Task.sleep(for: testInitialSyncGrace)
        await classifyAndApply()
    case .serverChange, .accountChange, .unknown:
        await classifyAndApply()
    }
}

private func classifyAndApply() async {
    let bootStartedAt = Date()
    let persisted = tokenStore.loadPersisted()
    let current = currentTokenProvider()
    let classification = TokenClassifier.classify(persisted: persisted, current: current)
    let cloud = decodeCloud()

    let decision: Decision
    switch classification {
    case .notSignedIn:
        stopSync(); return
    case .signedOut:
        stopSync(); return
    case .firstObservation, .identitySame:
        decision = BootstrapDecider.decide(
            local: store.settings, cloud: cloud,
            bootStartedAt: bootStartedAt,
            knownMigrations: knownMigrationsAtBoot()
        )
    case .identityChanged, .unknownPrevious:
        decision = AccountSwitchHandler.handle(local: store.settings, cloudY: cloud)
    }
    await applyDecision(decision, currentToken: current)
}

// Test hook
public func testPostExternalChange(reason: Int) {
    NotificationCenter.default.post(
        name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
        object: nil,
        userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
    )
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter KVSPullDispatchTests 2>&1 | tail -15`
Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/KVSPullDispatchTests.swift
git commit -m "feat(settings-sync): KVS external-change pull dispatch with reason routing"
```

---

### Task 17: AccountSwitchHandler `.initialSyncChange` grace at the dispatch seam

**Files:**
- Modify: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift` (no new code; this task is verifying the path covered by Task 16's `.initialSyncChange` branch + adding a focused test for it inside the account-switch context)
- Create: `apps/macos/Tests/SettingsSyncStoreTests/AccountSwitchInitialSyncGraceTests.swift`

- [ ] **Step 1: Write the focused test**

Create `apps/macos/Tests/SettingsSyncStoreTests/AccountSwitchInitialSyncGraceTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class AccountSwitchInitialSyncGraceTests: XCTestCase {
    func test_accountSwitch_initialSyncChangeGivesGrace_thenForceApplies() async throws {
        // Boot signed in to user-X with persisted token X
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("asg-\(UUID().uuidString).plist")
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev"
        let store = SettingsStore(settings: local, path: tmp)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "asg-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        tokenStore.persist(TestToken("user-X"))
        let session = AlwaysSignedInSession()
        // Switch identity by changing what currentTokenProvider returns.
        var currentTokenIdentity = "user-X"
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken(currentTokenIdentity) }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(60)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()
        XCTAssertFalse(sync.testPushSuspended,
            "boot under user-X with empty Y... wait, this is identitySame — no, bootstrap. Anyway: not suspended.")

        // Now simulate the account flip + cloud Y populated.
        currentTokenIdentity = "user-Y"
        var cloudY = CatermSettings()
        cloudY.global.fontSize = 88
        cloudY.revision = "y-rev"
        cloudY.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        kvs.set(try SettingsBlobCodec.encode(cloudY), forKey: SettingsSyncStore.kvsKey)

        // Send .initialSyncChange — must extend barrier (immediately) then grace then apply.
        sync.testPostExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(sync.testPushSuspended, "barrier active during grace")
        try await Task.sleep(for: .milliseconds(80))
        // Force-applied
        XCTAssertEqual(store.settings.global.fontSize, 88)
        // Token advanced to Y
        guard case .token(let stored) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(stored.isEqual(TestToken("user-Y")))
    }
}
```

- [ ] **Step 2: Run, confirm passing**

Run: `cd apps/macos && swift test --filter AccountSwitchInitialSyncGraceTests 2>&1 | tail -15`
Expected: PASS — Task 16 already implemented the necessary grace at `dispatchPull(reason: .initialSyncChange)`, and `classifyAndApply` handles the account-switch routing.

If this fails, inspect the existing implementation rather than adding new code; the bug is somewhere in the dispatch you already wrote.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Tests/SettingsSyncStoreTests/AccountSwitchInitialSyncGraceTests.swift
git commit -m "test(settings-sync): AccountSwitch + initialSyncChange grace integration"
```

---

### Task 18: First-edit unfreeze flow under `suspendUntilFirstEdit`

**Files:**
- Modify: `apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift`
- Create: `apps/macos/Tests/SettingsSyncStoreTests/FirstEditUnfreezeTests.swift`

- [ ] **Step 1: Write failing test**

Create `apps/macos/Tests/SettingsSyncStoreTests/FirstEditUnfreezeTests.swift`:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

@MainActor
final class FirstEditUnfreezeTests: XCTestCase {
    func test_firstEditUnderSuspend_unfreezesPushesAndPersistsToken() async throws {
        // Setup: identityChanged + Y empty → boot returns suspendUntilFirstEdit.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uf-\(UUID().uuidString).plist")
        var local = CatermSettings()
        local.global.fontSize = 17
        local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        local.revision = "x-rev"
        let store = SettingsStore(settings: local, path: tmp)
        store.debounceInterval = .milliseconds(0)
        let kvs = FakeKVS()
        let defaults = UserDefaults(suiteName: "uf-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        tokenStore.persist(TestToken("user-X"))
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { TestToken("user-Y") }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        await sync.startSync()
        await sync.testWaitForBootDecision()

        // Confirm boot returned suspendUntilFirstEdit
        XCTAssertTrue(sync.testPushSuspended)
        XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
        guard case .token(let stillX) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(stillX.isEqual(TestToken("user-X")), "token MUST still be X pre-edit")

        // First user edit
        store.update { $0.global.fontSize = 25 }
        store.flushNow()
        try await Task.sleep(for: .milliseconds(20))

        // Now: pushed, suspended cleared, token advanced to Y
        XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
            "first edit must push the blob")
        XCTAssertFalse(sync.testPushSuspended)
        guard case .token(let nowY) = tokenStore.loadPersisted() else {
            XCTFail("token missing"); return
        }
        XCTAssertTrue(nowY.isEqual(TestToken("user-Y")),
            "token advances to Y after first edit + push")
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Run: `cd apps/macos && swift test --filter FirstEditUnfreezeTests 2>&1 | tail -15`
Expected: fails — the unfreeze + token-persist sequence is not yet implemented.

- [ ] **Step 3: Implement unfreeze flow inside `handleLocalSettingsChange`**

In `SettingsSyncStore.swift`, replace `handleLocalSettingsChange`:

```swift
private func handleLocalSettingsChange(note: Notification) {
    let source = note.userInfo?[SettingsStore.sourceUserInfoKey] as? String ?? "local"
    if source == "sync" { return }

    if pushSuspended {
        // CRITICAL ORDERING: unfreeze BEFORE the push for this same edit so
        // that quitting after one edit still leaves Y populated.
        pushSuspended = false
        pushLocalToKVS()
        // Now persist the current token — user has accepted identity Y by
        // authoring data under it.
        if let token = currentTokenProvider() {
            tokenStore.persist(token)
        }
        return
    }

    pushLocalToKVS()
}
```

- [ ] **Step 4: Run, confirm passing**

Run: `cd apps/macos && swift test --filter FirstEditUnfreezeTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SettingsSyncStore/SettingsSyncStore.swift \
        apps/macos/Tests/SettingsSyncStoreTests/FirstEditUnfreezeTests.swift
git commit -m "feat(settings-sync): first-edit unfreeze pushes + persists new token"
```

---

## Phase 5 — Wiring + integration tests + docs

### Task 19: `CatermApp` wiring

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`

- [ ] **Step 1: Locate the `CatermApp.init()` block, just below the `liveReload` assignment**

Open `apps/macos/Sources/Caterm/CatermApp.swift`, find:

```swift
self.liveReload = LiveReloadCoordinator(settingsStore: settings)
```

(Around the bottom of `init()`.)

- [ ] **Step 2: Add `SettingsSyncStore` import + property + construction**

At the top of the file, near the existing `import SettingsStore`:

```swift
import SettingsSyncStore
```

In the `CatermApp` struct, add a stored property near the other `@StateObject`s:

```swift
private let settingsSync: SettingsSyncStore
```

After the `self.liveReload = LiveReloadCoordinator(...)` line, add:

```swift
let tokenStore = IdentityTokenStore()
let kvsAdapter: KVSProtocol = NSUbiquitousKeyValueStore.default
self.settingsSync = SettingsSyncStore(
    store: settings,
    kvs: kvsAdapter,
    accountSession: icloudSession,
    tokenStore: tokenStore,
    currentTokenProvider: { FileManager.default.ubiquityIdentityToken as? (NSObject & NSCoding & NSCopying) }
)
self.settingsSync.installLifecycleObservers()
Task { @MainActor [settingsSync] in
    await settingsSync.startSync()
}
```

- [ ] **Step 3: Confirm `iCloudAccountSession` conforms to `AccountSessionProviding`**

`iCloudAccountSession` (in `CloudKitSyncClient`) already exposes `var isSignedIn: Bool` and `func refresh() async`. Add an explicit conformance shim file:

Create `apps/macos/Sources/CloudKitSyncClient/iCloudAccountSession+SettingsSyncStore.swift`:

```swift
import SettingsSyncStore

extension iCloudAccountSession: AccountSessionProviding {}
```

Also add `SettingsSyncStore` as a dependency of the `CloudKitSyncClient` library target in `Package.swift`:

```swift
.target(
    name: "CloudKitSyncClient",
    dependencies: ["ServerSyncClient", "SSHCommandBuilder", "CredentialSyncTypes", "SettingsSyncStore"],
    path: "Sources/CloudKitSyncClient"
),
```

- [ ] **Step 4: Build the whole project**

Run: `cd apps/macos && swift build 2>&1 | tail -20`
Expected: success.

Run the full test suite for regressions:

Run: `cd apps/macos && swift test 2>&1 | tail -30`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Package.swift \
        apps/macos/Sources/Caterm/CatermApp.swift \
        apps/macos/Sources/CloudKitSyncClient/iCloudAccountSession+SettingsSyncStore.swift
git commit -m "feat(settings-sync): wire SettingsSyncStore into CatermApp"
```

---

### Task 20: Two-Mac integration test suite

**Files:**
- Create: `apps/macos/Tests/SettingsSyncStoreTests/TwoMacIntegrationTests.swift`

- [ ] **Step 1: Set up the harness — a `SharedFakeKVS` that two `SettingsSyncStore` instances share**

Append the helper inside the new test file:

```swift
import XCTest
import SettingsStore
@testable import SettingsSyncStore

/// A FakeKVS that broadcasts external-change notifications to all observers.
/// Models the cross-Mac KVS rendezvous behavior in unit-test land.
@MainActor
final class SharedFakeKVS: KVSProtocol {
    private var storage: [String: Data] = [:]
    public init() {}
    public func data(forKey key: String) -> Data? { storage[key] }
    public func set(_ data: Data, forKey key: String) {
        storage[key] = data
        broadcast(reason: NSUbiquitousKeyValueStoreServerChange)
    }
    public func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
        broadcast(reason: NSUbiquitousKeyValueStoreServerChange)
    }
    public func synchronize() -> Bool { true }
    public func dictionaryRepresentation() -> [String: Any] { storage }

    public func broadcast(reason: Int) {
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
        )
    }
}

@MainActor
final class TwoMacIntegrationTests: XCTestCase {
    private struct Mac {
        let store: SettingsStore
        let sync: SettingsSyncStore
        let kvs: SharedFakeKVS
        let tokenStore: IdentityTokenStore
    }

    private func makeMac(
        kvs: SharedFakeKVS,
        local: CatermSettings = CatermSettings(),
        currentToken: NSObject & NSCoding & NSCopying = TestToken("shared")
    ) -> Mac {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-\(UUID().uuidString).plist")
        let store = SettingsStore(settings: local, path: tmp)
        store.debounceInterval = .milliseconds(0)
        let defaults = UserDefaults(suiteName: "mac-\(UUID().uuidString)")!
        let tokenStore = IdentityTokenStore(userDefaults: defaults)
        let session = AlwaysSignedInSession()
        let sync = SettingsSyncStore(
            store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
            currentTokenProvider: { currentToken }
        )
        sync.testInitialSyncTimeout = .milliseconds(10)
        sync.testInitialSyncGrace = .milliseconds(0)
        sync.installLifecycleObservers()
        return Mac(store: store, sync: sync, kvs: kvs, tokenStore: tokenStore)
    }

    private func realLocal(font: Int, revision: String) -> CatermSettings {
        var s = CatermSettings()
        s.global.fontSize = font
        s.firstUserEditedAt = Date(timeIntervalSince1970: 1)
        s.revision = revision
        return s
    }

    // ... tests below
}
```

- [ ] **Step 2: Add scenario 1 — basic propagate**

Inside `TwoMacIntegrationTests`, append:

```swift
func test_scenario1_basicPropagate() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "a-1"))
    let B = makeMac(kvs: kvs, local: CatermSettings())   // fresh-ish
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    await B.sync.startSync(); await B.sync.testWaitForBootDecision()

    A.store.update { $0.global.fontSize = 22 }
    A.store.flushNow()
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(B.store.settings.global.fontSize, 22)
}
```

- [ ] **Step 3: Run scenario 1, confirm passing**

Run: `cd apps/macos && swift test --filter TwoMacIntegrationTests/test_scenario1_basicPropagate 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 4: Add scenario 2 — concurrent both-edit conflict (revision LWW)**

Append:

```swift
func test_scenario2_concurrentBothEdit_revisionLWW() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "rev-A-old"))
    let B = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "rev-Z-newer"))
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    // A pushed its blob with revision "rev-A-old"
    await B.sync.startSync(); await B.sync.testWaitForBootDecision()
    // B booted, saw A's blob in cloud, but B's revision "rev-Z-newer" > A's "rev-A-old".
    // BootstrapDecider returned pushLocal — B's data overwrites A's in KVS.
    try await Task.sleep(for: .milliseconds(50))
    let blob = try SettingsBlobCodec.decode(kvs.data(forKey: SettingsSyncStore.kvsKey)!)
    XCTAssertEqual(blob.revision, "rev-Z-newer")
}
```

- [ ] **Step 5: Add scenario 3 — anti seed-pollution (core)**

Append:

```swift
func test_scenario3_antiSeedPollution() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 21, revision: "a-real"))
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    // A pushed real data.
    var bSeed = CatermSettings.empty
    bSeed.global = CatermSettings.defaultsSeed
    bSeed.seededByDefault = true
    bSeed.seedVersion = 1
    bSeed.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
    bSeed.revision = "b-seed-newer-than-a"   // newer revision
    let B = makeMac(kvs: kvs, local: bSeed)
    await B.sync.startSync(); await B.sync.testWaitForBootDecision()
    // B is default-seed-unedited even though revision is newer → applyCloud, NOT LWW
    XCTAssertEqual(B.store.settings.global.fontSize, 21,
        "B must apply A's real cloud data, not push its newer-revision default seed")
}
```

- [ ] **Step 6: Add scenario 4 — clock-tampered seed**

Append:

```swift
func test_scenario4_clockTamperedSeedStillYields() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 21, revision: "a-real"))
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    var bSeed = CatermSettings.empty
    bSeed.global = CatermSettings.defaultsSeed
    bSeed.seededByDefault = true
    bSeed.seedVersion = 1
    bSeed.canonicalSeedHash = KnownSeedTable.canonicalHash(of: CatermSettings.defaultsSeed)
    bSeed.revision = "z-future-clock-revision"
    let B = makeMac(kvs: kvs, local: bSeed)
    await B.sync.startSync(); await B.sync.testWaitForBootDecision()
    XCTAssertEqual(B.store.settings.global.fontSize, 21,
        "isDefaultSeedUnedited doesn't depend on time — still yields to cloud")
}
```

- [ ] **Step 7: Add scenario 5 — account switch, Y has data, force-apply**

Append:

```swift
func test_scenario5_accountSwitch_yHasData_forceApply() async throws {
    let kvs = SharedFakeKVS()
    let macXTokenStorePath = UserDefaults(suiteName: "x-\(UUID().uuidString)")!
    let macXTokenStore = IdentityTokenStore(userDefaults: macXTokenStorePath)
    macXTokenStore.persist(TestToken("user-X"))

    var local = CatermSettings()
    local.global.fontSize = 99    // X-edited, NEWER than Y
    local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
    local.revision = "z-newer-than-y"

    // Pre-stage Y's cloud data
    var cloudY = CatermSettings()
    cloudY.global.fontSize = 42
    cloudY.firstUserEditedAt = Date(timeIntervalSince1970: 1)
    cloudY.revision = "y-old"
    kvs.set(try SettingsBlobCodec.encode(cloudY), forKey: SettingsSyncStore.kvsKey)

    // Construct mac with persisted X but currentToken Y
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("as-\(UUID().uuidString).plist")
    let store = SettingsStore(settings: local, path: tmp)
    let session = AlwaysSignedInSession()
    let sync = SettingsSyncStore(
        store: store, kvs: kvs, accountSession: session, tokenStore: macXTokenStore,
        currentTokenProvider: { TestToken("user-Y") }
    )
    sync.testInitialSyncTimeout = .milliseconds(10)
    sync.testInitialSyncGrace = .milliseconds(0)
    sync.installLifecycleObservers()
    await sync.startSync()
    await sync.testWaitForBootDecision()

    XCTAssertEqual(store.settings.global.fontSize, 42, "force-apply Y, ignored revision LWW")
    XCTAssertEqual(store.settings.revision, "y-old")
    guard case .token(let t) = macXTokenStore.loadPersisted() else {
        XCTFail("token missing"); return
    }
    XCTAssertTrue(t.isEqual(TestToken("user-Y")), "advanced to Y after force-apply")
}
```

- [ ] **Step 8: Add scenario 6 — Y empty + first edit unfreezes (covered by FirstEditUnfreezeTests but include here as integration)**

```swift
func test_scenario6_accountSwitch_yEmpty_firstEditPushes() async throws {
    let kvs = SharedFakeKVS()
    let defaults = UserDefaults(suiteName: "y-\(UUID().uuidString)")!
    let tokenStore = IdentityTokenStore(userDefaults: defaults)
    tokenStore.persist(TestToken("user-X"))
    var local = CatermSettings()
    local.global.fontSize = 17
    local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
    local.revision = "x-r"
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("y-\(UUID().uuidString).plist")
    let store = SettingsStore(settings: local, path: tmp)
    store.debounceInterval = .milliseconds(0)
    let session = AlwaysSignedInSession()
    let sync = SettingsSyncStore(
        store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
        currentTokenProvider: { TestToken("user-Y") }
    )
    sync.testInitialSyncTimeout = .milliseconds(10)
    sync.testInitialSyncGrace = .milliseconds(0)
    sync.installLifecycleObservers()
    await sync.startSync()
    await sync.testWaitForBootDecision()

    XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
    XCTAssertTrue(sync.testPushSuspended)
    if case .token(let t) = tokenStore.loadPersisted() {
        XCTAssertTrue(t.isEqual(TestToken("user-X")), "still X pre-edit")
    }

    store.update { $0.global.fontSize = 28 }
    store.flushNow()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
    XCTAssertFalse(sync.testPushSuspended)
}
```

- [ ] **Step 9: Add scenarios 7, 8, 9, 10, 11, 12 from the spec**

Append (six more focused tests):

```swift
func test_scenario7_catermICloudAccountChanged_doesNotTriggerSwitch() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "a-1"),
                    currentToken: TestToken("user-A"))
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    XCTAssertFalse(A.sync.testPushSuspended)
    NotificationCenter.default.post(name: .catermICloudAccountChanged, object: nil)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(A.sync.testPushSuspended,
        ".catermICloudAccountChanged with same identity must NOT trigger any account-switch flow")
}

func test_scenario8_initialSyncWriteBarrier() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 13, revision: "a-1"))
    A.sync.testInitialSyncTimeout = .milliseconds(80)
    A.sync.testInitialSyncGrace = .milliseconds(0)
    let pushTask = Task { await A.sync.startSync() }
    try await Task.sleep(for: .milliseconds(10))
    // While boot is still waiting, fire a local edit; observer plane runs but
    // pushSuspended==true so no push lands in KVS yet.
    A.store.update { $0.global.fontSize = 99 }
    A.store.flushNow()
    XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
        "observer-plane push must be suspended during boot wait")
    await pushTask.value
    await A.sync.testWaitForBootDecision()
    // After boot, the local push happens via control plane (BootstrapDecider.pushLocal)
    XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey))
}

func test_scenario8a_firstObservation_pushesViaControlPlane() async throws {
    let kvs = SharedFakeKVS()
    let A = makeMac(kvs: kvs, local: realLocal(font: 17, revision: "a-1"),
                    currentToken: TestToken("first-time"))
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    XCTAssertNotNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
        "firstObservation routes via BootstrapDecider; cloud nil + local real → pushLocal")
    if case .token(let t) = A.tokenStore.loadPersisted() {
        XCTAssertTrue(t.isEqual(TestToken("first-time")),
            "firstObservation accepts identity → token persisted")
    } else {
        XCTFail("token not persisted")
    }
}

func test_scenario8b_archiveFailureSentinel_routesSafely() async throws {
    let kvs = SharedFakeKVS()
    let defaults = UserDefaults(suiteName: "af-\(UUID().uuidString)")!
    let tokenStore = IdentityTokenStore(userDefaults: defaults)
    tokenStore.persistSentinel()
    var local = CatermSettings()
    local.global.fontSize = 17
    local.firstUserEditedAt = Date(timeIntervalSince1970: 1)
    local.revision = "x-r"
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("af-\(UUID().uuidString).plist")
    let store = SettingsStore(settings: local, path: tmp)
    let session = AlwaysSignedInSession()
    let sync = SettingsSyncStore(
        store: store, kvs: kvs, accountSession: session, tokenStore: tokenStore,
        currentTokenProvider: { TestToken("any") }
    )
    sync.testInitialSyncTimeout = .milliseconds(10)
    sync.testInitialSyncGrace = .milliseconds(0)
    sync.installLifecycleObservers()
    await sync.startSync()
    await sync.testWaitForBootDecision()
    XCTAssertNil(kvs.data(forKey: SettingsSyncStore.kvsKey),
        "unknownPrevious + Y empty → suspendUntilFirstEdit; do NOT push")
    XCTAssertEqual(tokenStore.loadPersisted(), .archiveFailed,
        "sentinel preserved; do not advance")
}

func test_scenario9_schemaVersionReject() async throws {
    let kvs = SharedFakeKVS()
    var future = CatermSettings()
    future.version = 3
    future.global.fontSize = 88
    future.revision = "future"
    future.firstUserEditedAt = Date(timeIntervalSince1970: 1)
    kvs.set(try SettingsBlobCodec.encode(future), forKey: SettingsSyncStore.kvsKey)
    let A = makeMac(kvs: kvs, local: realLocal(font: 17, revision: "a-r"))
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    XCTAssertEqual(A.store.settings.global.fontSize, 17,
        "v2 client rejects v3 blob; local untouched")
}

func test_scenario10_migrationsCompletedDoesNotSync() async throws {
    let kvs = SharedFakeKVS()
    var aLocal = realLocal(font: 17, revision: "a-r")
    aLocal.migrationsCompleted = ["settings-gui-v1"]
    let A = makeMac(kvs: kvs, local: aLocal)
    let B = makeMac(kvs: kvs, local: CatermSettings())  // no token in B's set
    await A.sync.startSync(); await A.sync.testWaitForBootDecision()
    await B.sync.startSync(); await B.sync.testWaitForBootDecision()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(B.store.settings.migrationsCompleted.contains("settings-gui-v1"),
        "migrationsCompleted is local-only and must NOT propagate via sync")
}
```

- [ ] **Step 10: Run the full integration suite**

Run: `cd apps/macos && swift test --filter TwoMacIntegrationTests 2>&1 | tail -25`
Expected: all scenarios PASS.

- [ ] **Step 11: Commit**

```bash
git add apps/macos/Tests/SettingsSyncStoreTests/TwoMacIntegrationTests.swift
git commit -m "test(settings-sync): two-Mac integration matrix (scenarios 1–10)"
```

---

### Task 21: Operator-facing documentation

**Files:**
- Create: `docs/macos-cloudkit-settings-sync.md`

- [ ] **Step 1: Write the doc**

Create `docs/macos-cloudkit-settings-sync.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/macos-cloudkit-settings-sync.md
git commit -m "docs(settings-sync): operator-facing architecture doc"
```

---

### Task 22: Manual real-device verification checklist

**Files:**
- Create: `docs/superpowers/plans/2026-05-03-cloudkit-settings-kv-manual-verification.md`

- [ ] **Step 1: Write the checklist**

Create `docs/superpowers/plans/2026-05-03-cloudkit-settings-kv-manual-verification.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-05-03-cloudkit-settings-kv-manual-verification.md
git commit -m "docs(settings-sync): manual real-device verification checklist"
```

---

## Final verification

- [ ] **Step 1: Build the entire project**

Run: `cd apps/macos && swift build 2>&1 | tail -20`
Expected: success, no warnings.

- [ ] **Step 2: Run the entire test suite**

Run: `cd apps/macos && swift test 2>&1 | tail -30`
Expected: all tests PASS, no `XCTSkip`s introduced by Plan D.

- [ ] **Step 3: Inspect the diff statistics**

Run: `git log --stat origin/main..HEAD -- apps/macos/Sources/SettingsSyncStore/ apps/macos/Sources/SettingsStore/ docs/`
Expected: ~600 lines of new code in `SettingsSyncStore`; ~80 lines added to `SettingsStore`; two new docs.

- [ ] **Step 4: Push branch and open a PR referencing this plan + spec**

```bash
git push -u origin beirut-v1
gh pr create --title "feat: Plan D — CloudKit Settings KV sync" \
  --body "Implements [Plan D design](docs/superpowers/specs/2026-05-03-cloudkit-settings-kv-design.md). Two-Mac integration suite covers identity isolation, anti-seed-pollution, schema reject, .initialSyncChange grace, archive-failure sentinel, first-edit unfreeze. Manual verification checklist at docs/superpowers/plans/2026-05-03-cloudkit-settings-kv-manual-verification.md."
```

---

## Definition of done

- Schema bumped to v2; v1→v2 canonical-shape migration verified.
- New module `SettingsSyncStore` ships with 100% of the spec's unit + integration scenarios green.
- `CatermApp` wires the store; `swift build` clean.
- Two-Mac integration tests cover scenarios 1–12 (8 numbered + 8a/8b/9/10).
- Operator doc + manual verification checklist committed.
- No live two-Mac runs failed; if any deferred, link to follow-up issues.
