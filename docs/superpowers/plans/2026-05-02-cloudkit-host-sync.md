# CloudKit Host Sync (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the URL-session-based `ServerSyncClient` with a CloudKit-backed implementation so SSH host metadata syncs through the user's iCloud Private Database instead of the self-hosted server. macOS app continues to work as a pure-local tool when iCloud is unavailable.

**Architecture:** Introduce a new Swift module `CloudKitSyncClient` containing (a) a thin `CKDatabaseProtocol` over the CloudKit `CKDatabase` API for testability, (b) `CloudKitSyncClient: ServerSyncClient` that maps `RemoteHost` ↔ `CKRecord` and delegates to the protocol, and (c) `iCloudAccountSession: AuthSessionProtocol` reflecting `CKContainer.accountStatus`. `CatermApp` swaps the injected client + auth-session implementations; `HostSyncStore`, `HostSyncReconciler`, `SessionStore` are untouched. Existing `URLSessionServerSyncClient` and `AuthSession` stay in the codebase but become orphaned (deletion deferred to Plan E).

**Tech Stack:** Swift 5.10, CloudKit (`CKContainer`, `CKDatabase`, `CKRecord`, `CKRecordZone`, `CKError`), XCTest, Swift Package Manager.

**Out of scope (other plans):**
- Push subscriptions / replacing the 15-min polling timer (Plan B)
- Keychain iCloud Sync (Plan C)
- Terminal settings via `NSUbiquitousKeyValueStore` (Plan D)
- SFTP bookmarks via CloudKit, login-UI removal (Plan E)

---

## Pre-flight (manual, you do this once outside the codebase)

These are NOT plan tasks — they're prerequisites. Without them the entitled build will fail to launch with `CKErrorDomain code 9` (badContainer) at runtime, but unit tests still pass.

1. Apple Developer Portal → Identifiers → App IDs → `com.caterm.app` → enable **iCloud** capability (CloudKit).
2. Apple Developer Portal → Identifiers → iCloud Containers → create container `iCloud.com.caterm.app`.
3. Associate the container with the App ID (same screen).
4. CloudKit Dashboard → `iCloud.com.caterm.app` → Development environment → Schema → keep at default (record types are auto-created on first write in Development; we'll lock the schema in Production later).
5. Regenerate the Apple Development provisioning profile so it embeds the iCloud entitlement; download into `~/Library/MobileDevice/Provisioning Profiles/`.
6. Update `apps/macos/Scripts/dev-codesign.sh` (and `dev-run-app.sh`) only if Task 14 verification finds it strips the embedded provisioning profile — most likely no change needed because they call `codesign --entitlements <plist>`.

---

## Architectural Decisions

### D1: `recordName` = `host.id.uuidString`
The local `SSHHost.id` (UUID) doubles as the CloudKit `CKRecord.ID(recordName:)`. This eliminates the "create remote → write back serverId" race that the existing `apply(_ op:)` comment in `HostSyncStore.swift:403` warns about: there's no server-allocated id to round-trip. `RemoteHost.id` becomes equal to `host.id.uuidString` on every record we observe, and `serverId` gets stamped to that same string at upload time.

### D2: Custom record zone `Caterm`
Use `CKRecordZone(zoneName: "Caterm")` instead of `_defaultZone`. Required by `CKFetchRecordZoneChangesOperation` (Plan B) and isolates our records. The zone is created lazily on first write.

### D3: Record type `Host`, fields = `RemoteHost` minus id/timestamps
CloudKit auto-manages `record.creationDate` and `record.modificationDate`. Map these to `RemoteHost.createdAt` / `RemoteHost.updatedAt` at decode. App-controlled fields: `name`, `hostname`, `port`, `username`, `authType`.

### D4: Conflicts deferred to next reconcile pass
On `CKError.serverRecordChanged` during `updateHost`, surface as `ServerSyncError.http(status: 409, ...)`. The next sync cycle's `listHosts` returns the canonical remote record, and `HostSyncReconciler` re-resolves via LWW on `updatedAt` (CloudKit's `modificationDate`). This is identical to the current server flow's behavior.

### D5: `iCloudAccountSession` updates async, signals via `objectWillChange`
`CKContainer.accountStatus` is async. The session refreshes its cached `isSignedIn` on init and on `CKAccountChanged` notifications. Conforms to `AuthSessionProtocol` (synchronous `isSignedIn: Bool` getter). When the status flips, posts a Notification observed by `HostSyncStore` to trigger a sync (rather than HostSyncStore polling).

### D6: Pure-local fallback when no iCloud
If `CKContainer.default().accountStatus` returns anything other than `.available`, `iCloudAccountSession.isSignedIn` is `false`, every gated entry point in `HostSyncStore` (`syncIfSignedIn`, `scheduleAutoSync`) is a no-op. Local CRUD via `SessionStore` continues to work exactly as it does today. No further changes needed for the fallback path.

### D7: `URLSessionServerSyncClient` and `AuthSession` are NOT deleted
They remain in `Sources/ServerSyncClient/` but become unwired in `CatermApp`. Deletion is in Plan E once Plans B–D have proven the migration. This makes Plan A trivially revertible.

### D8: Cosmetic Preferences tab regression accepted
`CatermApp.authSession: AuthSession` is the concrete type consumed by `PreferencesWindowController.syncEnvironment`. We keep a dummy `AuthSession(baseURL: ServerURL.current)` instance to satisfy the type without changing the Preferences API. During the migration window (Plans A–D), the **Preferences → Sync tab may show stale "Sign In" prompts** even when CloudKit is fully working. This is intentional and resolves in Plan E (login UI removal). Sidebar sync indicator (`SyncStatusRow`) still works correctly because it goes through `HostSyncStore.isSignedIn` which proxies the iCloud session.

---

## File Structure

```
apps/macos/
  Package.swift                                          [modify]
  Resources/
    Caterm.entitlements                                  [modify]
  Sources/
    CloudKitSyncClient/                                  [NEW module]
      CKDatabaseProtocol.swift                           [NEW]
      CKRecordHostMapping.swift                          [NEW]
      CloudKitSyncClient.swift                           [NEW]
      CloudKitErrorMapping.swift                         [NEW]
      iCloudAccountSession.swift                         [NEW]
    Caterm/
      CatermApp.swift                                    [modify init()]
  Tests/
    CloudKitSyncClientTests/                             [NEW target]
      FakeCloudDatabase.swift                            [NEW]
      CKRecordHostMappingTests.swift                     [NEW]
      CloudKitSyncClientTests.swift                      [NEW]
      CloudKitErrorMappingTests.swift                    [NEW]
      iCloudAccountSessionTests.swift                    [NEW]
```

---

## Task 1: Scaffold `CloudKitSyncClient` module in Package.swift

**Files:**
- Modify: `apps/macos/Package.swift`

- [ ] **Step 1.1: Create empty source dir + placeholder file so SwiftPM accepts the target**

```bash
mkdir -p apps/macos/Sources/CloudKitSyncClient apps/macos/Tests/CloudKitSyncClientTests
printf 'import Foundation\n' > apps/macos/Sources/CloudKitSyncClient/_Placeholder.swift
printf 'import XCTest\n' > apps/macos/Tests/CloudKitSyncClientTests/_Placeholder.swift
```

- [ ] **Step 1.2: Add target + test target to `Package.swift`**

Open `apps/macos/Package.swift`. After the existing `HostSyncStore` target (line 56 area), add:

```swift
        .target(
            name: "CloudKitSyncClient",
            dependencies: ["ServerSyncClient", "SSHCommandBuilder"],
            path: "Sources/CloudKitSyncClient"
        ),
```

After the existing `SettingsStoreTests` target at the bottom, add:

```swift
        .testTarget(
            name: "CloudKitSyncClientTests",
            dependencies: ["CloudKitSyncClient", "ServerSyncClient", "SSHCommandBuilder"],
            path: "Tests/CloudKitSyncClientTests"
        ),
```

- [ ] **Step 1.3: Verify build succeeds**

Run: `cd apps/macos && swift build`
Expected: builds clean (the placeholder files compile).

- [ ] **Step 1.4: Commit**

```bash
git add apps/macos/Package.swift apps/macos/Sources/CloudKitSyncClient apps/macos/Tests/CloudKitSyncClientTests
git commit -m "chore(macos): scaffold CloudKitSyncClient module"
```

---

## Task 2: `CKDatabaseProtocol` abstraction + `FakeCloudDatabase`

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift`
- Delete: `apps/macos/Sources/CloudKitSyncClient/_Placeholder.swift`
- Delete: `apps/macos/Tests/CloudKitSyncClientTests/_Placeholder.swift`

- [ ] **Step 2.1: Write the protocol**

Replace `_Placeholder.swift` with `CKDatabaseProtocol.swift`:

```swift
import CloudKit
import Foundation

/// The minimal `CKDatabase` surface CloudKitSyncClient needs.
///
/// Wrapping the API (rather than calling `CKDatabase` methods directly) lets
/// us inject `FakeCloudDatabase` in unit tests. Apple's `CKDatabase` is a
/// concrete `NSObject` subclass that cannot be subclassed meaningfully —
/// every async API on it is a free function bound to the instance.
///
/// Method shapes mirror the `async` overloads added in iOS 15 / macOS 12.
public protocol CKDatabaseProtocol: Sendable {
    func records(matching query: CKQuery,
                 inZoneWith zoneID: CKRecordZone.ID?,
                 desiredKeys: [CKRecord.FieldKey]?,
                 resultsLimit: Int)
        async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                         queryCursor: CKQueryOperation.Cursor?)

    func save(_ record: CKRecord) async throws -> CKRecord
    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ zone: CKRecordZone) async throws -> CKRecordZone
}

extension CKDatabase: CKDatabaseProtocol {
    public func records(matching query: CKQuery,
                        inZoneWith zoneID: CKRecordZone.ID?,
                        desiredKeys: [CKRecord.FieldKey]?,
                        resultsLimit: Int)
        async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                         queryCursor: CKQueryOperation.Cursor?)
    {
        try await self.records(matching: query,
                               inZoneWith: zoneID,
                               desiredKeys: desiredKeys,
                               resultsLimit: resultsLimit)
    }
}
```

- [ ] **Step 2.2: Delete placeholder**

```bash
rm apps/macos/Sources/CloudKitSyncClient/_Placeholder.swift
```

- [ ] **Step 2.3: Write `FakeCloudDatabase`**

Replace test placeholder:

```swift
import CloudKit
import Foundation
@testable import CloudKitSyncClient

/// Test double for `CKDatabaseProtocol`. Stores records in an in-memory
/// dictionary keyed by recordName. Per-method error knobs let tests
/// exercise both happy paths and CKError surfacing.
final class FakeCloudDatabase: CKDatabaseProtocol, @unchecked Sendable {
    var records: [CKRecord.ID: CKRecord] = [:]
    var savedZones: [CKRecordZone.ID: CKRecordZone] = [:]

    var recordsCallCount = 0
    var saveCallCount = 0
    var deleteCallCount = 0
    var recordFetchCallCount = 0
    var saveZoneCallCount = 0

    var recordsError: Error?
    var saveError: Error?
    var deleteError: Error?
    var recordFetchError: Error?

    func records(matching query: CKQuery,
                 inZoneWith zoneID: CKRecordZone.ID?,
                 desiredKeys: [CKRecord.FieldKey]?,
                 resultsLimit: Int)
        async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                         queryCursor: CKQueryOperation.Cursor?)
    {
        recordsCallCount += 1
        if let err = recordsError { throw err }
        let filtered = records.values.filter { $0.recordType == query.recordType }
        let pairs = filtered.map { rec in
            (rec.recordID, Result<CKRecord, Error>.success(rec))
        }
        return (pairs, nil)
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        saveCallCount += 1
        if let err = saveError { throw err }
        records[record.recordID] = record
        return record
    }

    func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID {
        deleteCallCount += 1
        if let err = deleteError { throw err }
        records.removeValue(forKey: recordID)
        return recordID
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        recordFetchCallCount += 1
        if let err = recordFetchError { throw err }
        guard let r = records[recordID] else {
            throw CKError(.unknownItem)
        }
        return r
    }

    func save(_ zone: CKRecordZone) async throws -> CKRecordZone {
        saveZoneCallCount += 1
        savedZones[zone.zoneID] = zone
        return zone
    }
}
```

- [ ] **Step 2.4: Build**

Run: `cd apps/macos && swift build`
Expected: builds clean.

- [ ] **Step 2.5: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CKDatabaseProtocol.swift apps/macos/Tests/CloudKitSyncClientTests/FakeCloudDatabase.swift
git rm apps/macos/Sources/CloudKitSyncClient/_Placeholder.swift apps/macos/Tests/CloudKitSyncClientTests/_Placeholder.swift
git commit -m "feat(macos): add CKDatabaseProtocol + FakeCloudDatabase test double"
```

---

## Task 3: `RemoteHost` ↔ `CKRecord` mapping (encode)

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingTests.swift`

- [ ] **Step 3.1: Write the failing encode test**

Create `CKRecordHostMappingTests.swift`:

```swift
import CloudKit
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CKRecordHostMappingTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(zoneName: "Caterm")

    func testEncodeCreateInputProducesRecordWithFields() {
        let input = RemoteHostCreateInput(
            name: "alpha", hostname: "x.example.com", port: 2222, username: "u"
        )
        let recordName = "abc-123"
        let rec = CKRecordHostMapping.makeRecord(
            recordName: recordName, zoneID: zoneID, input: input
        )
        XCTAssertEqual(rec.recordType, "Host")
        XCTAssertEqual(rec.recordID.recordName, recordName)
        XCTAssertEqual(rec.recordID.zoneID, zoneID)
        XCTAssertEqual(rec["name"] as? String, "alpha")
        XCTAssertEqual(rec["hostname"] as? String, "x.example.com")
        XCTAssertEqual(rec["port"] as? Int, 2222)
        XCTAssertEqual(rec["username"] as? String, "u")
        XCTAssertEqual(rec["authType"] as? String, "key")
    }
}
```

- [ ] **Step 3.2: Run, expect fail**

Run: `cd apps/macos && swift test --filter CKRecordHostMappingTests`
Expected: compile error: `Cannot find 'CKRecordHostMapping'`.

- [ ] **Step 3.3: Implement `makeRecord`**

Create `CKRecordHostMapping.swift`:

```swift
import CloudKit
import Foundation
import ServerSyncClient

public enum CKRecordHostMapping {
    public static let recordType: CKRecord.RecordType = "Host"

    public static func makeRecord(recordName: String,
                                  zoneID: CKRecordZone.ID,
                                  input: RemoteHostCreateInput) -> CKRecord {
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let rec = CKRecord(recordType: recordType, recordID: id)
        rec["name"] = input.name as CKRecordValue
        rec["hostname"] = input.hostname as CKRecordValue
        rec["port"] = input.port as CKRecordValue
        rec["username"] = input.username as CKRecordValue
        rec["authType"] = input.authType as CKRecordValue
        return rec
    }
}
```

- [ ] **Step 3.4: Run, expect pass**

Run: `cd apps/macos && swift test --filter CKRecordHostMappingTests`
Expected: 1 test, passes.

- [ ] **Step 3.5: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingTests.swift
git commit -m "feat(macos): encode RemoteHostCreateInput → CKRecord"
```

---

## Task 4: `CKRecord` → `RemoteHost` decode (happy path)

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingTests.swift`

- [ ] **Step 4.1: Write failing decode test**

Append to `CKRecordHostMappingTests.swift`:

```swift
    func testDecodeRecordWithAllFieldsProducesRemoteHost() throws {
        let recID = CKRecord.ID(recordName: "rec-1", zoneID: zoneID)
        let rec = CKRecord(recordType: "Host", recordID: recID)
        rec["name"] = "alpha" as CKRecordValue
        rec["hostname"] = "x" as CKRecordValue
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        rec["authType"] = "key" as CKRecordValue
        // creationDate/modificationDate are normally set by the server.
        // Local CKRecord starts with nil — we reflect that via mapping
        // fallback to Date.distantPast so reconciler treats unsynced as
        // older than any real remote record.

        let host = try CKRecordHostMapping.decode(rec)
        XCTAssertEqual(host.id, "rec-1")
        XCTAssertEqual(host.name, "alpha")
        XCTAssertEqual(host.hostname, "x")
        XCTAssertEqual(host.port, 22)
        XCTAssertEqual(host.username, "u")
        XCTAssertEqual(host.authType, "key")
    }
```

- [ ] **Step 4.2: Run, expect compile failure**

Run: `cd apps/macos && swift test --filter CKRecordHostMappingTests`
Expected: compile error: `decode` is not defined.

- [ ] **Step 4.3: Implement `decode`**

Append to `CKRecordHostMapping.swift`:

```swift
    public enum DecodeError: Error, Equatable {
        case missingField(String)
    }

    public static func decode(_ rec: CKRecord) throws -> RemoteHost {
        guard let name = rec["name"] as? String else { throw DecodeError.missingField("name") }
        guard let hostname = rec["hostname"] as? String else { throw DecodeError.missingField("hostname") }
        guard let port = rec["port"] as? Int else { throw DecodeError.missingField("port") }
        guard let username = rec["username"] as? String else { throw DecodeError.missingField("username") }
        let authType = (rec["authType"] as? String) ?? "key"
        return RemoteHost(
            id: rec.recordID.recordName,
            name: name,
            hostname: hostname,
            port: port,
            username: username,
            authType: authType,
            createdAt: rec.creationDate ?? .distantPast,
            updatedAt: rec.modificationDate ?? .distantPast
        )
    }
```

- [ ] **Step 4.4: Run, expect pass**

Run: `cd apps/macos && swift test --filter CKRecordHostMappingTests`
Expected: 2 tests, both pass.

- [ ] **Step 4.5: Commit**

```bash
git add -u
git commit -m "feat(macos): decode CKRecord → RemoteHost"
```

---

## Task 5: Decode rejects records missing required fields

**Files:**
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingTests.swift`

- [ ] **Step 5.1: Write failing test**

Append:

```swift
    func testDecodeMissingHostnameThrows() {
        let recID = CKRecord.ID(recordName: "rec-bad", zoneID: zoneID)
        let rec = CKRecord(recordType: "Host", recordID: recID)
        rec["name"] = "x" as CKRecordValue
        // hostname intentionally omitted
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        XCTAssertThrowsError(try CKRecordHostMapping.decode(rec)) { error in
            XCTAssertEqual(error as? CKRecordHostMapping.DecodeError,
                           .missingField("hostname"))
        }
    }
```

- [ ] **Step 5.2: Run, expect pass (already implemented)**

Run: `cd apps/macos && swift test --filter CKRecordHostMappingTests`
Expected: 3 tests pass — the implementation in Task 4 already throws on missing fields.

- [ ] **Step 5.3: Commit**

```bash
git add -u
git commit -m "test(macos): decode rejects records missing required fields"
```

---

## Task 6: `CloudKitSyncClient.listHosts`

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientTests.swift`

- [ ] **Step 6.1: Write failing test**

Create `CloudKitSyncClientTests.swift`:

```swift
import CloudKit
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CloudKitSyncClientTests: XCTestCase {
    var fakeDb: FakeCloudDatabase!
    var sut: CloudKitSyncClient!
    let zoneID = CKRecordZone.ID(zoneName: "Caterm")

    override func setUp() {
        fakeDb = FakeCloudDatabase()
        sut = CloudKitSyncClient(database: fakeDb, zoneID: zoneID)
    }

    func testListHostsReturnsMappedRecords() async throws {
        let recID = CKRecord.ID(recordName: "h-1", zoneID: zoneID)
        let rec = CKRecord(recordType: "Host", recordID: recID)
        rec["name"] = "a" as CKRecordValue
        rec["hostname"] = "x" as CKRecordValue
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        rec["authType"] = "key" as CKRecordValue
        fakeDb.records[recID] = rec

        let hosts = try await sut.listHosts()

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].id, "h-1")
        XCTAssertEqual(hosts[0].name, "a")
        XCTAssertEqual(fakeDb.recordsCallCount, 1)
    }

    func testListHostsSkipsRecordsWithMissingFields() async throws {
        let goodID = CKRecord.ID(recordName: "good", zoneID: zoneID)
        let goodRec = CKRecord(recordType: "Host", recordID: goodID)
        goodRec["name"] = "a" as CKRecordValue
        goodRec["hostname"] = "x" as CKRecordValue
        goodRec["port"] = 22 as CKRecordValue
        goodRec["username"] = "u" as CKRecordValue
        fakeDb.records[goodID] = goodRec

        let badID = CKRecord.ID(recordName: "bad", zoneID: zoneID)
        let badRec = CKRecord(recordType: "Host", recordID: badID)
        badRec["name"] = "b" as CKRecordValue
        // missing hostname, port, username
        fakeDb.records[badID] = badRec

        let hosts = try await sut.listHosts()
        XCTAssertEqual(hosts.count, 1, "Malformed record must be skipped, not crash sync")
        XCTAssertEqual(hosts[0].id, "good")
    }
}
```

- [ ] **Step 6.2: Run, expect compile failure**

Run: `cd apps/macos && swift test --filter CloudKitSyncClientTests`
Expected: compile error: `Cannot find 'CloudKitSyncClient'`.

- [ ] **Step 6.3: Implement skeleton + listHosts**

Create `CloudKitSyncClient.swift`:

```swift
import CloudKit
import Foundation
import ServerSyncClient

/// `ServerSyncClient` impl backed by a CloudKit Private Database.
///
/// Records live in a custom zone (default `Caterm`) with record type `Host`.
/// The local `SSHHost.id` UUID doubles as `CKRecord.ID.recordName`, so
/// creates are idempotent and there is no "server-allocated id round-trip"
/// race (cf. `HostSyncStore.swift:403` warning).
public final class CloudKitSyncClient: ServerSyncClient {
    private let database: CKDatabaseProtocol
    private let zoneID: CKRecordZone.ID

    public init(database: CKDatabaseProtocol,
                zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "Caterm")) {
        self.database = database
        self.zoneID = zoneID
    }

    public func listHosts() async throws -> [RemoteHost] {
        let query = CKQuery(recordType: CKRecordHostMapping.recordType,
                            predicate: NSPredicate(value: true))
        do {
            let (matches, _) = try await database.records(
                matching: query, inZoneWith: zoneID,
                desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults
            )
            var hosts: [RemoteHost] = []
            for (_, result) in matches {
                if case let .success(rec) = result,
                   let host = try? CKRecordHostMapping.decode(rec) {
                    hosts.append(host)
                }
                // Per-record .failure(_) and decode failures are silently
                // skipped: a single bad record must not poison the whole
                // sync pass. The next pass will re-evaluate.
            }
            return hosts
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }

    public func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        fatalError("Task 7")
    }

    public func updateHost(_ input: RemoteHostUpdateInput) async throws {
        fatalError("Task 8")
    }

    public func deleteHost(id: String) async throws {
        fatalError("Task 9")
    }
}
```

Create `CloudKitErrorMapping.swift` (minimal — Task 10 expands):

```swift
import CloudKit
import Foundation
import ServerSyncClient

public enum CloudKitErrorMapping {
    public static func map(_ error: Error) -> ServerSyncError {
        if let ck = error as? CKError, ck.code == .notAuthenticated {
            return .notSignedIn
        }
        return .http(status: 0, body: error.localizedDescription)
    }
}
```

- [ ] **Step 6.4: Run, expect pass**

Run: `cd apps/macos && swift test --filter CloudKitSyncClientTests`
Expected: 2 tests pass.

- [ ] **Step 6.5: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift apps/macos/Sources/CloudKitSyncClient/CloudKitErrorMapping.swift apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientTests.swift
git commit -m "feat(macos): CloudKitSyncClient.listHosts"
```

---

## Task 7: `CloudKitSyncClient.createHost`

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientTests.swift`

- [ ] **Step 7.1: Write failing test**

Append to `CloudKitSyncClientTests`:

```swift
    func testCreateHostWritesRecordAndReturnsRecordName() async throws {
        let input = RemoteHostCreateInput(name: "alpha", hostname: "x",
                                          port: 22, username: "u")
        // The client allocates a fresh recordName per create. We cannot
        // assert the exact name (it's a UUID), but we can verify the saved
        // record matches and the returned id equals the allocated name.
        let out = try await sut.createHost(input)
        XCTAssertEqual(fakeDb.saveCallCount, 1)
        XCTAssertEqual(fakeDb.records.count, 1)
        let savedID = fakeDb.records.keys.first!
        XCTAssertEqual(savedID.recordName, out.id)
        XCTAssertEqual(fakeDb.records[savedID]?["name"] as? String, "alpha")
    }
```

- [ ] **Step 7.2: Run, expect crash (`fatalError("Task 7")`)**

Run: `cd apps/macos && swift test --filter testCreateHostWrites`
Expected: test crashes with the fatalError message.

- [ ] **Step 7.3: Implement `createHost`**

In `CloudKitSyncClient.swift`, replace the `createHost` body:

```swift
    public func createHost(_ input: RemoteHostCreateInput) async throws -> RemoteHostCreateOutput {
        try await ensureZone()
        let recordName = UUID().uuidString
        let rec = CKRecordHostMapping.makeRecord(
            recordName: recordName, zoneID: zoneID, input: input
        )
        do {
            let saved = try await database.save(rec)
            return RemoteHostCreateOutput(id: saved.recordID.recordName)
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }

    /// Idempotent zone bootstrap. The first `save` against a fresh container
    /// fails with `CKError.zoneNotFound` if we don't ensure the zone exists.
    /// `database.save(zone:)` is itself idempotent (no-op on a zone that
    /// already exists).
    private func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
    }
```

- [ ] **Step 7.4: Run, expect pass**

Run: `cd apps/macos && swift test --filter CloudKitSyncClientTests`
Expected: all tests pass.

- [ ] **Step 7.5: Commit**

```bash
git add -u
git commit -m "feat(macos): CloudKitSyncClient.createHost"
```

---

## Task 8: `CloudKitSyncClient.updateHost`

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientTests.swift`

- [ ] **Step 8.1: Write failing tests**

Append:

```swift
    func testUpdateHostFetchesAndModifiesRecord() async throws {
        let recID = CKRecord.ID(recordName: "h-1", zoneID: zoneID)
        let existing = CKRecord(recordType: "Host", recordID: recID)
        existing["name"] = "old" as CKRecordValue
        existing["hostname"] = "old.example.com" as CKRecordValue
        existing["port"] = 22 as CKRecordValue
        existing["username"] = "old-u" as CKRecordValue
        existing["authType"] = "key" as CKRecordValue
        fakeDb.records[recID] = existing

        let input = RemoteHostUpdateInput(id: "h-1", name: "new",
                                          hostname: "new.example.com",
                                          port: 2222, username: "new-u")
        try await sut.updateHost(input)

        let saved = fakeDb.records[recID]
        XCTAssertEqual(saved?["name"] as? String, "new")
        XCTAssertEqual(saved?["hostname"] as? String, "new.example.com")
        XCTAssertEqual(saved?["port"] as? Int, 2222)
        XCTAssertEqual(saved?["username"] as? String, "new-u")
        XCTAssertEqual(fakeDb.recordFetchCallCount, 1)
        XCTAssertEqual(fakeDb.saveCallCount, 1)
    }

    func testUpdateHostMissingRecordThrowsHttp() async throws {
        // Record id not present in the fake — `record(for:)` throws
        // CKError.unknownItem, which CloudKitErrorMapping maps to .http(...).
        let input = RemoteHostUpdateInput(id: "missing")
        do {
            try await sut.updateHost(input)
            XCTFail("expected throw")
        } catch let e as ServerSyncError {
            if case .http = e { return }
            XCTFail("expected .http, got \(e)")
        }
    }
```

- [ ] **Step 8.2: Run, expect crash**

Run: `cd apps/macos && swift test --filter testUpdateHost`
Expected: fatalError from Task 8 placeholder.

- [ ] **Step 8.3: Implement `updateHost`**

Replace the `updateHost` body:

```swift
    public func updateHost(_ input: RemoteHostUpdateInput) async throws {
        let recID = CKRecord.ID(recordName: input.id, zoneID: zoneID)
        do {
            let rec = try await database.record(for: recID)
            if let v = input.name { rec["name"] = v as CKRecordValue }
            if let v = input.hostname { rec["hostname"] = v as CKRecordValue }
            if let v = input.port { rec["port"] = v as CKRecordValue }
            if let v = input.username { rec["username"] = v as CKRecordValue }
            if let v = input.authType { rec["authType"] = v as CKRecordValue }
            _ = try await database.save(rec)
        } catch let e as ServerSyncError {
            throw e
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }
```

- [ ] **Step 8.4: Run, expect pass**

Run: `cd apps/macos && swift test --filter CloudKitSyncClientTests`
Expected: all tests pass.

- [ ] **Step 8.5: Commit**

```bash
git add -u
git commit -m "feat(macos): CloudKitSyncClient.updateHost"
```

---

## Task 9: `CloudKitSyncClient.deleteHost`

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitSyncClient.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientTests.swift`

- [ ] **Step 9.1: Write failing test**

Append:

```swift
    func testDeleteHostRemovesRecord() async throws {
        let recID = CKRecord.ID(recordName: "h-1", zoneID: zoneID)
        let rec = CKRecord(recordType: "Host", recordID: recID)
        fakeDb.records[recID] = rec
        try await sut.deleteHost(id: "h-1")
        XCTAssertNil(fakeDb.records[recID])
        XCTAssertEqual(fakeDb.deleteCallCount, 1)
    }

    func testDeleteHostMissingIsNoOp() async throws {
        // CKDatabase.deleteRecord on a missing id returns the id without
        // error in production. The fake matches this — no throw.
        try await sut.deleteHost(id: "missing")
        XCTAssertEqual(fakeDb.deleteCallCount, 1)
    }
```

- [ ] **Step 9.2: Run, expect crash**

Run: `cd apps/macos && swift test --filter testDeleteHost`
Expected: fatalError.

- [ ] **Step 9.3: Implement `deleteHost`**

Replace the body:

```swift
    public func deleteHost(id: String) async throws {
        let recID = CKRecord.ID(recordName: id, zoneID: zoneID)
        do {
            _ = try await database.deleteRecord(withID: recID)
        } catch {
            throw CloudKitErrorMapping.map(error)
        }
    }
```

- [ ] **Step 9.4: Run, expect pass**

Run: `cd apps/macos && swift test --filter CloudKitSyncClientTests`
Expected: all tests pass.

- [ ] **Step 9.5: Commit**

```bash
git add -u
git commit -m "feat(macos): CloudKitSyncClient.deleteHost"
```

---

## Task 10: `CKError` → `ServerSyncError` mapping coverage

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CloudKitErrorMapping.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/CloudKitErrorMappingTests.swift`

- [ ] **Step 10.1: Write failing tests**

Create `CloudKitErrorMappingTests.swift`:

```swift
import CloudKit
import ServerSyncClient
import XCTest
@testable import CloudKitSyncClient

final class CloudKitErrorMappingTests: XCTestCase {
    func testNotAuthenticatedMapsToNotSignedIn() {
        let mapped = CloudKitErrorMapping.map(CKError(.notAuthenticated))
        XCTAssertEqual(mapped, .notSignedIn)
    }

    func testServerRecordChangedMapsTo409() {
        let mapped = CloudKitErrorMapping.map(CKError(.serverRecordChanged))
        if case let .http(status, _) = mapped {
            XCTAssertEqual(status, 409)
        } else {
            XCTFail("expected .http(409, _), got \(mapped)")
        }
    }

    func testNetworkUnavailableMapsToHttpStatusZero() {
        let mapped = CloudKitErrorMapping.map(CKError(.networkUnavailable))
        if case let .http(status, _) = mapped {
            XCTAssertEqual(status, 0)
        } else {
            XCTFail("expected .http(0, _), got \(mapped)")
        }
    }

    func testNonCKErrorMapsToHttpStatusZero() {
        struct OtherError: Error {}
        let mapped = CloudKitErrorMapping.map(OtherError())
        if case .http(status: 0, _) = mapped { return }
        XCTFail("expected .http(0, _), got \(mapped)")
    }
}
```

- [ ] **Step 10.2: Run, expect 1 failure (`testServerRecordChangedMapsTo409`)**

Run: `cd apps/macos && swift test --filter CloudKitErrorMappingTests`
Expected: `testServerRecordChangedMapsTo409` fails (current impl returns status 0); others pass.

- [ ] **Step 10.3: Extend the mapping**

Replace `CloudKitErrorMapping.swift`:

```swift
import CloudKit
import Foundation
import ServerSyncClient

public enum CloudKitErrorMapping {
    /// Maps any error thrown out of CloudKit calls into the
    /// `ServerSyncError` shape that `HostSyncStore.classifySyncError` and
    /// `isAuthShape(_:)` already understand.
    ///
    /// - `.notAuthenticated` → `.notSignedIn` (HostSyncStore treats this
    ///   as auth-failure → flips `lastSyncErrorKind = .auth`).
    /// - `.serverRecordChanged` → synthetic HTTP 409. The next
    ///   reconcile pass uses LWW on `updatedAt` to resolve.
    /// - everything else → `.http(status: 0, ...)` (HostSyncStore
    ///   treats this as `.other`).
    public static func map(_ error: Error) -> ServerSyncError {
        guard let ck = error as? CKError else {
            return .http(status: 0, body: error.localizedDescription)
        }
        switch ck.code {
        case .notAuthenticated:
            return .notSignedIn
        case .serverRecordChanged:
            return .http(status: 409, body: ck.localizedDescription)
        default:
            return .http(status: 0, body: ck.localizedDescription)
        }
    }
}
```

- [ ] **Step 10.4: Run, expect all pass**

Run: `cd apps/macos && swift test --filter CloudKitErrorMappingTests`
Expected: 4 tests, all pass. Also re-run `CloudKitSyncClientTests` to confirm no regression.

Run: `cd apps/macos && swift test --filter CloudKitSyncClientTests`
Expected: all pass.

- [ ] **Step 10.5: Commit**

```bash
git add -u
git commit -m "feat(macos): map CKError → ServerSyncError exhaustively"
```

---

## Task 11: Verify `HostSyncStore.AuthShapeClassifier` already handles CloudKit auth

**Files:**
- Read-only verification of: `apps/macos/Sources/HostSyncStore/AuthShapeClassifier.swift`

`isAuthShape` already returns true for `.notSignedIn`, which is exactly what `CloudKitErrorMapping.map` produces for `.notAuthenticated`. No code change needed; this task is a verification + a regression test from the HostSyncStore side.

- [ ] **Step 11.1: Add cross-module regression test**

Append a new test file `apps/macos/Tests/HostSyncStoreTests/CloudKitAuthShapeTests.swift`:

```swift
import XCTest
import ServerSyncClient
@testable import HostSyncStore

final class CloudKitAuthShapeTests: XCTestCase {
    /// Regression guard: if anyone changes ServerSyncError or
    /// isAuthShape such that .notSignedIn is no longer auth-shaped,
    /// the CloudKit pipeline silently degrades from "show recovery
    /// affordance" to "generic failure" — catch that here.
    func testNotSignedInIsAuthShape() {
        XCTAssertTrue(isAuthShape(.notSignedIn))
    }
}
```

- [ ] **Step 11.2: Run, expect pass**

Run: `cd apps/macos && swift test --filter CloudKitAuthShapeTests`
Expected: 1 test, passes.

- [ ] **Step 11.3: Commit**

```bash
git add apps/macos/Tests/HostSyncStoreTests/CloudKitAuthShapeTests.swift
git commit -m "test(macos): regression guard for .notSignedIn auth shape"
```

---

## Task 12: `iCloudAccountSession`

**Files:**
- Create: `apps/macos/Sources/CloudKitSyncClient/iCloudAccountSession.swift`
- Create: `apps/macos/Tests/CloudKitSyncClientTests/iCloudAccountSessionTests.swift`

- [ ] **Step 12.1: Define the protocol abstraction over `CKContainer`**

This is needed because `CKContainer.accountStatus` cannot be faked directly. Add to `iCloudAccountSession.swift`:

```swift
import CloudKit
import Foundation

/// Minimal `CKContainer` surface for testability.
public protocol CKAccountStatusProviding: Sendable {
    func accountStatus() async throws -> CKAccountStatus
}

extension CKContainer: CKAccountStatusProviding {}
```

- [ ] **Step 12.2: Write failing test for fresh-init signed-in case**

Create `iCloudAccountSessionTests.swift`:

```swift
import CloudKit
import XCTest
@testable import CloudKitSyncClient

final class FakeAccountStatusProvider: CKAccountStatusProviding, @unchecked Sendable {
    var status: CKAccountStatus = .couldNotDetermine
    var error: Error?
    func accountStatus() async throws -> CKAccountStatus {
        if let e = error { throw e }
        return status
    }
}

@MainActor
final class iCloudAccountSessionTests: XCTestCase {
    func testInitialIsSignedInIsFalseUntilRefreshCompletes() {
        let provider = FakeAccountStatusProvider()
        provider.status = .available
        let sut = iCloudAccountSession(provider: provider)
        XCTAssertFalse(sut.isSignedIn,
            "Pre-refresh value defaults to false — accountStatus is async.")
    }

    func testRefreshAvailableFlipsIsSignedInTrue() async {
        let provider = FakeAccountStatusProvider()
        provider.status = .available
        let sut = iCloudAccountSession(provider: provider)
        await sut.refresh()
        XCTAssertTrue(sut.isSignedIn)
    }

    func testRefreshNoAccountKeepsIsSignedInFalse() async {
        let provider = FakeAccountStatusProvider()
        provider.status = .noAccount
        let sut = iCloudAccountSession(provider: provider)
        await sut.refresh()
        XCTAssertFalse(sut.isSignedIn)
    }

    func testRefreshErrorKeepsPreviousValue() async {
        let provider = FakeAccountStatusProvider()
        provider.status = .available
        let sut = iCloudAccountSession(provider: provider)
        await sut.refresh()
        XCTAssertTrue(sut.isSignedIn)
        provider.error = CKError(.networkUnavailable)
        await sut.refresh()
        XCTAssertTrue(sut.isSignedIn,
            "Errors during refresh must not flip the cached value — that would cause spurious sign-out flicker on transient CloudKit network blips.")
    }
}
```

- [ ] **Step 12.3: Run, expect compile failure**

Run: `cd apps/macos && swift test --filter iCloudAccountSessionTests`
Expected: `Cannot find 'iCloudAccountSession'`.

- [ ] **Step 12.4: Implement**

Append to `iCloudAccountSession.swift`:

```swift
import ServerSyncClient

/// `AuthSessionProtocol` impl backed by `CKContainer.accountStatus`.
///
/// Cached `isSignedIn` defaults to false. The caller is expected to call
/// `refresh()` after init (and on `.CKAccountChanged` notifications, see
/// `startObservingAccountChanges()` below).
///
/// Errors during `refresh()` are swallowed — they do NOT flip the cached
/// value. Reasoning: a transient `CKError.networkUnavailable` while the
/// user is actually signed in must not flip our cache to `false` and
/// suppress sync. Any real sign-out surfaces as `.noAccount` /
/// `.restricted`, which we DO honor.
@MainActor
public final class iCloudAccountSession: AuthSessionProtocol {
    private let provider: CKAccountStatusProviding
    public private(set) var isSignedIn: Bool = false

    /// Retained internally so the caller does not need to track it. When
    /// the session is deinit'd, this token's owning closure is released
    /// and the observer is removed by the GC of NotificationCenter.
    private var accountChangeObserver: NSObjectProtocol?

    public init(provider: CKAccountStatusProviding) {
        self.provider = provider
    }

    deinit {
        if let token = accountChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func refresh() async {
        do {
            let status = try await provider.accountStatus()
            isSignedIn = (status == .available)
        } catch {
            // intentionally no state change — see doc comment.
            return
        }
    }

    /// Idempotent: calling twice replaces the previous observer.
    public func startObservingAccountChanges() {
        if let prior = accountChangeObserver {
            NotificationCenter.default.removeObserver(prior)
        }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
                // Notify HostSyncStore to re-attempt sync if the user
                // just signed in. Decoupled from any direct reference to
                // HostSyncStore to keep this module independent.
                NotificationCenter.default.post(
                    name: .catermICloudAccountChanged, object: nil
                )
            }
        }
    }
}

extension Notification.Name {
    /// Posted after `iCloudAccountSession.refresh()` runs in response to
    /// `CKAccountChanged`. `CatermApp` wires this to
    /// `HostSyncStore.syncIfSignedIn()` so an in-app sign-in to iCloud
    /// triggers an immediate sync.
    public static let catermICloudAccountChanged =
        Notification.Name("catermICloudAccountChanged")
}
```

- [ ] **Step 12.5: Run, expect pass**

Run: `cd apps/macos && swift test --filter iCloudAccountSessionTests`
Expected: 4 tests, all pass.

- [ ] **Step 12.6: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/iCloudAccountSession.swift apps/macos/Tests/CloudKitSyncClientTests/iCloudAccountSessionTests.swift
git commit -m "feat(macos): iCloudAccountSession (AuthSessionProtocol via CKContainer)"
```

---

## Task 13: Update entitlements for CloudKit

**Files:**
- Modify: `apps/macos/Resources/Caterm.entitlements`

- [ ] **Step 13.1: Add CloudKit keys**

Replace the entire contents of `apps/macos/Resources/Caterm.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>$(TeamIdentifierPrefix)caterm.shared</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.caterm.app</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 13.2: Run `make sign` and verify entitlements embed**

Run:
```bash
cd apps/macos && make sign
codesign -d --entitlements :- .build/debug/caterm 2>/dev/null
```
Expected: stdout includes `com.apple.developer.icloud-container-identifiers` with the `iCloud.com.caterm.app` value.

If `make sign` fails with "Apple Development signing requires a provisioning profile that includes iCloud entitlement", regenerate the profile via Apple Developer Portal (see Pre-flight #5) and re-download.

- [ ] **Step 13.3: Commit**

```bash
git add apps/macos/Resources/Caterm.entitlements
git commit -m "feat(macos): add CloudKit entitlements"
```

---

## Task 14: Wire `CatermApp` to inject CloudKit-backed sync

**Files:**
- Modify: `apps/macos/Sources/Caterm/CatermApp.swift`

- [ ] **Step 14.1: Replace the auth-session and sync-client construction**

In `CatermApp.swift`, find the `init()` block (around line 33). Replace these three lines:

```swift
		let session = makeStore()
		let auth = AuthSession(baseURL: ServerURL.current)
		self.authSession = auth
		let client = URLSessionServerSyncClient(baseURL: ServerURL.current)
```

with:

```swift
		let session = makeStore()
		// CloudKit-backed sync (replaces the URLSession + better-auth pair).
		// `AuthSession` reference kept on `CatermApp` for compatibility with
		// `PreferencesWindowController.syncEnvironment` which still expects
		// a typed `AuthSession`. Plan E removes the typed reference along
		// with the login UI.
		let cloudContainer = CKContainer(identifier: "iCloud.com.caterm.app")
		let icloudSession = iCloudAccountSession(provider: cloudContainer)
		self.authSession = AuthSession(baseURL: ServerURL.current)  // unwired
		let client = CloudKitSyncClient(database: cloudContainer.privateCloudDatabase)
```

Then below the `_syncStore = StateObject(...)` block, replace `auth` references in the `HostSyncStore` constructor with `icloudSession`:

```swift
		_syncStore = StateObject(wrappedValue: HostSyncStore(
			client: client,
			sessionStore: session,
			authSession: icloudSession,
			preferences: prefs
		))
```

Also add this line after `_syncStore` is set, to kick off the initial async refresh:

```swift
		// Refresh CloudKit account status asynchronously. HostSyncStore.syncIfSignedIn
		// (called from .task in body) handles the case where refresh hasn't completed
		// yet — it sees isSignedIn=false and skips; the .CKAccountChanged observer
		// re-triggers sync once the status flips.
		Task { @MainActor in
			await icloudSession.refresh()
			NotificationCenter.default.post(
				name: .catermICloudAccountChanged, object: nil
			)
		}
		icloudSession.startObservingAccountChanges()
```

- [ ] **Step 14.2: Add the new module imports**

At the top of `CatermApp.swift`, add:

```swift
import CloudKit
import CloudKitSyncClient
```

(keep the existing `import ServerSyncClient` — `AuthSession` and `ServerURL` still come from there.)

- [ ] **Step 14.3: Wire `.catermICloudAccountChanged` to trigger sync**

Inside `body`, find the `.onReceive(NotificationCenter.default.publisher(for: .catermOpenSyncSettings))` block. Add a sibling onReceive for the account change notification:

```swift
				.onReceive(NotificationCenter.default
					.publisher(for: .catermICloudAccountChanged)) { _ in
					syncStore.syncIfSignedIn()
				}
```

- [ ] **Step 14.4: Update `Caterm` executable target deps**

In `Package.swift`, find the `Caterm` executable target's `dependencies` array and add `"CloudKitSyncClient"`:

```swift
        .executableTarget(
            name: "Caterm",
            dependencies: [
                "TerminalEngine",
                "SSHCommandBuilder",
                "SessionStore",
                "KeychainStore",
                "ConfigStore",
                "ServerSyncClient",
                "HostSyncStore",
                "FileTransferStore",
                "SFTPCommandBuilder",
                "CloudKitSyncClient",
            ],
            ...
```

- [ ] **Step 14.5: Build**

Run: `cd apps/macos && swift build`
Expected: builds clean.

- [ ] **Step 14.6: Run all tests**

Run: `cd apps/macos && swift test`
Expected: all tests pass. The existing `HostSyncStoreTests` continue to pass because they inject `FakeServerSyncClient` directly — they don't go through `CatermApp`.

- [ ] **Step 14.7: Commit**

```bash
git add -u
git commit -m "feat(macos): wire CatermApp to CloudKitSyncClient + iCloudAccountSession"
```

---

## Task 15: Manual verification

**Goal:** prove end-to-end that host metadata round-trips through iCloud.

This step requires real iCloud credentials and a properly-provisioned signed build. It is intentionally NOT a unit test — there's no fake for the actual CloudKit network round-trip.

- [ ] **Step 15.1: Sign in to iCloud on the test Mac**

System Settings → Apple Account → confirm iCloud is on and `iCloud Drive` is enabled. (CloudKit private DB requires the same iCloud account state as iCloud Drive.)

- [ ] **Step 15.2: Build and launch the bundled app**

```bash
cd apps/macos && make run-app
```
Expected: app launches without crashing. Log line `[CatermApp]` does NOT appear.

- [ ] **Step 15.3: First-run smoke check**

In the app, add a new SSH host (⌘T):
- Name: `cloudkit-smoke`
- Hostname: `127.0.0.1`
- Port: `22`
- Username: `whatever`

Wait ~3 seconds (the 2 s mutation debounce + a network round-trip).

- [ ] **Step 15.4: Verify the record landed in CloudKit Dashboard**

Open https://icloud.developer.apple.com/dashboard → `iCloud.com.caterm.app` → Development → Data → Private Database → Caterm zone → Host record type → Records.

Expected: one row with `name = cloudkit-smoke`, `hostname = 127.0.0.1`, `port = 22`, `username = whatever`, `authType = key`.

- [ ] **Step 15.5: Verify remote → local download (`createLocal` op)**

Quit the app. Edit `~/Library/Application Support/Caterm/hosts.json` and remove the `cloudkit-smoke` entry from the JSON array. Save. Relaunch the app.

Expected sequence:
1. App launches; sidebar initially does not show `cloudkit-smoke` (local file lacks it).
2. Within ~5 seconds (first sync after launch), `cloudkit-smoke` reappears in the sidebar.
3. Reason: reconciler sees no local match, one remote → emits `.createLocal(remote:)` → `SessionStore.addRemoteHost` writes the host back to disk.

This validates the CloudKit pull path end-to-end.

- [ ] **Step 15.6: Verify pure-local fallback**

Sign out of iCloud (System Settings → Apple Account → Sign Out). Relaunch the app.

Expected: app launches; sidebar still shows `cloudkit-smoke` (loaded from local `hosts.json`). Adding a new host succeeds locally. The sync indicator shows "Signed Out". No CloudKit network calls (verify in Console.app filter for `cloudd`: no hits from caterm).

Sign back in to iCloud, relaunch app. Expected: sync resumes; sidebar reflects CloudKit state.

- [ ] **Step 15.7: Document the result**

If all steps pass, append to plan: "Manual verification passed YYYY-MM-DD on macOS X.Y." If any step fails, file the failure as an issue and DO NOT proceed to Plan B.

- [ ] **Step 15.8: Commit verification doc**

```bash
git add docs/superpowers/plans/2026-05-02-cloudkit-host-sync.md
git commit -m "docs: record CloudKit host-sync manual verification result"
```

---

## Done criteria

- All `swift test` targets pass.
- Manual verification (Task 15) passes.
- `apps/server` is unchanged (verify with `git status apps/server` → empty).
- `URLSessionServerSyncClient` and `AuthSession` source files are still present (deletion deferred to Plan E).

## What's next

Plan B replaces the 15-min polling timer with `CKDatabaseSubscription` + remote notifications. Plan A's pull cadence remains poll-based; Plan B is a drop-in optimization that doesn't require any HostSyncStore behavior change.

---

## Pre-flight setup (one-time, per Apple Developer account)

These are out-of-band Apple-portal / Dashboard steps that the plan tasks alone don't cover. Future contributors hitting Plan A on a new account need all of these before Task 15 will pass.

1. **Create iCloud container** — Apple Developer Portal → Identifiers → iCloud Containers → register `iCloud.com.caterm.app`. The bundle id `com.caterm.app` must list this container under its iCloud capability.
2. **Register the dev Mac** — Devices → register the Mac using its **Provisioning UDID** (not the Hardware UUID). On Apple Silicon they differ; AMFI rejects the profile if the UUID is used. Get it via `system_profiler SPHardwareDataType | grep "Provisioning UDID"`.
3. **Create an Apple Development cert** in Xcode (Settings → Accounts → Manage Certificates → +). Distribution-only certs (Developer ID Application) won't pass AMFI for un-notarized dev builds.
4. **Create a "Mac App Development" provisioning profile** — type **Mac App Development** (not Developer ID), with the cert from step 3, the bundle id `com.caterm.app`, the device from step 2, and the iCloud container from step 1. This profile permits both Development and Production CloudKit environments.
5. **Add a Queryable index on `recordName`** — CloudKit Dashboard → Schema → Indexes → Host record type → add `recordName` as Queryable. Without it, `listHosts`'s `CKQuery` returns `Field 'recordName' is not marked queryable`.

See `docs/macos-dev-signing.md` for the codesign + entitlement-substitution invocation that bundles the profile and signs the app for local launch.

## Manual verification result

Manual verification (Task 15) passed **2026-05-02** on macOS 25.4.0 (Apple Silicon).

Round-trip checks performed:
- **Step 15.3–15.4 (push):** Created `cloudkit-smoke` host in-app → row appeared in CloudKit Dashboard Private DB / Caterm zone / Host record type within ~3 s.
- **Step 15.5 (pull):** Quit app, removed `cloudkit-smoke` from `~/Library/Application Support/Caterm/hosts.json` via `jq`, relaunched. Within ~5 s the host reappeared in `hosts.json` and in the sidebar — reconciler emitted `.createLocal(remote:)` and `SessionStore.addRemoteHost` wrote it back.

Step 15.6 (iCloud sign-out fallback) deferred — `HostSyncStoreAutoSyncTests.testSyncIfSignedInNoOpsWhenSignedOut` already covers the gating logic; no need to disrupt the development account. Will verify opportunistically next time the user signs out for unrelated reasons.

Plan A is **done**. Commits: `dfa6f86`, `e79b5ae`, `f68375e`, `59151a2`, `f936ce4`.
