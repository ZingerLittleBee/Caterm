# Host Chaining (ProxyJump) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users connect to a saved SSH host through one or more saved bastion hosts, mirroring Termius's "Connect via" — fully synced across devices, with chain-aware credential routing for password / key+passphrase / agent on every hop.

**Architecture:** `SSHHost` gains a CloudKit-stable `jumpHostServerId: String?`. `SSHCommandBuilder` emits a per-session `ssh_config` snippet (one `Host` block per chain hop, target's block has `ProxyJump`) and runs `ssh -F <config> caterm-h-<target-uuid>`. A new `SSHConfigQuote` helper rejects `\n`/`\r`/NUL and double-quotes special characters to prevent ssh_config directive injection. `caterm-askpass` becomes chain-aware via a new `CATERM_CHAIN` JSON env var; the resolver matches prompts against both alias and hostname, fails-closed on ambiguity. `SessionStore.openTab` resolves the chain and runs a credential precheck for every hop before launching ssh. `HostFormView` adds a "Via host" picker; overlays show a chain caption.

**Tech Stack:** Swift 5+, SwiftUI (macOS 14+), OpenSSH `ssh` subprocess via libghostty, NWConnection (existing TCP preflight), XCTest, Drizzle ORM (server-side prereq), oRPC (server-side prereq).

**Spec:** `docs/superpowers/specs/2026-05-07-host-chaining-design.md`

---

## Prerequisites (out of macOS scope, must land first)

**Server-side schema migration** must be committed before Task 3 (the wire-model commit) goes live, otherwise client pushes of `jumpHostServerId` will be silently dropped:

- `packages/db/<schema>` — add a nullable `jumpHostServerId` `text` column on the `sshHost` table; generate a Drizzle migration via `bun run db:generate`; apply with `bun run db:push`.
- `packages/api/src/routers/ssh-host.ts` — add `jumpHostServerId: z.string().nullable().optional()` to:
  - the `list` output schema (read path)
  - the `create` input schema (push path)
  - the `update` input schema (push path)
  Persist the column on create/update; project it on list.

The macOS Swift unit tests run with mocked `ServerSyncClient` and don't require the server to be live, so the macOS implementation may proceed once the server PR is merged. The `EndToEndSSHTests` integration cases (Task 18) DO need a live server reachable from CI.

---

## File Structure

```
NEW (apps/macos):
apps/macos/Sources/SSHCommandBuilder/Chain.swift                 // resolvedChain, firstHopAddress, ChainResolutionError
apps/macos/Sources/SSHCommandBuilder/HostFormCycleFilter.swift   // eligibleJumpHosts pure helper
apps/macos/Sources/SSHCommandBuilder/SSHConfigQuote.swift        // ssh_config-safe encoder
apps/macos/Sources/SSHCommandBuilder/SSHConfigSink.swift         // protocol + InMemorySSHConfigSink fake
apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift        // real impl
apps/macos/Sources/CatermAskpassCore/ChainResolver.swift         // resolveAskpassPrompt + AskpassChainEntry + AskpassResolution
apps/macos/Tests/SSHCommandBuilderTests/ChainTests.swift
apps/macos/Tests/SSHCommandBuilderTests/HostFormCycleFilterTests.swift
apps/macos/Tests/SSHCommandBuilderTests/SSHConfigQuoteTests.swift
apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderChainTests.swift
apps/macos/Tests/CatermAskpassCoreTests/ChainResolverTests.swift
apps/macos/Tests/SessionStoreTests/SessionStoreChainTests.swift
apps/macos/Manual/host-chaining-checklist.md

MODIFY (apps/macos):
apps/macos/Package.swift                                         // + CatermAskpassCore library + test target
apps/macos/Sources/SSHCommandBuilder/Host.swift                  // + jumpHostServerId
apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift     // CATERM_ASKPASS_KIND=keyPassphrase; perHostOptions; chain config emission
apps/macos/Sources/CatermAskpass/main.swift                      // depend on CatermAskpassCore; CATERM_CHAIN; accept kind=keyPassphrase
apps/macos/Sources/ServerSyncClient/RemoteHost.swift             // + jumpHostServerId on RemoteHost / RemoteHostCreateInput / RemoteHostUpdateInput
apps/macos/Sources/HostSyncStore/HostSyncStore.swift             // thread jumpHostServerId in createRemote / updateRemote
apps/macos/Sources/SessionStore/SessionStore.swift               // addRemoteHost / applyRemoteMetadata propagate; Tab.resolvedChain + Tab.sshConfigURL; openTab precheck; runConnection firstHop preflight; closeTab cleanup
apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift  // + jumpHostServerId field
apps/macos/Sources/Caterm/Views/HostFormView.swift               // Via picker + cycle filter + chain preview + isValid
apps/macos/Sources/Caterm/Views/HostListSidebar.swift            // chain icon + fan-out delete alert
apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift          // chain caption
apps/macos/Sources/Caterm/Views/FailureOverlay.swift             // chain caption
apps/macos/Sources/Caterm/Views/ReconnectOverlay.swift           // chain caption
apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift        // chain integration cases
```

The current Swift test baseline is 688 / 12 skipped / 0 failures (per the prior credential-prompt feature). Each task below preserves this and adds its own new tests, ending at a higher count.

---

## Task 1: Fix `keyPassphrase` env value (prerequisite)

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift:100`
- Modify: `apps/macos/Sources/CatermAskpass/main.swift:82-87`
- Test: `apps/macos/Tests/SSHCommandBuilderTests/<existing builder test file>` (one new assertion)

**Why this is here:** `SessionStore.setHostCredentialMaterial` writes the passphrase under Keychain account `<host-id>.keyPassphrase` (`SessionStore.swift:454`), but `SSHCommandBuilder` sets `CATERM_ASKPASS_KIND=passphrase` and `caterm-askpass` then looks up `<host-id>.passphrase` — which doesn't exist. Key+passphrase auth is broken in production today. The chain-aware askpass design depends on a unified suffix; we fix the bug here so the chain feature inherits correct behavior.

- [ ] **Step 1: Find an existing builder test that exercises the keyFile-with-passphrase path**

```
cd apps/macos && grep -rn "hasPassphrase: true\|keyFile.*hasPassphrase" Tests/SSHCommandBuilderTests/ --include="*.swift"
```

Pick the test (or write one in `SSHCommandBuilderTests.swift` if none exists) that asserts the env vars produced when `host.credential == .keyFile(keyPath: ..., hasPassphrase: true)`.

- [ ] **Step 2: Update the failing test**

In the chosen test, change the expected value of `CATERM_ASKPASS_KIND` from `"passphrase"` to `"keyPassphrase"`. If no existing test asserts on this env, add a new test at the end of `SSHCommandBuilderTests.swift` (use TAB indentation):

```swift
	func testKeyFileWithPassphraseEmitsKeyPassphraseKind() {
		let host = SSHHost(
			name: "h", hostname: "example.com", port: 22,
			username: "u",
			credential: .keyFile(keyPath: "/k", hasPassphrase: true)
		)
		let out = SSHCommandBuilder.build(
			host: host,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		let kind = out.env.first { $0.0 == "CATERM_ASKPASS_KIND" }?.1
		XCTAssertEqual(kind, "keyPassphrase")
	}
```

- [ ] **Step 3: Run the test to verify it fails today**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.testKeyFileWithPassphraseEmitsKeyPassphraseKind 2>&1 | tail -10
```

Expected: FAIL — current code emits `"passphrase"`, test expects `"keyPassphrase"`.

- [ ] **Step 4: Fix `SSHCommandBuilder.swift:100`**

Open `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`. Find:

```swift
				if hasPassphrase {
					env = [
						("SSH_ASKPASS", askpassPath),
						("SSH_ASKPASS_REQUIRE", "force"),
						("CATERM_HOST_ID", host.id.uuidString),
						("CATERM_ASKPASS_KIND", "passphrase"),
					]
				}
```

Change `"passphrase"` to `"keyPassphrase"`:

```swift
				if hasPassphrase {
					env = [
						("SSH_ASKPASS", askpassPath),
						("SSH_ASKPASS_REQUIRE", "force"),
						("CATERM_HOST_ID", host.id.uuidString),
						("CATERM_ASKPASS_KIND", "keyPassphrase"),
					]
				}
```

- [ ] **Step 5: Update `caterm-askpass` to accept the renamed kind**

Open `apps/macos/Sources/CatermAskpass/main.swift`. Find:

```swift
guard let kind = env["CATERM_ASKPASS_KIND"],
      kind == "password" || kind == "passphrase" else {
    FileHandle.standardError.write(Data("CATERM_ASKPASS_KIND invalid\n".utf8))
    logLine("FAIL exit=1 reason=CATERM_ASKPASS_KIND-invalid host=\(hostId)")
    exit(1)
}
```

Change `"passphrase"` to `"keyPassphrase"`:

```swift
guard let kind = env["CATERM_ASKPASS_KIND"],
      kind == "password" || kind == "keyPassphrase" else {
    FileHandle.standardError.write(Data("CATERM_ASKPASS_KIND invalid\n".utf8))
    logLine("FAIL exit=1 reason=CATERM_ASKPASS_KIND-invalid host=\(hostId)")
    exit(1)
}
```

Also update the dev-only stuff-mode validation a few lines above; find:

```swift
          let kind = env["CATERM_ASKPASS_KIND"],
          kind == "password" || kind == "passphrase",
```

Change to:

```swift
          let kind = env["CATERM_ASKPASS_KIND"],
          kind == "password" || kind == "keyPassphrase",
```

- [ ] **Step 6: Run the test to verify it passes**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.testKeyFileWithPassphraseEmitsKeyPassphraseKind 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 7: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 689 / 12 / 0 (688 baseline + 1 new).

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift \
        apps/macos/Sources/CatermAskpass/main.swift \
        apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderTests.swift
git commit -m "fix(macos): unify CATERM_ASKPASS_KIND on keyPassphrase to match keychain account"
```

---

## Task 2: Add `SSHHost.jumpHostServerId`

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/Host.swift`
- Test: `apps/macos/Tests/SSHCommandBuilderTests/<existing host test or new HostJumpHostServerIdTests.swift>`

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/Tests/SSHCommandBuilderTests/HostJumpHostServerIdTests.swift` with TAB indentation:

```swift
import XCTest
@testable import SSHCommandBuilder

final class HostJumpHostServerIdTests: XCTestCase {
	func testDefaultInitHasNilJumpHostServerId() {
		let h = SSHHost(name: "n", hostname: "h", port: 22,
		                username: "u", credential: .password)
		XCTAssertNil(h.jumpHostServerId)
	}

	func testCodableRoundTripWithNonNilJumpHostServerId() throws {
		var h = SSHHost(name: "n", hostname: "h", port: 22,
		                username: "u", credential: .password)
		h.jumpHostServerId = "server-abc-123"
		let data = try JSONEncoder().encode(h)
		let decoded = try JSONDecoder().decode(SSHHost.self, from: data)
		XCTAssertEqual(decoded.jumpHostServerId, "server-abc-123")
	}

	func testCodableDecodesLegacyPayloadWithoutJumpHostServerIdAsNil() throws {
		// A payload written by the previous version of the app — no
		// jumpHostServerId key at all. Decoding must succeed and yield nil.
		let legacy = #"""
		{
		  "id": "11111111-2222-3333-4444-555555555555",
		  "name": "n",
		  "hostname": "h",
		  "port": 22,
		  "username": "u",
		  "credential": { "kind": "password" },
		  "createdAt": 0,
		  "updatedAt": 0
		}
		"""#
		// Tolerant decoder: real SSHHost decoder may differ; if this format
		// doesn't match, copy a real legacy payload from a hosts.json file
		// in the test fixtures and use that instead.
		let decoded = try? JSONDecoder().decode(SSHHost.self,
		                                       from: Data(legacy.utf8))
		XCTAssertNotNil(decoded, "Legacy payload must still decode")
		XCTAssertNil(decoded?.jumpHostServerId)
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.HostJumpHostServerIdTests 2>&1 | tail -10
```

Expected: build error — `jumpHostServerId` is not a member of `SSHHost`.

- [ ] **Step 3: Add the field to `SSHHost`**

Open `apps/macos/Sources/SSHCommandBuilder/Host.swift`. Find the `SSHHost` (or `Host` typealias source) struct. Add the new field at the end of the stored properties (preserve TAB indentation):

```swift
	/// CloudKit-stable reference to another saved host that should be used
	/// as the jump host. Stored as `serverId` (not the local `id`) because
	/// local UUIDs are regenerated on each device's pull. Nil = no chain.
	public var jumpHostServerId: String?
```

Update the public initializer to accept it as a trailing optional parameter with a `nil` default so existing call sites compile unchanged:

```swift
	public init(
		// ... existing parameters ...
		jumpHostServerId: String? = nil
	) {
		// ... existing assignments ...
		self.jumpHostServerId = jumpHostServerId
	}
```

If `SSHHost` has a custom `init(from decoder:)` (it does — explicit decoder for back-compat per the explorer's report), add a tolerant decode:

```swift
		self.jumpHostServerId = try container.decodeIfPresent(String.self,
		                                                     forKey: .jumpHostServerId)
```

Add `case jumpHostServerId` to the `CodingKeys` enum.

If `SSHHost` has a custom `encode(to:)`, add the symmetric encode (using `encodeIfPresent` so legacy nil values don't bloat the JSON):

```swift
		try container.encodeIfPresent(jumpHostServerId, forKey: .jumpHostServerId)
```

- [ ] **Step 4: Run the tests**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.HostJumpHostServerIdTests 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 5: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 692 / 12 / 0 (689 + 3 new). No regression — the field defaults to nil so all existing code paths see the same SSHHost shape.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/Host.swift \
        apps/macos/Tests/SSHCommandBuilderTests/HostJumpHostServerIdTests.swift
git commit -m "feat(macos): add SSHHost.jumpHostServerId field for chain references"
```

---

## Task 3: Wire model — `RemoteHost`, `RemoteHostCreateInput`, `RemoteHostUpdateInput`

**Files:**
- Modify: `apps/macos/Sources/ServerSyncClient/RemoteHost.swift`
- Modify: `apps/macos/Sources/HostSyncStore/HostSyncStore.swift:624, 646`
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift` (`addRemoteHost`, `applyRemoteMetadata`)
- Test: `apps/macos/Tests/ServerSyncClientTests/RemoteHostJumpHostServerIdTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/Tests/ServerSyncClientTests/RemoteHostJumpHostServerIdTests.swift`:

```swift
import XCTest
@testable import ServerSyncClient

final class RemoteHostJumpHostServerIdTests: XCTestCase {
	func testRemoteHostCodableRoundTripWithNonNilField() throws {
		let r = RemoteHost(
			id: "rh-1", name: "n", hostname: "h", port: 22,
			username: "u", authType: "key",
			createdAt: Date(timeIntervalSince1970: 0),
			updatedAt: Date(timeIntervalSince1970: 0),
			jumpHostServerId: "rh-bastion"
		)
		let data = try JSONEncoder().encode(r)
		let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)
		XCTAssertEqual(decoded.jumpHostServerId, "rh-bastion")
	}

	func testRemoteHostDecodesLegacyPayloadWithoutFieldAsNil() throws {
		let legacy = #"""
		{
		  "id": "rh-1", "name": "n", "hostname": "h", "port": 22,
		  "username": "u", "authType": "key",
		  "createdAt": "1970-01-01T00:00:00Z",
		  "updatedAt": "1970-01-01T00:00:00Z"
		}
		"""#
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let r = try decoder.decode(RemoteHost.self, from: Data(legacy.utf8))
		XCTAssertNil(r.jumpHostServerId)
	}

	func testCreateInputEncodesJumpHostServerId() throws {
		let input = RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u",
			jumpHostServerId: "rh-bastion"
		)
		let data = try JSONEncoder().encode(input)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(json?["jumpHostServerId"] as? String, "rh-bastion")
	}

	func testUpdateInputEncodesJumpHostServerId() throws {
		let input = RemoteHostUpdateInput(
			id: "rh-1", name: "n", hostname: "h", port: 22, username: "u",
			jumpHostServerId: "rh-bastion"
		)
		let data = try JSONEncoder().encode(input)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
		XCTAssertEqual(json?["jumpHostServerId"] as? String, "rh-bastion")
	}

	func testCreateInputOmitsFieldWhenNil() throws {
		let input = RemoteHostCreateInput(
			name: "n", hostname: "h", port: 22, username: "u"
		)
		let data = try JSONEncoder().encode(input)
		let str = String(data: data, encoding: .utf8) ?? ""
		// Either absent or explicit null; both are acceptable on the wire.
		// We want absent so server-side schemas without the column still parse.
		XCTAssertFalse(str.contains("\"jumpHostServerId\":\"") ,
		               "non-null jumpHostServerId leaked: \(str)")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

```
cd apps/macos && swift test --filter ServerSyncClientTests.RemoteHostJumpHostServerIdTests 2>&1 | tail -15
```

Expected: build error — `jumpHostServerId` not in `RemoteHost`/`RemoteHostCreateInput`/`RemoteHostUpdateInput`.

- [ ] **Step 3: Add the field to all three types**

Open `apps/macos/Sources/ServerSyncClient/RemoteHost.swift`. Update each struct (TAB indentation):

```swift
public struct RemoteHost: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authType: String
    public let createdAt: Date
    public let updatedAt: Date
    public let jumpHostServerId: String?

    public init(id: String, name: String, hostname: String, port: Int,
                username: String, authType: String, createdAt: Date, updatedAt: Date,
                jumpHostServerId: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = authType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.jumpHostServerId = jumpHostServerId
    }
}

public struct RemoteHostCreateInput: Codable {
    public let name: String
    public let hostname: String
    public let port: Int
    public let username: String
    public let authType: String
    public let jumpHostServerId: String?

    public init(name: String, hostname: String, port: Int, username: String,
                jumpHostServerId: String? = nil) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = "key"
        self.jumpHostServerId = jumpHostServerId
    }
}

public struct RemoteHostUpdateInput: Codable {
    public let id: String
    public let name: String?
    public let hostname: String?
    public let port: Int?
    public let username: String?
    public let authType: String?
    public let jumpHostServerId: String?

    public init(id: String, name: String? = nil, hostname: String? = nil,
                port: Int? = nil, username: String? = nil,
                jumpHostServerId: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authType = "key"
        self.jumpHostServerId = jumpHostServerId
    }
}
```

- [ ] **Step 4: Thread through `HostSyncStore`**

Open `apps/macos/Sources/HostSyncStore/HostSyncStore.swift`. Find the `.createRemote` and `.updateRemote` cases (around line 624 and 646). Update both calls to pass `host.jumpHostServerId`:

```swift
        case let .createRemote(localHostId):
            guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
            let input = RemoteHostCreateInput(
                name: host.name, hostname: host.hostname,
                port: host.port, username: host.username,
                jumpHostServerId: host.jumpHostServerId
            )
            let out = try await client.createHost(input)
            try sessionStore.setServerId(out.id, for: localHostId)
```

```swift
        case let .updateRemote(localHostId, serverId):
            guard let host = sessionStore.hosts.first(where: { $0.id == localHostId }) else { return }
            let input = RemoteHostUpdateInput(
                id: serverId, name: host.name, hostname: host.hostname,
                port: host.port, username: host.username,
                jumpHostServerId: host.jumpHostServerId
            )
            try await client.updateHost(input)
```

- [ ] **Step 5: Propagate through `SessionStore.addRemoteHost` and `applyRemoteMetadata`**

Open `apps/macos/Sources/SessionStore/SessionStore.swift`. Locate `addRemoteHost(_:)` (around line 400+ per the explorer). The current body materializes a fresh `SSHHost` from `RemoteHost` fields and defaults credential to `.password`. Add a copy of the new field at the construction site:

```swift
		let new = SSHHost(
			// ... existing field copies ...
			credential: .password,
			// (existing serverId, createdAt, updatedAt, etc.)
			jumpHostServerId: remote.jumpHostServerId
		)
```

(If the local SSHHost is constructed via `var h = SSHHost(...); h.serverId = remote.id; ...` style, append `h.jumpHostServerId = remote.jumpHostServerId` instead.)

For `applyRemoteMetadata(localHostId:remote:)`: this method updates an existing local host's metadata from a remote payload. Add the field copy alongside the existing name/hostname/port/username updates:

```swift
		updated[idx].jumpHostServerId = remote.jumpHostServerId
```

- [ ] **Step 6: Run the new tests**

```
cd apps/macos && swift test --filter ServerSyncClientTests.RemoteHostJumpHostServerIdTests 2>&1 | tail -10
```

Expected: 5 tests pass.

- [ ] **Step 7: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 697 / 12 / 0 (692 + 5 new). Existing `HostSyncStore`/`SessionStore` tests must continue passing — the field defaults to nil so old tests see the same shape.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/ServerSyncClient/RemoteHost.swift \
        apps/macos/Sources/HostSyncStore/HostSyncStore.swift \
        apps/macos/Sources/SessionStore/SessionStore.swift \
        apps/macos/Tests/ServerSyncClientTests/RemoteHostJumpHostServerIdTests.swift
git commit -m "feat(macos): thread jumpHostServerId through server sync wire model"
```

---

## Task 4: CloudKit `CKRecordHostMapping` field

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`
- Test: `apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingJumpHostServerIdTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingJumpHostServerIdTests.swift`:

```swift
import CloudKit
import XCTest
@testable import CloudKitSyncClient
@testable import SSHCommandBuilder

final class CKRecordHostMappingJumpHostServerIdTests: XCTestCase {
	func testMakeRecordWritesJumpHostServerId() {
		var host = SSHHost(name: "n", hostname: "h", port: 22,
		                   username: "u", credential: .password)
		host.jumpHostServerId = "ck-bastion"
		let record = CKRecordHostMapping.makeRecord(host)
		XCTAssertEqual(record["jumpHostServerId"] as? String, "ck-bastion")
	}

	func testMakeRecordOmitsJumpHostServerIdWhenNil() {
		let host = SSHHost(name: "n", hostname: "h", port: 22,
		                   username: "u", credential: .password)
		let record = CKRecordHostMapping.makeRecord(host)
		XCTAssertNil(record["jumpHostServerId"])
	}

	func testApplyMetadataReadsJumpHostServerId() {
		var host = SSHHost(name: "n", hostname: "h", port: 22,
		                   username: "u", credential: .password)
		let record = CKRecord(recordType: "Host")
		record["jumpHostServerId"] = "ck-bastion" as CKRecordValue
		// Plus the other required metadata fields the mapping expects:
		record["name"] = "n" as CKRecordValue
		record["hostname"] = "h" as CKRecordValue
		record["port"] = 22 as CKRecordValue
		record["username"] = "u" as CKRecordValue
		record["authType"] = "password" as CKRecordValue
		record["metadataUpdatedAt"] = Date() as CKRecordValue
		CKRecordHostMapping.applyMetadata(record, to: &host)
		XCTAssertEqual(host.jumpHostServerId, "ck-bastion")
	}

	func testApplyMetadataLeavesJumpHostServerIdUnchangedWhenAbsent() {
		var host = SSHHost(name: "n", hostname: "h", port: 22,
		                   username: "u", credential: .password)
		host.jumpHostServerId = "preexisting"
		let record = CKRecord(recordType: "Host")
		record["name"] = "n" as CKRecordValue
		record["hostname"] = "h" as CKRecordValue
		record["port"] = 22 as CKRecordValue
		record["username"] = "u" as CKRecordValue
		record["authType"] = "password" as CKRecordValue
		record["metadataUpdatedAt"] = Date() as CKRecordValue
		// Note: no jumpHostServerId key — simulates an old-record decode.
		CKRecordHostMapping.applyMetadata(record, to: &host)
		// Spec §4.10: "Missing key → unchanged (decode-old-records compat)."
		XCTAssertEqual(host.jumpHostServerId, "preexisting")
	}
}
```

If existing tests in this directory use a different assertion helper or fixture, mirror that convention.

- [ ] **Step 2: Run to verify it fails**

```
cd apps/macos && swift test --filter CloudKitSyncClientTests.CKRecordHostMappingJumpHostServerIdTests 2>&1 | tail -15
```

Expected: build error or test failure — `jumpHostServerId` not in mapping.

- [ ] **Step 3: Add the field to the mapping**

Open `apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`. Find the `Field` enum (around line 10-26 per the explorer). Add a new case:

```swift
	enum Field: String {
		// ... existing cases ...
		case jumpHostServerId
	}
```

In `makeRecord(_:)`, add (use `if let` so nil is omitted entirely):

```swift
		if let jumpHostServerId = host.jumpHostServerId {
			record[Field.jumpHostServerId.rawValue] = jumpHostServerId as CKRecordValue
		}
```

In `applyMetadata(_:to:)`, add (use the `if let` form so missing keys leave the existing value unchanged):

```swift
		if let v = record[Field.jumpHostServerId.rawValue] as? String {
			host.jumpHostServerId = v
		}
```

If `CKRecordHostMapping` exposes a separate `decode(_:)` function that builds an `SSHHost` from a record, add a parallel read there:

```swift
		host.jumpHostServerId = record[Field.jumpHostServerId.rawValue] as? String
```

- [ ] **Step 4: Run the tests**

```
cd apps/macos && swift test --filter CloudKitSyncClientTests.CKRecordHostMappingJumpHostServerIdTests 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 701 / 12 / 0 (697 + 4 new).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift \
        apps/macos/Tests/CloudKitSyncClientTests/CKRecordHostMappingJumpHostServerIdTests.swift
git commit -m "feat(macos): sync jumpHostServerId via CloudKit Host record mapping"
```

---

## Task 5: Pure helpers — chain resolver + cycle filter

**Files:**
- Create: `apps/macos/Sources/SSHCommandBuilder/Chain.swift`
- Create: `apps/macos/Sources/SSHCommandBuilder/HostFormCycleFilter.swift`
- Test: `apps/macos/Tests/SSHCommandBuilderTests/ChainTests.swift`
- Test: `apps/macos/Tests/SSHCommandBuilderTests/HostFormCycleFilterTests.swift`

- [ ] **Step 1: Write the failing tests for `Chain.swift`**

Create `apps/macos/Tests/SSHCommandBuilderTests/ChainTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class ChainTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: .password)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	func testNoChainReturnsEmpty() throws {
		let target = host("target", "rh-target")
		XCTAssertEqual(try target.resolvedChain(in: [target]), [])
	}

	func testSingleHopReturnsAncestor() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let chain = try target.resolvedChain(in: [bastion, target])
		XCTAssertEqual(chain.map(\.name), ["bastion"])
	}

	func testMultiHopReturnsAncestorsInDialOrder() throws {
		// Connect order: deep → near → target.
		// Chain config: target.jump = mid; mid.jump = deep.
		// resolvedChain returns [deep, mid] (target is excluded).
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let chain = try target.resolvedChain(in: [deep, mid, target])
		XCTAssertEqual(chain.map(\.name), ["deep", "mid"])
	}

	func testMissingHostThrows() {
		let target = host("target", "rh-target", jump: "rh-ghost")
		XCTAssertThrowsError(try target.resolvedChain(in: [target])) { error in
			guard case ChainResolutionError.missingHost(let id) =
				error as? ChainResolutionError ?? .missingHost(serverId: "")
			else { return XCTFail("wrong error: \(error)") }
			XCTAssertEqual(id, "rh-ghost")
		}
	}

	func testSelfLoopThrows() {
		let target = host("target", "rh-target", jump: "rh-target")
		XCTAssertThrowsError(try target.resolvedChain(in: [target])) { error in
			guard case ChainResolutionError.cycle(let id) =
				error as? ChainResolutionError ?? .cycle(involvingServerId: "")
			else { return XCTFail("wrong error: \(error)") }
			XCTAssertEqual(id, "rh-target")
		}
	}

	func testTwoHostCycleThrows() {
		let a = host("a", "rh-a", jump: "rh-b")
		let b = host("b", "rh-b", jump: "rh-a")
		XCTAssertThrowsError(try a.resolvedChain(in: [a, b]))
	}

	func testFirstHopAddressOnDirectHostReturnsSelf() {
		let target = host("target", "rh-target")
		let addr = target.firstHopAddress(in: [target])
		XCTAssertEqual(addr?.hostname, "target.example.com")
		XCTAssertEqual(addr?.port, 22)
	}

	func testFirstHopAddressOnChainReturnsDeepestAncestor() {
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let addr = target.firstHopAddress(in: [deep, mid, target])
		XCTAssertEqual(addr?.hostname, "deep.example.com")
	}

	func testFirstHopAddressOnBrokenChainReturnsNil() {
		let target = host("target", "rh-target", jump: "rh-ghost")
		XCTAssertNil(target.firstHopAddress(in: [target]))
	}
}
```

- [ ] **Step 2: Run to verify they fail**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.ChainTests 2>&1 | tail -10
```

Expected: build error — `resolvedChain`, `firstHopAddress`, `ChainResolutionError` not defined.

- [ ] **Step 3: Implement `Chain.swift`**

Create `apps/macos/Sources/SSHCommandBuilder/Chain.swift`:

```swift
import Foundation

public enum ChainResolutionError: Error, Equatable {
	/// The `jumpHostServerId` references a host that's not in the
	/// in-memory list (deleted, or not yet pulled from CloudKit on
	/// this device).
	case missingHost(serverId: String)

	/// Self-loop or cycle. The associated `serverId` is the first
	/// node revisited.
	case cycle(involvingServerId: String)
}

public extension SSHHost {
	/// Returns the chain ancestors in connect order — index 0 is the
	/// host ssh dials *first* (deepest ancestor); the last entry is
	/// `self`'s direct parent. Returns an empty array when
	/// `jumpHostServerId` is nil. Throws when the chain cycles or
	/// references a host not present in `hosts`.
	func resolvedChain(in hosts: [SSHHost]) throws -> [SSHHost] {
		var ancestors: [SSHHost] = []
		var visited: Set<String> = []
		// Walk up from self.
		var cursor = self
		while let nextServerId = cursor.jumpHostServerId {
			// Self-loop / cycle check based on the parent chain only —
			// `self` is not in `visited` yet because the user might be
			// editing self before saving. We seed visited with self's
			// serverId if non-nil (so self-loop is caught).
			if let selfSid = self.serverId, visited.contains(selfSid) == false,
			   nextServerId == selfSid {
				throw ChainResolutionError.cycle(involvingServerId: selfSid)
			}
			if visited.contains(nextServerId) {
				throw ChainResolutionError.cycle(involvingServerId: nextServerId)
			}
			guard let parent = hosts.first(where: { $0.serverId == nextServerId }) else {
				throw ChainResolutionError.missingHost(serverId: nextServerId)
			}
			visited.insert(nextServerId)
			ancestors.append(parent)
			cursor = parent
		}
		// Currently `ancestors` is in walk order (parent, grandparent, ...).
		// Spec wants index 0 = deepest ancestor (the host ssh dials first).
		return ancestors.reversed()
	}

	/// First TCP endpoint ssh actually dials — i.e., the deepest
	/// ancestor's `(hostname, port)` when there's a chain, else
	/// `self`'s. Returns nil only when the chain is broken.
	func firstHopAddress(in hosts: [SSHHost]) -> (hostname: String, port: Int)? {
		do {
			let chain = try self.resolvedChain(in: hosts)
			if let deepest = chain.first {
				return (deepest.hostname, deepest.port)
			}
			return (self.hostname, self.port)
		} catch {
			return nil
		}
	}
}
```

- [ ] **Step 4: Run the chain tests**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.ChainTests 2>&1 | tail -10
```

Expected: 9 tests pass.

- [ ] **Step 5: Write the failing tests for `HostFormCycleFilter.swift`**

Create `apps/macos/Tests/SSHCommandBuilderTests/HostFormCycleFilterTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class HostFormCycleFilterTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: .password)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	func testFilterExcludesSelf() {
		let a = host("a", "rh-a")
		let b = host("b", "rh-b")
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b])
		XCTAssertEqual(filtered.map(\.name), ["b"])
	}

	func testFilterExcludesHostsWithoutServerId() {
		let a = host("a", "rh-a")
		let b = host("b", nil)            // not synced yet
		let c = host("c", "rh-c")
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b, c])
		XCTAssertEqual(filtered.map(\.name), ["c"])
	}

	func testFilterExcludesHostsWhoseChainPassesThroughEditingHost() {
		// If we're editing `a`, then `b` (whose chain is b → a) cannot be
		// picked as a's jump because that would create a cycle.
		let a = host("a", "rh-a")
		let b = host("b", "rh-b", jump: "rh-a")
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b])
		XCTAssertTrue(filtered.isEmpty,
			"b transitively references a so it must be filtered out")
	}

	func testFilterIncludesHostsWithUnrelatedChains() {
		let a = host("a", "rh-a")
		let b = host("b", "rh-b")
		let c = host("c", "rh-c", jump: "rh-b")  // c → b, no a
		let filtered = HostFormCycleFilter.eligibleJumpHosts(
			editingHost: a, allHosts: [a, b, c])
		XCTAssertEqual(Set(filtered.map(\.name)), Set(["b", "c"]))
	}
}
```

- [ ] **Step 6: Run to verify they fail**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.HostFormCycleFilterTests 2>&1 | tail -10
```

Expected: build error — `HostFormCycleFilter` not defined.

- [ ] **Step 7: Implement `HostFormCycleFilter.swift`**

Create `apps/macos/Sources/SSHCommandBuilder/HostFormCycleFilter.swift`:

```swift
import Foundation

/// Picker filter for `HostFormView`'s "Via host" dropdown. Pure function;
/// returns the subset of `allHosts` that can safely be used as
/// `editingHost`'s jump host without creating a cycle.
public enum HostFormCycleFilter {
	public static func eligibleJumpHosts(
		editingHost: SSHHost,
		allHosts: [SSHHost]
	) -> [SSHHost] {
		allHosts.filter { candidate in
			// Rule 1: cannot pick self.
			guard candidate.id != editingHost.id else { return false }
			// Rule 2: must be synced (have a serverId).
			guard candidate.serverId != nil else { return false }
			// Rule 3: candidate's transitive chain must not pass through
			// editingHost. Walk up via jumpHostServerId, lookup by serverId.
			var visited: Set<String> = []
			var cursor: SSHHost? = candidate
			while let cur = cursor, let nextSid = cur.jumpHostServerId {
				if nextSid == editingHost.serverId { return false }
				if visited.contains(nextSid) { return false }
				visited.insert(nextSid)
				cursor = allHosts.first { $0.serverId == nextSid }
			}
			return true
		}
	}
}
```

- [ ] **Step 8: Run the filter tests + the full suite**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.HostFormCycleFilterTests 2>&1 | tail -10
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: filter 4/4 pass; full suite 714 / 12 / 0 (701 + 9 chain + 4 filter).

- [ ] **Step 9: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/Chain.swift \
        apps/macos/Sources/SSHCommandBuilder/HostFormCycleFilter.swift \
        apps/macos/Tests/SSHCommandBuilderTests/ChainTests.swift \
        apps/macos/Tests/SSHCommandBuilderTests/HostFormCycleFilterTests.swift
git commit -m "feat(macos): add chain resolver and HostFormView cycle filter"
```

---

## Task 6: `SSHConfigQuote` — ssh_config-safe encoder

**Files:**
- Create: `apps/macos/Sources/SSHCommandBuilder/SSHConfigQuote.swift`
- Test: `apps/macos/Tests/SSHCommandBuilderTests/SSHConfigQuoteTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/Tests/SSHCommandBuilderTests/SSHConfigQuoteTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class SSHConfigQuoteTests: XCTestCase {
	func testPlainAsciiPassesThroughUnchanged() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("example.com"), "example.com")
		XCTAssertEqual(try SSHConfigQuote.encode("user"), "user")
		XCTAssertEqual(try SSHConfigQuote.encode("/Users/u/.ssh/key"),
		               "/Users/u/.ssh/key")
	}

	func testValueWithSpaceIsDoubleQuoted() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("hello world"),
		               "\"hello world\"")
	}

	func testValueWithDoubleQuoteIsEscaped() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("a\"b"),
		               "\"a\\\"b\"")
	}

	func testValueWithBackslashIsEscaped() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("a\\b"),
		               "\"a\\\\b\"")
	}

	func testValueWithBackslashAndQuoteEscapesBoth() throws {
		// Input: a\"b (a, backslash, quote, b)
		// Output: "a\\\"b"  (wrapped, \\\\, \\", literal a/b)
		XCTAssertEqual(try SSHConfigQuote.encode("a\\\"b"),
		               "\"a\\\\\\\"b\"")
	}

	func testEmptyStringYieldsEmptyQuotedPair() throws {
		// An empty value still needs to render as a token — `""`.
		XCTAssertEqual(try SSHConfigQuote.encode(""), "\"\"")
	}

	func testUnicodePassesThroughUnchanged() throws {
		XCTAssertEqual(try SSHConfigQuote.encode("hôst-1"), "hôst-1")
	}

	func testNewlineThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\nb")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testCarriageReturnThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\rb")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}

	func testNullThrowsControlCharacter() {
		XCTAssertThrowsError(try SSHConfigQuote.encode("a\0b")) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
	}
}
```

- [ ] **Step 2: Run to verify they fail**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.SSHConfigQuoteTests 2>&1 | tail -10
```

Expected: build error — `SSHConfigQuote` not defined.

- [ ] **Step 3: Implement `SSHConfigQuote.swift`**

Create `apps/macos/Sources/SSHCommandBuilder/SSHConfigQuote.swift`:

```swift
import Foundation

public enum SSHConfigQuoteError: Error, Equatable {
	/// Value contains a newline (\n), carriage return (\r), or NUL.
	/// ssh_config is line-oriented; embedded line terminators would
	/// inject new directives. We reject rather than escape.
	case controlCharacter
}

/// Encodes a value for safe inclusion as the right-hand side of an
/// ssh_config option line. ssh_config quoting is **not** shell quoting;
/// see the OpenSSH `ssh_config(5)` man page for the rules.
public enum SSHConfigQuote {
	public static func encode(_ value: String) throws -> String {
		// Reject control characters that would break the line-oriented
		// parser or could be smuggled in via UI fields.
		for scalar in value.unicodeScalars {
			if scalar == "\n" || scalar == "\r" || scalar == "\u{0}" {
				throw SSHConfigQuoteError.controlCharacter
			}
		}
		// If the value needs no quoting (plain word), emit it verbatim.
		// ssh_config recognizes whitespace, double quote, and backslash
		// as needing quoting. Everything else (including unicode) is fine.
		let needsQuoting = value.isEmpty
			|| value.contains(" ") || value.contains("\t")
			|| value.contains("\"") || value.contains("\\")
		if !needsQuoting {
			return value
		}
		// Wrap in double quotes; escape backslash and double-quote.
		var escaped = ""
		for ch in value {
			if ch == "\\" {
				escaped.append("\\\\")
			} else if ch == "\"" {
				escaped.append("\\\"")
			} else {
				escaped.append(ch)
			}
		}
		return "\"\(escaped)\""
	}
}
```

- [ ] **Step 4: Run the tests**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.SSHConfigQuoteTests 2>&1 | tail -10
```

Expected: 10 tests pass.

- [ ] **Step 5: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 724 / 12 / 0 (714 + 10 new).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHConfigQuote.swift \
        apps/macos/Tests/SSHCommandBuilderTests/SSHConfigQuoteTests.swift
git commit -m "feat(macos): add SSHConfigQuote encoder rejecting CR/LF/NUL injection"
```

---

## Task 7: `CatermAskpassCore` library + `ChainResolver`

**Files:**
- Modify: `apps/macos/Package.swift` — add new library target + test target
- Create: `apps/macos/Sources/CatermAskpassCore/ChainResolver.swift`
- Create: `apps/macos/Tests/CatermAskpassCoreTests/ChainResolverTests.swift`

- [ ] **Step 1: Add the new library target to `Package.swift`**

Open `apps/macos/Package.swift`. Find the `targets:` array. Add a new `.target` entry near the other library targets, and a new `.testTarget` near the existing test targets. Also add `"CatermAskpassCore"` to the `dependencies` of the existing `.executableTarget(name: "CatermAskpass", ...)`.

Insertions (preserve the surrounding style — Swift Package Manager files in this repo use 4-space indent except where a directly modified file uses tabs; match the existing Package.swift):

```swift
        .target(
            name: "CatermAskpassCore",
            path: "Sources/CatermAskpassCore"
        ),
        // ... near the executable target, ensure dependency is added:
        .executableTarget(
            name: "CatermAskpass",
            dependencies: [
                "KeychainStore",
                "CatermAskpassCore",   // NEW
            ]
        ),
        // ... near other testTargets:
        .testTarget(
            name: "CatermAskpassCoreTests",
            dependencies: ["CatermAskpassCore"],
            path: "Tests/CatermAskpassCoreTests"
        ),
```

- [ ] **Step 2: Write the failing tests**

Create `apps/macos/Tests/CatermAskpassCoreTests/ChainResolverTests.swift`:

```swift
import XCTest
@testable import CatermAskpassCore

final class ChainResolverTests: XCTestCase {
	private func entry(host: String, user: String = "u",
	                   port: Int = 22, hostId: String = "id-1",
	                   alias: String? = nil,
	                   keyPath: String? = nil) -> AskpassChainEntry {
		AskpassChainEntry(
			hostId: hostId,
			alias: alias ?? "caterm-h-\(hostId)",
			user: user,
			hostname: host,
			port: port,
			keyPath: keyPath
		)
	}

	func testPasswordPromptNoPortSingleCandidate() {
		let chain = [entry(host: "bastion.example.com", hostId: "id-1")]
		let r = resolveAskpassPrompt("u@bastion.example.com's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .found(.password(hostId: "id-1")))
	}

	func testPasswordPromptWithPortPicksByPort() {
		let chain = [
			entry(host: "h.example.com", port: 22, hostId: "id-22"),
			entry(host: "h.example.com", port: 2222, hostId: "id-2222"),
		]
		let r = resolveAskpassPrompt("u@h.example.com:2222's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .found(.password(hostId: "id-2222")))
	}

	func testPasswordPromptUsesAliasMatch() {
		// OpenSSH on some versions emits the connect alias in the prompt,
		// not the resolved HostName. Verify the resolver picks that up.
		let chain = [entry(host: "real.example.com",
		                   hostId: "id-1",
		                   alias: "caterm-h-id-1")]
		let r = resolveAskpassPrompt("u@caterm-h-id-1's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .found(.password(hostId: "id-1")))
	}

	func testPasswordPromptAmbiguousByUserHostnameWithoutPort() {
		// Two entries share user + hostname differ only by port. A
		// portless prompt must NOT silently pick one — it must fail.
		let chain = [
			entry(host: "h.example.com", port: 22, hostId: "id-22"),
			entry(host: "h.example.com", port: 2222, hostId: "id-2222"),
		]
		let r = resolveAskpassPrompt("u@h.example.com's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .ambiguous)
	}

	func testPasswordPromptNoMatchingUserReturnsNoMatch() {
		let chain = [entry(host: "h.example.com", user: "alice",
		                   hostId: "id-1")]
		let r = resolveAskpassPrompt("bob@h.example.com's password: ",
		                             chain: chain)
		XCTAssertEqual(r, .noMatch)
	}

	func testPassphrasePromptMatchesAbsolutePath() {
		let chain = [entry(host: "h.example.com", hostId: "id-1",
		                   keyPath: "/Users/u/.ssh/key")]
		let r = resolveAskpassPrompt(
			"Enter passphrase for key '/Users/u/.ssh/key': ",
			chain: chain)
		XCTAssertEqual(r, .found(.passphrase(hostId: "id-1")))
	}

	func testPassphrasePromptDoesNotMatchTildePath() {
		// ssh always expands ~/ before prompting, so a literal tilde
		// path in the prompt is never expected. Treat as noMatch.
		let chain = [entry(host: "h.example.com", hostId: "id-1",
		                   keyPath: "/Users/u/.ssh/key")]
		let r = resolveAskpassPrompt(
			"Enter passphrase for key '~/.ssh/key': ",
			chain: chain)
		XCTAssertEqual(r, .noMatch)
	}

	func testUnknownPromptFormatReturnsNoMatch() {
		let chain = [entry(host: "h.example.com", hostId: "id-1")]
		let r = resolveAskpassPrompt("Some other prompt: ", chain: chain)
		XCTAssertEqual(r, .noMatch)
	}

	func testEmptyChainReturnsNoMatchForAnyPrompt() {
		let r = resolveAskpassPrompt("u@h.example.com's password: ",
		                             chain: [])
		XCTAssertEqual(r, .noMatch)
	}
}
```

- [ ] **Step 3: Run to verify they fail**

```
cd apps/macos && swift test --filter CatermAskpassCoreTests.ChainResolverTests 2>&1 | tail -15
```

Expected: build error — `CatermAskpassCore` module / `AskpassChainEntry` / `resolveAskpassPrompt` not defined.

- [ ] **Step 4: Implement `ChainResolver.swift`**

Create `apps/macos/Sources/CatermAskpassCore/ChainResolver.swift`:

```swift
import Foundation

public struct AskpassChainEntry: Decodable, Equatable {
	public let hostId: String
	public let alias: String       // "caterm-h-<uuid>" — same as the Host block name in the generated ssh_config
	public let user: String
	public let hostname: String
	public let port: Int
	public let keyPath: String?

	public init(hostId: String, alias: String, user: String,
	            hostname: String, port: Int, keyPath: String?) {
		self.hostId = hostId
		self.alias = alias
		self.user = user
		self.hostname = hostname
		self.port = port
		self.keyPath = keyPath
	}
}

public enum AskpassLookup: Equatable {
	case password(hostId: String)
	case passphrase(hostId: String)
}

public enum AskpassResolution: Equatable {
	case found(AskpassLookup)
	case ambiguous              // multiple candidates, prompt has no port disambiguator
	case noMatch                // unknown prompt format or no chain entry
}

private let passwordRegex: NSRegularExpression = {
	// `<user>@<host>(:<port>)?'s password: `
	// host is non-colon, non-quote, non-whitespace; port is digits.
	let pattern = #"^(?<user>[^@]+)@(?<host>[^:'\s]+)(?::(?<port>\d+))?'s password: $"#
	return try! NSRegularExpression(pattern: pattern)
}()

private let passphraseRegex: NSRegularExpression = {
	// `Enter passphrase for key '<absolute path>': `
	let pattern = #"^Enter passphrase for key '(?<path>/[^']+)': $"#
	return try! NSRegularExpression(pattern: pattern)
}()

public func resolveAskpassPrompt(
	_ prompt: String,
	chain: [AskpassChainEntry]
) -> AskpassResolution {
	if let m = matchPasswordPrompt(prompt) {
		return resolvePassword(matched: m, chain: chain)
	}
	if let m = matchPassphrasePrompt(prompt) {
		return resolvePassphrase(matched: m, chain: chain)
	}
	return .noMatch
}

private struct PasswordMatch {
	let user: String
	let host: String
	let port: Int?
}

private func matchPasswordPrompt(_ prompt: String) -> PasswordMatch? {
	let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
	guard let m = passwordRegex.firstMatch(in: prompt, range: range),
	      let userRange = Range(m.range(withName: "user"), in: prompt),
	      let hostRange = Range(m.range(withName: "host"), in: prompt)
	else { return nil }
	let portRange = Range(m.range(withName: "port"), in: prompt)
	let port = portRange.flatMap { Int(prompt[$0]) }
	return PasswordMatch(
		user: String(prompt[userRange]),
		host: String(prompt[hostRange]),
		port: port
	)
}

private func matchPassphrasePrompt(_ prompt: String) -> String? {
	let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
	guard let m = passphraseRegex.firstMatch(in: prompt, range: range),
	      let pathRange = Range(m.range(withName: "path"), in: prompt)
	else { return nil }
	return String(prompt[pathRange])
}

private func resolvePassword(matched: PasswordMatch,
                             chain: [AskpassChainEntry]) -> AskpassResolution {
	// Candidates: same user AND (alias OR hostname) match.
	let candidates = chain.filter { entry in
		entry.user == matched.user
			&& (entry.alias == matched.host || entry.hostname == matched.host)
	}
	if candidates.isEmpty { return .noMatch }
	if let port = matched.port {
		let portFiltered = candidates.filter { $0.port == port }
		guard portFiltered.count == 1, let chosen = portFiltered.first else {
			return portFiltered.isEmpty ? .noMatch : .ambiguous
		}
		return .found(.password(hostId: chosen.hostId))
	}
	// Portless prompt: must be exactly one candidate.
	if candidates.count == 1, let chosen = candidates.first {
		return .found(.password(hostId: chosen.hostId))
	}
	return .ambiguous
}

private func resolvePassphrase(matched path: String,
                               chain: [AskpassChainEntry]) -> AskpassResolution {
	let candidates = chain.filter { $0.keyPath == path }
	if candidates.count == 1, let chosen = candidates.first {
		return .found(.passphrase(hostId: chosen.hostId))
	}
	return .noMatch
}
```

- [ ] **Step 5: Run the tests**

```
cd apps/macos && swift test --filter CatermAskpassCoreTests.ChainResolverTests 2>&1 | tail -10
```

Expected: 9 tests pass.

- [ ] **Step 6: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 733 / 12 / 0 (724 + 9 new).

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Package.swift \
        apps/macos/Sources/CatermAskpassCore/ChainResolver.swift \
        apps/macos/Tests/CatermAskpassCoreTests/ChainResolverTests.swift
git commit -m "feat(macos): add CatermAskpassCore with chain prompt resolver"
```

---

## Task 8: Wire `caterm-askpass` to `CatermAskpassCore` (chain-aware mode)

**Files:**
- Modify: `apps/macos/Sources/CatermAskpass/main.swift`

Goal: when `CATERM_CHAIN` is set, parse it as JSON, resolve `argv[1]` against it via `resolveAskpassPrompt`, and look up the resulting hostId's keychain item. When `CATERM_CHAIN` is absent, behavior is unchanged from the post-Task-1 single-host path.

This task has no new XCTest — the single-host behavior is already covered, and the chain-aware behavior is verified at integration time (Task 18 EndToEndSSHTests). The unit-level chain logic is already covered by `CatermAskpassCoreTests` (Task 7).

- [ ] **Step 1: Update `main.swift`**

Open `apps/macos/Sources/CatermAskpass/main.swift`. After `import KeychainStore` add:

```swift
import CatermAskpassCore
```

Insert the chain-mode branch BEFORE the existing `guard let hostId = env["CATERM_HOST_ID"] ...` check (so chain mode takes priority when active). The full new body becomes:

```swift
let env = ProcessInfo.processInfo.environment

// ... existing logURL + logLine helper unchanged ...

// ... existing CATERM_ASKPASS_STUFF dev-mode unchanged (uses keyPassphrase
// after Task 1) ...

// ── Chain mode ─────────────────────────────────────────────────────
// Triggered when SSHCommandBuilder set CATERM_CHAIN. The resolver
// matches argv[1] against the chain and tells us which host's
// secret to fetch. On ambiguity or unknown prompt, exit 2.
if let chainJSON = env["CATERM_CHAIN"], !chainJSON.isEmpty {
    let chain: [AskpassChainEntry]
    do {
        chain = try JSONDecoder().decode([AskpassChainEntry].self,
                                         from: Data(chainJSON.utf8))
    } catch {
        FileHandle.standardError.write(Data(
            "askpass: malformed CATERM_CHAIN: \(error)\n".utf8))
        logLine("FAIL exit=1 reason=chain-json-malformed")
        exit(1)
    }

    let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    let resolution = resolveAskpassPrompt(prompt, chain: chain)

    let hostId: String
    let kind: String
    switch resolution {
    case .found(.password(let id)):
        hostId = id
        kind = "password"
    case .found(.passphrase(let id)):
        hostId = id
        kind = "keyPassphrase"
    case .ambiguous:
        FileHandle.standardError.write(Data(
            "askpass: ambiguous chain entry for prompt: \(prompt)\n".utf8))
        logLine("FAIL exit=2 reason=chain-ambiguous prompt=\(prompt)")
        exit(2)
    case .noMatch:
        FileHandle.standardError.write(Data(
            "askpass: no chain entry matches prompt: \(prompt)\n".utf8))
        logLine("FAIL exit=2 reason=chain-no-match prompt=\(prompt)")
        exit(2)
    }

    let account = "\(hostId).\(kind)"
    let accessGroup = env["CATERM_ACCESS_GROUP"]
    let groupTag = accessGroup ?? "<nil>"
    let store = KeychainStore(service: "com.caterm.host",
                              accessGroup: accessGroup)
    do {
        let secret = try store.get(account: account)
        let out = secret + "\n"
        FileHandle.standardOutput.write(Data(out.utf8))
        logLine("OK exit=0 mode=chain account=\(account) " +
                "group=\(groupTag) secretLen=\(secret.count)")
        exit(0)
    } catch KeychainError.notFound {
        FileHandle.standardError.write(Data(
            "askpass: secret not found for \(account)\n".utf8))
        logLine("FAIL exit=2 mode=chain reason=keychain-not-found " +
                "account=\(account) group=\(groupTag)")
        exit(2)
    } catch {
        FileHandle.standardError.write(Data(
            "askpass: keychain error \(error)\n".utf8))
        logLine("FAIL exit=3 mode=chain reason=keychain-error " +
                "account=\(account) group=\(groupTag) error=\(error)")
        exit(3)
    }
}

// ── Single-host mode (existing behavior) ───────────────────────────
guard let hostId = env["CATERM_HOST_ID"], !hostId.isEmpty else {
    // ... existing existing code unchanged ...
}
// ... existing single-host code unchanged ...
```

(The existing single-host code starts immediately after the chain block. Do not modify it; it already uses the renamed `keyPassphrase` validation from Task 1.)

- [ ] **Step 2: Build to verify it compiles**

```
cd apps/macos && swift build 2>&1 | tail -10
```

Expected: `Build complete!`. If linker reports `CatermAskpassCore` symbols missing, double-check Task 7 added the dependency to the executable target's `dependencies` array in `Package.swift`.

- [ ] **Step 3: Run the full suite (regression)**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 733 / 12 / 0 (no new tests in this task).

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/CatermAskpass/main.swift
git commit -m "feat(macos): make caterm-askpass chain-aware via CATERM_CHAIN env"
```

---

## Task 9: `SSHCommandBuilder.perHostOptions` extraction (no behavior change)

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`

This is a pure refactor: lift the per-host option assembly into a named internal function so the chain code path (Task 10) can call it for each Host block. Direct-path callers must produce byte-identical output to before.

The existing `SSHCommandBuilderTests` already cover the direct-path golden command string. Their assertions are the regression gate for this refactor; we add no new tests in this task.

- [ ] **Step 1: Define the `PerHostOptions` value type**

In `SSHCommandBuilder.swift`, near the existing private types, add (TAB indentation):

```swift
	internal struct PerHostOptions {
		let hostName: String          // raw — encoded by SSHConfigQuote at emit time
		let port: Int
		let user: String              // raw
		let identityFile: String?     // raw, nil for password / agent
		let optionLines: [String]     // each "<key> <value>" with both halves
		                              // ALREADY encoded by SSHConfigQuote
		let env: [(String, String)]   // SSH_ASKPASS / CATERM_HOST_ID — only for target
	}
```

- [ ] **Step 2: Add `perHostOptions(...)` factored function**

Add this as a `static internal func` on `SSHCommandBuilder`. The body assembles the same options the existing `build()` produces today, in the same order. `isTarget` controls whether `env` is populated (chain non-target hosts set their identity via the IdentityFile config option, but the askpass env is set once on the target).

```swift
	internal static func perHostOptions(
		for host: SSHHost,
		isTarget: Bool,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		accessGroup: String?
	) throws -> PerHostOptions {
		var lines: [String] = []
		var env: [(String, String)] = []

		// Always.
		try lines.append("StrictHostKeyChecking accept-new")
		try lines.append("UserKnownHostsFile \(SSHConfigQuote.encode("\(knownHostsCaterm) \(knownHostsUser)"))")
		try lines.append("ControlMaster auto")
		try lines.append("ControlPersist 10m")
		let controlPath = "~/Library/Caches/Caterm/cm/\(host.id.uuidString).sock"
		try lines.append("ControlPath \(SSHConfigQuote.encode(controlPath))")

		// Per-credential.
		var identityFile: String? = nil
		switch host.credential {
		case .password:
			lines.append("PreferredAuthentications password,keyboard-interactive")
			lines.append("PubkeyAuthentication no")
			lines.append("NumberOfPasswordPrompts 1")
			if isTarget {
				env = [
					("SSH_ASKPASS", askpassPath),
					("SSH_ASKPASS_REQUIRE", "force"),
					("CATERM_HOST_ID", host.id.uuidString),
					("CATERM_ASKPASS_KIND", "password"),
				]
			}
		case let .keyFile(keyPath, hasPassphrase):
			lines.append("IdentitiesOnly yes")
			lines.append("PreferredAuthentications publickey")
			lines.append("PasswordAuthentication no")
			lines.append("KbdInteractiveAuthentication no")
			try lines.append("IdentityFile \(SSHConfigQuote.encode(keyPath))")
			identityFile = keyPath
			if hasPassphrase, isTarget {
				env = [
					("SSH_ASKPASS", askpassPath),
					("SSH_ASKPASS_REQUIRE", "force"),
					("CATERM_HOST_ID", host.id.uuidString),
					("CATERM_ASKPASS_KIND", "keyPassphrase"),
				]
			}
		case .agent:
			lines.append("BatchMode yes")
		}
		_ = accessGroup  // CATERM_ACCESS_GROUP is set by the SessionStore at the env-vars layer, not here
		return PerHostOptions(
			hostName: host.hostname,
			port: host.port,
			user: host.username,
			identityFile: identityFile,
			optionLines: lines,
			env: env
		)
	}
```

(Note the `_ = accessGroup` placeholder — `CATERM_ACCESS_GROUP` env continues to be set by SessionStore, NOT by SSHCommandBuilder. The parameter is reserved for future use.)

- [ ] **Step 3: Verify the existing `build()` still produces byte-identical output**

Do NOT yet rewrite `build()` to consume `perHostOptions`. The point of this task is just to add the factored function as dead code; Task 10 will switch the code paths. By keeping the existing `build()` body intact for now, we keep the regression risk to zero.

- [ ] **Step 4: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 733 / 12 / 0. The existing builder tests verify direct-path output unchanged.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift
git commit -m "refactor(macos): factor SSHCommandBuilder per-host options into reusable helper"
```

---

## Task 10: `SSHCommandBuilder` chain config emission + `Output.configURL`

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`
- Create: `apps/macos/Sources/SSHCommandBuilder/SSHConfigSink.swift`
- Test: `apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderChainTests.swift`

- [ ] **Step 1: Define `SSHConfigSink` protocol + in-memory fake**

Create `apps/macos/Sources/SSHCommandBuilder/SSHConfigSink.swift`:

```swift
import Foundation

public protocol SSHConfigSink: Sendable {
	/// Writes `config` to a file with mode 0600 and returns the URL.
	/// The caller passes the URL back to `cleanup(_:)` when done.
	func write(_ config: String) throws -> URL

	/// Removes the previously-written config file. No-op if it's
	/// already gone. Errors are swallowed (logged) — best-effort.
	func cleanup(_ url: URL)
}

/// Test fake. Captures the most recently written config in memory and
/// hands back a `tmpfs://N` URL. Never touches the filesystem.
public final class InMemorySSHConfigSink: SSHConfigSink, @unchecked Sendable {
	public private(set) var writes: [(URL, String)] = []
	public private(set) var cleanups: [URL] = []
	public init() {}
	public func write(_ config: String) throws -> URL {
		let url = URL(string: "tmpfs://\(writes.count)")!
		writes.append((url, config))
		return url
	}
	public func cleanup(_ url: URL) { cleanups.append(url) }
}
```

- [ ] **Step 2: Write the failing chain tests**

Create `apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderChainTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class SSHCommandBuilderChainTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil,
	                  cred: CredentialSource = .password) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: cred)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	func testDirectHostProducesNoConfigURL() throws {
		let target = host("target", "rh-target")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		XCTAssertNil(out.configURL)
		XCTAssertTrue(sink.writes.isEmpty)
	}

	func testSingleHopWritesConfigAndCommandUsesAlias() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		XCTAssertNotNil(out.configURL)
		XCTAssertEqual(sink.writes.count, 1)
		let config = sink.writes[0].1

		// Both Host blocks present, aliased "caterm-h-<uuid>".
		XCTAssertTrue(config.contains("Host caterm-h-\(bastion.id.uuidString)"))
		XCTAssertTrue(config.contains("Host caterm-h-\(target.id.uuidString)"))
		// Target block carries ProxyJump pointing at bastion's alias.
		XCTAssertTrue(config.contains(
			"ProxyJump caterm-h-\(bastion.id.uuidString)"),
			"target Host block must reference the ancestor alias")
		// Command uses the target alias.
		XCTAssertTrue(out.command.contains(
			"-F \(out.configURL!.path)") ||
			out.command.contains("-F '\(out.configURL!.path)'") ||
			out.command.contains("-F \(out.configURL!.absoluteString)"))
		XCTAssertTrue(out.command.contains(
			"caterm-h-\(target.id.uuidString)"))
	}

	func testMultiHopConfigHasProxyJumpExceptOnDeepest() throws {
		let deep = host("deep", "rh-deep")
		let mid = host("mid", "rh-mid", jump: "rh-deep")
		let target = host("target", "rh-target", jump: "rh-mid")
		let sink = InMemorySSHConfigSink()
		_ = try SSHCommandBuilder.build(
			host: target, ancestors: [deep, mid],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		let config = sink.writes[0].1

		// Find each Host block and check its ProxyJump-ness.
		// `deep` is the ssh-dialed first hop — no ProxyJump.
		let deepBlock = blockFor("caterm-h-\(deep.id.uuidString)",
		                         in: config)
		XCTAssertFalse(deepBlock.contains("ProxyJump"))
		// `mid` jumps via deep.
		let midBlock = blockFor("caterm-h-\(mid.id.uuidString)",
		                        in: config)
		XCTAssertTrue(midBlock.contains(
			"ProxyJump caterm-h-\(deep.id.uuidString)"))
		// `target` jumps via mid.
		let targetBlock = blockFor("caterm-h-\(target.id.uuidString)",
		                           in: config)
		XCTAssertTrue(targetBlock.contains(
			"ProxyJump caterm-h-\(mid.id.uuidString)"))
	}

	func testCATERMChainEnvContainsEveryHopWithMatchingAliases() throws {
		let bastion = host("bastion", "rh-bastion",
			cred: .keyFile(keyPath: "/k", hasPassphrase: true))
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let out = try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)
		guard let chainJSON = out.env.first(where: { $0.0 == "CATERM_CHAIN" })?.1
		else { return XCTFail("CATERM_CHAIN not set on chain") }
		let data = Data(chainJSON.utf8)
		guard let array = try JSONSerialization.jsonObject(with: data)
				as? [[String: Any]]
		else { return XCTFail("CATERM_CHAIN is not a JSON array") }
		XCTAssertEqual(array.count, 2)
		let aliases = array.compactMap { $0["alias"] as? String }
		XCTAssertEqual(Set(aliases), Set([
			"caterm-h-\(bastion.id.uuidString)",
			"caterm-h-\(target.id.uuidString)",
		]))
		// And the same aliases appear in the config file.
		let config = sink.writes[0].1
		for alias in aliases {
			XCTAssertTrue(config.contains("Host \(alias)"),
			              "alias \(alias) missing from ssh_config")
		}
	}

	func testNewlineInHostnameThrowsControlCharacter() {
		var bastion = host("bastion", "rh-bastion")
		bastion.hostname = "bastion.example.com\nProxyCommand /tmp/evil"
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		XCTAssertThrowsError(try SSHCommandBuilder.build(
			host: target, ancestors: [bastion],
			configSink: sink,
			askpassPath: "/usr/local/bin/caterm-askpass",
			knownHostsCaterm: "/k1", knownHostsUser: "/k2",
			installTerminfo: false, sshPath: "/usr/bin/ssh",
			terminfoDump: nil
		)) { error in
			XCTAssertEqual(error as? SSHConfigQuoteError, .controlCharacter)
		}
		// And no config was emitted.
		XCTAssertTrue(sink.writes.isEmpty)
	}

	// Helper: extract the contents of a Host block keyed by alias.
	private func blockFor(_ alias: String, in config: String) -> String {
		let lines = config.split(separator: "\n").map(String.init)
		guard let start = lines.firstIndex(where: { $0.hasPrefix("Host \(alias)") })
		else { return "" }
		var end = lines.count
		for i in (start + 1)..<lines.count {
			if lines[i].hasPrefix("Host ") { end = i; break }
		}
		return lines[start..<end].joined(separator: "\n")
	}
}
```

- [ ] **Step 3: Run to verify they fail**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.SSHCommandBuilderChainTests 2>&1 | tail -15
```

Expected: build error — `Output.configURL` not defined; `build` does not accept `ancestors:configSink:`.

- [ ] **Step 4: Update `Output` struct**

In `SSHCommandBuilder.swift`, change `Output` from a tuple to a struct (if it isn't already) and add `configURL`:

```swift
	public struct Output {
		public let command: String
		public let env: [(String, String)]
		public let configURL: URL?

		public init(command: String, env: [(String, String)],
		            configURL: URL? = nil) {
			self.command = command
			self.env = env
			self.configURL = configURL
		}
	}
```

If `Output` was a tuple, ALL existing callers need to switch to dot-access. Update the in-tree callers (`SessionStore.surfaceConfig`, any tests). The existing builder test that already checks `out.command` / `out.env` keeps working because struct field access has the same syntax.

- [ ] **Step 5: Update `build(...)` signature and body**

The new signature:

```swift
	public static func build(
		host: SSHHost,
		ancestors: [SSHHost] = [],
		configSink: SSHConfigSink,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool,
		sshPath: String,
		terminfoDump: String?
	) throws -> Output {
		if ancestors.isEmpty {
			return try buildDirect(
				host: host, askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm, knownHostsUser: knownHostsUser,
				installTerminfo: installTerminfo, sshPath: sshPath,
				terminfoDump: terminfoDump
			)
		}
		return try buildChain(
			target: host, ancestors: ancestors, configSink: configSink,
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm, knownHostsUser: knownHostsUser,
			installTerminfo: installTerminfo, sshPath: sshPath,
			terminfoDump: terminfoDump
		)
	}
```

Move the existing `build(...)` body into a private `buildDirect(...)` helper. The signature is the same minus `ancestors` and `configSink`. Return value wraps the same `(command, env)` into the new `Output(command:env:configURL: nil)`. Direct-path output is byte-identical.

Add the new `buildChain(...)` private helper:

```swift
	private static func buildChain(
		target: SSHHost,
		ancestors: [SSHHost],   // index 0 = deepest (dialed first)
		configSink: SSHConfigSink,
		askpassPath: String,
		knownHostsCaterm: String,
		knownHostsUser: String,
		installTerminfo: Bool,
		sshPath: String,
		terminfoDump: String?
	) throws -> Output {
		// Build a Host block for each ancestor + target.
		var blocks: [String] = []
		var chainEntries: [[String: Any]] = []
		let allHops = ancestors + [target]      // dial order: deep → near → target
		for (i, h) in allHops.enumerated() {
			let isTarget = (i == allHops.count - 1)
			let opts = try perHostOptions(
				for: h, isTarget: isTarget,
				askpassPath: askpassPath,
				knownHostsCaterm: knownHostsCaterm,
				knownHostsUser: knownHostsUser,
				accessGroup: nil
			)
			let alias = "caterm-h-\(h.id.uuidString)"
			var lines: [String] = []
			lines.append("Host \(alias)")
			lines.append("\tHostName \(try SSHConfigQuote.encode(opts.hostName))")
			lines.append("\tPort \(opts.port)")
			lines.append("\tUser \(try SSHConfigQuote.encode(opts.user))")
			for line in opts.optionLines {
				lines.append("\t\(line)")
			}
			if i > 0 {
				let parentAlias = "caterm-h-\(allHops[i - 1].id.uuidString)"
				lines.append("\tProxyJump \(parentAlias)")
			}
			blocks.append(lines.joined(separator: "\n"))

			// CATERM_CHAIN entry.
			var entry: [String: Any] = [
				"hostId": h.id.uuidString,
				"alias": alias,
				"user": h.username,
				"hostname": h.hostname,
				"port": h.port,
			]
			if case .keyFile(let path, _) = h.credential {
				entry["keyPath"] = path
			} else {
				entry["keyPath"] = NSNull()
			}
			chainEntries.append(entry)
		}
		let config = blocks.joined(separator: "\n\n") + "\n"
		let configURL = try configSink.write(config)

		// Build the env (target's env merged with CATERM_CHAIN).
		let targetOpts = try perHostOptions(
			for: target, isTarget: true,
			askpassPath: askpassPath,
			knownHostsCaterm: knownHostsCaterm,
			knownHostsUser: knownHostsUser,
			accessGroup: nil
		)
		var env = targetOpts.env
		// Encode CATERM_CHAIN as JSON.
		let chainData = try JSONSerialization.data(
			withJSONObject: chainEntries,
			options: [.sortedKeys]
		)
		let chainJSON = String(data: chainData, encoding: .utf8) ?? "[]"
		env.append(("CATERM_CHAIN", chainJSON))

		// Build the shell command. The configURL is a file:// URL; pass its
		// path via -F. The target alias is the operand to ssh.
		let sshArg = sshPath == "/usr/bin/ssh" ? sshPath : ShellQuote.posix(sshPath)
		let configPath = ShellQuote.posix(configURL.path)
		let alias = "caterm-h-\(target.id.uuidString)"
		var command = "\(sshArg) -F \(configPath) \(alias)"

		if installTerminfo, let dump = terminfoDump {
			// Wrap with the existing terminfo install pattern. Reuse
			// whatever helper buildDirect uses today; for clarity in this
			// plan, we inline the same shape:
			command = "TERM=xterm-ghostty \(command)"
			_ = dump  // The actual dump install logic is identical to buildDirect.
		}

		return Output(command: command, env: env, configURL: configURL)
	}
```

(If `buildDirect` uses a different terminfo-wrapping helper, lift that helper to the file scope so `buildChain` can reuse it. Do not duplicate the wrapping logic.)

- [ ] **Step 6: Run the chain tests**

```
cd apps/macos && swift test --filter SSHCommandBuilderTests.SSHCommandBuilderChainTests 2>&1 | tail -15
```

Expected: 5 tests pass.

- [ ] **Step 7: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 738 / 12 / 0 (733 + 5). Direct-path tests still green — `buildDirect` produces byte-identical output.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift \
        apps/macos/Sources/SSHCommandBuilder/SSHConfigSink.swift \
        apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderChainTests.swift
git commit -m "feat(macos): emit per-session ssh_config with ProxyJump for host chains"
```

---

## Task 11: `CatermSSHConfigSink` real implementation

**Files:**
- Create: `apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift`

This is the production `SSHConfigSink` that writes to `~/Library/Caches/Caterm/ssh-configs/<sessionId>.conf` with mode 0600. SessionStore will instantiate one per app launch.

No new tests — the file IO is exercised end-to-end by Task 18 EndToEndSSHTests. The InMemorySSHConfigSink fake (Task 10) covers SSHCommandBuilder unit tests.

- [ ] **Step 1: Create the file**

Create `apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift`:

```swift
import Foundation
import os
import SSHCommandBuilder

/// Real `SSHConfigSink` implementation. Writes per-session config files
/// under `~/Library/Caches/Caterm/ssh-configs/`, mode 0600. SessionStore
/// owns one instance and passes it to `SSHCommandBuilder.build(...)`.
public final class CatermSSHConfigSink: SSHConfigSink {
	private let log = Logger(subsystem: "com.caterm.session",
	                         category: "SSHConfigSink")
	private let directory: URL

	public init() {
		let caches = FileManager.default.urls(for: .cachesDirectory,
		                                      in: .userDomainMask)[0]
		self.directory = caches
			.appendingPathComponent("Caterm", isDirectory: true)
			.appendingPathComponent("ssh-configs", isDirectory: true)
		try? FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true,
			attributes: [.posixPermissions: NSNumber(value: 0o700)])
	}

	public func write(_ config: String) throws -> URL {
		let url = directory.appendingPathComponent("\(UUID().uuidString).conf")
		try config.data(using: .utf8)!.write(to: url, options: .atomic)
		try FileManager.default.setAttributes(
			[.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
		return url
	}

	public func cleanup(_ url: URL) {
		do {
			try FileManager.default.removeItem(at: url)
		} catch {
			log.error("ssh-config cleanup failed: \(error.localizedDescription)")
		}
	}
}
```

- [ ] **Step 2: Build to verify**

```
cd apps/macos && swift build 2>&1 | tail -10
```

Expected: `Build complete!`.

- [ ] **Step 3: Full test run (regression only)**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 738 / 12 / 0 (no new tests).

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift
git commit -m "feat(macos): add CatermSSHConfigSink writing ssh-configs/<uuid>.conf 0600"
```

---

## Task 12: SessionStore — `Tab.resolvedChain`, `Tab.sshConfigURL`, openTab precheck, runConnection firstHop preflight, closeTab cleanup

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`
- Test: `apps/macos/Tests/SessionStoreTests/SessionStoreChainTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/Tests/SessionStoreTests/SessionStoreChainTests.swift`:

```swift
import XCTest
@testable import SessionStore
@testable import SSHCommandBuilder

@MainActor
final class SessionStoreChainTests: XCTestCase {
	private func host(_ name: String, _ serverId: String?,
	                  jump: String? = nil,
	                  cred: CredentialSource = .password) -> SSHHost {
		var h = SSHHost(name: name, hostname: "\(name).example.com",
		                port: 22, username: "u", credential: cred)
		h.serverId = serverId
		h.jumpHostServerId = jump
		return h
	}

	/// Stub keychain that "has" credentials only for the host IDs in
	/// `present`. needsCredentialSetup reports true otherwise.
	private final class StubCredStore {
		let present: Set<UUID>
		init(present: Set<UUID>) { self.present = present }
	}

	func testOpenTabFailsFastOnBrokenChain() throws {
		// Arrange: target references missing serverId.
		let target = host("target", "rh-target", jump: "rh-ghost")
		let store = SessionStore.makeForTest(hosts: [target])
		let tabId = store.openTab(host: target)
		// Tab should be in failed state, runConnection NOT called.
		guard case .failed(let kind) = store.tabs.first(where: { $0.id == tabId })?.state
		else { return XCTFail("tab not failed") }
		guard case .networkUnreachable(.other(_, let msg)) = kind
		else { return XCTFail("wrong failure kind: \(kind)") }
		XCTAssertTrue(msg.contains("Jump host chain is broken"),
		              "got: \(msg)")
	}

	func testOpenTabFailsFastOnMissingCredentialOnAncestor() throws {
		let bastion = host("bastion", "rh-bastion")  // no credential set up
		let target = host("target", "rh-target", jump: "rh-bastion")
		let store = SessionStore.makeForTest(
			hosts: [bastion, target],
			credentialsAvailableFor: [target.id]   // bastion missing
		)
		let tabId = store.openTab(host: target)
		guard case .failed(let kind) = store.tabs.first(where: { $0.id == tabId })?.state,
		      case .networkUnreachable(.other(_, let msg)) = kind
		else { return XCTFail("expected failed networkUnreachable.other") }
		XCTAssertTrue(msg.contains("bastion") &&
		              msg.contains("needs credentials configured first"),
		              "got: \(msg)")
	}

	func testOpenTabPopulatesResolvedChainOnSuccess() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let store = SessionStore.makeForTest(
			hosts: [bastion, target],
			credentialsAvailableFor: [bastion.id, target.id]
		)
		let tabId = store.openTab(host: target)
		let tab = store.tabs.first(where: { $0.id == tabId })!
		XCTAssertEqual(tab.resolvedChain.map(\.serverId), ["rh-bastion"])
	}

	func testCloseTabCallsConfigSinkCleanupWhenSshConfigURLNonNil() throws {
		let bastion = host("bastion", "rh-bastion")
		let target = host("target", "rh-target", jump: "rh-bastion")
		let sink = InMemorySSHConfigSink()
		let store = SessionStore.makeForTest(
			hosts: [bastion, target],
			credentialsAvailableFor: [bastion.id, target.id],
			configSink: sink
		)
		let tabId = store.openTab(host: target)
		// Simulate runConnection landing in .authenticating with a configURL.
		// The exact wiring depends on production code; for this test we
		// directly inject a configURL onto the tab via a test-only helper
		// SessionStore.setSSHConfigURLForTest(_:tabId:).
		store.setSSHConfigURLForTest(URL(string: "tmpfs://0")!, tabId: tabId)
		store.closeTab(tabId: tabId)
		XCTAssertEqual(sink.cleanups, [URL(string: "tmpfs://0")!])
	}
}
```

(`SessionStore.makeForTest(...)` and `setSSHConfigURLForTest(_:tabId:)` are test-only helpers added in Step 3; their signatures match the tests above.)

- [ ] **Step 2: Run to verify they fail**

```
cd apps/macos && swift test --filter SessionStoreTests.SessionStoreChainTests 2>&1 | tail -15
```

Expected: build error / test failures — `resolvedChain`, `sshConfigURL`, `makeForTest`, `setSSHConfigURLForTest` not defined.

- [ ] **Step 3: Add the new fields and openTab logic**

Open `apps/macos/Sources/SessionStore/SessionStore.swift`. The `Tab` struct gains:

```swift
		var resolvedChain: [SSHHost] = []
		var sshConfigURL: URL? = nil
```

Add a new property on `SessionStore`:

```swift
	private let configSink: SSHConfigSink
```

Wire it through the existing initializer (production callers use `CatermSSHConfigSink()`; tests inject `InMemorySSHConfigSink()`).

Update `openTab(host:)`:

```swift
	@discardableResult
	public func openTab(host: SSHHost) -> UUID {
		// 1. Resolve the chain.
		let chain: [SSHHost]
		do {
			chain = try host.resolvedChain(in: hosts)
		} catch ChainResolutionError.cycle, ChainResolutionError.missingHost {
			let id = UUID()
			tabs.append(Tab(
				id: id, host: host, state: .failed(.networkUnreachable(
					.other(code: 0,
					       message: "Jump host chain is broken — edit host to fix"))),
				surfaceGeneration: 0,
				resolvedChain: [],
				sshConfigURL: nil
			))
			return id
		} catch {
			// Fallback for any other thrown error — also fail-fast.
			let id = UUID()
			tabs.append(Tab(
				id: id, host: host, state: .failed(.networkUnreachable(
					.other(code: 0, message: "Jump host chain error: \(error)"))),
				surfaceGeneration: 0,
				resolvedChain: [],
				sshConfigURL: nil
			))
			return id
		}

		// 2. Credential precheck for target + every ancestor.
		let needsCred: SSHHost? = ([host] + chain).first { needsCredentialSetup($0) }
		if let h = needsCred {
			let id = UUID()
			let msg = "\(h.name) needs credentials configured first — connect to it directly to set them up"
			tabs.append(Tab(
				id: id, host: host, state: .failed(.networkUnreachable(
					.other(code: 0, message: msg))),
				surfaceGeneration: 0,
				resolvedChain: [],
				sshConfigURL: nil
			))
			return id
		}

		// 3. Happy path — create the tab and start the connection.
		let id = UUID()
		tabs.append(Tab(
			id: id, host: host, state: .idle,
			surfaceGeneration: 0,
			resolvedChain: chain,
			sshConfigURL: nil
		))
		startConnection(tabId: id)
		return id
	}
```

Update `runConnection(tabId:)`:
- Change the preflight target from `host.hostname:host.port` to `host.firstHopAddress(in: hosts)`. If nil (broken chain — should never happen because openTab already filtered, but defense in depth), fail-fast with the same chain-broken message.
- Pass `resolvedChain` to `SSHCommandBuilder.build(...)` as `ancestors`. After `build` returns, capture `out.configURL` onto the tab via `applyIfCurrent`:

```swift
		applyIfCurrent(tabId: tabId, token: token) { tab in
			tab.sshConfigURL = out.configURL
			// ... existing surfaceGeneration bump etc ...
			tab.state = .authenticating(startedAt: Date())
		}
```

Update `closeTab(tabId:)`: BEFORE the existing control-socket cleanup, if `tab.sshConfigURL` is non-nil, call `configSink.cleanup(url)`.

Update `markChildExited(tabId:)` similarly: cleanup `sshConfigURL` once the ssh subprocess has exited (ssh has finished reading the config at this point).

Add the test-only helpers (gated behind `#if DEBUG` if the codebase uses that pattern; otherwise `internal` is fine):

```swift
	#if DEBUG
	internal func setSSHConfigURLForTest(_ url: URL, tabId: UUID) {
		guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
		tabs[idx].sshConfigURL = url
	}

	public static func makeForTest(
		hosts: [SSHHost],
		credentialsAvailableFor: Set<UUID> = [],
		configSink: SSHConfigSink = InMemorySSHConfigSink()
	) -> SessionStore {
		// Test-only construction that bypasses Keychain by stubbing
		// needsCredentialSetup. Match this to the existing test helpers
		// pattern in the codebase (see e.g. earlier SessionStoreConnectionFlowTests).
		// ...
	}
	#endif
```

(The exact `makeForTest` body depends on existing test helpers — match the pattern. The point is to inject hosts, a fake credential predicate, and a `SSHConfigSink`.)

- [ ] **Step 4: Run the chain tests**

```
cd apps/macos && swift test --filter SessionStoreTests.SessionStoreChainTests 2>&1 | tail -15
```

Expected: 4 tests pass.

- [ ] **Step 5: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 742 / 12 / 0 (738 + 4).

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift \
        apps/macos/Tests/SessionStoreTests/SessionStoreChainTests.swift
git commit -m "feat(macos): SessionStore openTab chain precheck, runConnection firstHop preflight, sshConfigURL cleanup"
```

---

## Task 13: HostFormView — "Via host" picker

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostFormView.swift`

No SwiftUI tests (no snapshot framework). Visual verification deferred to Task 17 manual checklist. Logic-level cycle filtering is already covered by `HostFormCycleFilterTests` (Task 5).

- [ ] **Step 1: Add the picker state**

Open `apps/macos/Sources/Caterm/Views/HostFormView.swift`. Add a `@State` (TAB indentation):

```swift
	@State private var jumpHostServerId: String? = nil
```

In `populate()`, copy from the host being edited:

```swift
		jumpHostServerId = host.jumpHostServerId
```

- [ ] **Step 2: Add a `LabeledContent("Via host")` row in the Connection section**

In `body`, inside the existing `Section("Connection") { … }` block (after `Username`), add:

```swift
				LabeledContent("Via host") {
					Picker(selection: $jumpHostServerId) {
						Text("(none)").tag(String?.none)
						ForEach(eligibleJumpHosts, id: \.id) { other in
							Text("\(other.name) (\(other.username)@\(other.hostname))")
								.tag(String?.some(other.serverId!))
						}
					}
					.pickerStyle(.menu)
					.labelsHidden()
				}
				if !chainPreviewText.isEmpty {
					Text(chainPreviewText)
						.font(.caption)
						.foregroundStyle(chainHasMissingHost ? .red : .secondary)
				}
```

- [ ] **Step 3: Add the computed properties**

```swift
	@EnvironmentObject private var sessionStore: SessionStore  // if not already present

	private var eligibleJumpHosts: [SSHHost] {
		guard case let .edit(currentHost) = mode else {
			// In .add mode, the new host has no id yet. Filter only by serverId presence.
			return sessionStore.hosts.filter { $0.serverId != nil }
		}
		return HostFormCycleFilter.eligibleJumpHosts(
			editingHost: currentHost,
			allHosts: sessionStore.hosts
		)
	}

	private var chainPreviewText: String {
		guard let sid = jumpHostServerId else { return "" }
		// Walk the chain by serverId and collect names.
		var names: [String] = []
		var cursor: String? = sid
		var visited: Set<String> = []
		while let nextSid = cursor {
			if visited.contains(nextSid) {
				names.append("(cycle)")
				break
			}
			visited.insert(nextSid)
			if let h = sessionStore.hosts.first(where: { $0.serverId == nextSid }) {
				names.append(h.name)
				cursor = h.jumpHostServerId
			} else {
				names.append("(deleted)")
				break
			}
		}
		return "Will connect via \(names.joined(separator: " → "))"
	}

	private var chainHasMissingHost: Bool {
		chainPreviewText.contains("(deleted)") || chainPreviewText.contains("(cycle)")
	}
```

- [ ] **Step 4: Update `submit()` to write the field**

In `submit()`, when constructing the `SSHHost` for `onSubmit`, set:

```swift
		host.jumpHostServerId = jumpHostServerId
```

(If the form uses `HostFormView.buildHost(...)`, add a `jumpHostServerId` parameter and pipe it through; mirror the existing host-shaping pattern.)

- [ ] **Step 5: Tighten `isValid`**

Add to the `isValid` computation: the host's resolved chain must succeed (no cycle, no missing host). This is defense-in-depth on top of the picker filter.

```swift
	private var isValid: Bool {
		// ... existing checks (hostname, port range, etc.) ...
		// Chain must resolve.
		var draft = SSHHost(
			name: resolvedName, hostname: hostname,
			port: Int(port) ?? 22, username: username,
			credential: cred
		)
		draft.jumpHostServerId = jumpHostServerId
		do {
			_ = try draft.resolvedChain(in: sessionStore.hosts)
		} catch {
			return false
		}
		return true
	}
```

- [ ] **Step 6: Build + full suite**

```
cd apps/macos && swift build 2>&1 | tail -10
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: build clean; 742 / 12 / 0.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostFormView.swift
git commit -m "feat(macos): add Via host picker with chain preview to HostFormView"
```

---

## Task 14: HostListSidebar — chain icon + fan-out delete alert

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostListSidebar.swift`

- [ ] **Step 1: Add the chain icon to host rows**

Open `apps/macos/Sources/Caterm/Views/HostListSidebar.swift`. Find the row rendering (the closure that returns the per-host SwiftUI view). Add an `if host.jumpHostServerId != nil { … }` conditional that renders:

```swift
								if host.jumpHostServerId != nil {
									Image(systemName: "arrow.triangle.branch")
										.font(.caption2)
										.foregroundStyle(.secondary)
										.help(chainTooltip(for: host))
								}
```

Add the tooltip helper (TAB indentation):

```swift
	private func chainTooltip(for host: SSHHost) -> String {
		var names: [String] = []
		var cursor: String? = host.jumpHostServerId
		var visited: Set<String> = []
		while let nextSid = cursor {
			if visited.contains(nextSid) { names.append("(cycle)"); break }
			visited.insert(nextSid)
			if let h = store.hosts.first(where: { $0.serverId == nextSid }) {
				names.append(h.name)
				cursor = h.jumpHostServerId
			} else {
				names.append("(deleted)")
				break
			}
		}
		return "via \(names.joined(separator: " → "))"
	}
```

- [ ] **Step 2: Wrap deletion in a fan-out check**

Locate the existing host-deletion handler (probably triggered by a context menu or swipe action). Wrap the delete in:

```swift
	private func deleteHost(_ host: SSHHost) {
		let dependents = store.hosts.filter {
			$0.id != host.id && $0.jumpHostServerId == host.serverId
		}
		if !dependents.isEmpty, let serverId = host.serverId {
			pendingFanoutDelete = PendingFanoutDelete(
				host: host, serverId: serverId, dependents: dependents)
			return
		}
		// No dependents; proceed.
		try? store.deleteHost(id: host.id)
	}
```

Add the supporting state and alert at the top of the view (or wherever existing alerts live):

```swift
	@State private var pendingFanoutDelete: PendingFanoutDelete?

	private struct PendingFanoutDelete: Identifiable {
		let host: SSHHost
		let serverId: String
		let dependents: [SSHHost]
		var id: UUID { host.id }
	}
```

And:

```swift
			.alert(item: $pendingFanoutDelete) { pending in
				Alert(
					title: Text("Delete \(pending.host.name)?"),
					message: Text("\(pending.host.name) is used by \(pending.dependents.count) host(s) as their jump host. Deleting will leave their chain references dangling."),
					primaryButton: .destructive(Text("Delete anyway")) {
						try? store.deleteHost(id: pending.host.id)
					},
					secondaryButton: .cancel()
				)
			}
```

- [ ] **Step 2 (continued): Build + full suite**

```
cd apps/macos && swift build 2>&1 | tail -10
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 742 / 12 / 0 (no new tests in this task — visual; see Task 17 manual checklist).

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostListSidebar.swift
git commit -m "feat(macos): chain icon + fan-out delete alert in HostListSidebar"
```

---

## Task 15: Overlays — chain caption in `ConnectingOverlay`, `FailureOverlay`, `ReconnectOverlay`

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift`
- Modify: `apps/macos/Sources/Caterm/Views/FailureOverlay.swift`
- Modify: `apps/macos/Sources/Caterm/Views/ReconnectOverlay.swift`
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift` (call sites pass `chain`)

- [ ] **Step 1: Add a `chain` parameter to each overlay**

In each of the three overlay files, add a parameter at the top of the struct (TAB indentation):

```swift
	let chain: [SSHHost]
```

Below the existing `user@host:port` line in each `body`, insert:

```swift
				if !chain.isEmpty {
					Text("via \(chain.map { "\($0.username)@\($0.hostname)" }.joined(separator: " → "))")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
```

- [ ] **Step 2: Pass `tab.resolvedChain` from `TerminalContainerView`**

In `TerminalContainerView.swift`, where each overlay is instantiated, pass `chain: tab.resolvedChain`. Search for `ConnectingOverlay(`, `FailureOverlay(`, `ReconnectOverlay(` and update each constructor call.

- [ ] **Step 3: Build + full suite**

```
cd apps/macos && swift build 2>&1 | tail -10
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 742 / 12 / 0.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift \
        apps/macos/Sources/Caterm/Views/FailureOverlay.swift \
        apps/macos/Sources/Caterm/Views/ReconnectOverlay.swift \
        apps/macos/Sources/Caterm/Views/TerminalContainerView.swift
git commit -m "feat(macos): show chain caption in connecting / failure / reconnect overlays"
```

---

## Task 16: `EndToEndSSHTests` chain integration cases

**Files:**
- Modify: `apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift`

The existing `EndToEndSSHTests` infrastructure already starts `sshd` containers per the prior SSH connection progress feature. We add three chain cases on top of that fixture.

- [ ] **Step 1: Identify the existing fixture helpers**

Read `EndToEndSSHTests.swift` to find the helper that starts an `sshd` container and yields its host/port + a `Host` value. The helpers below assume a function shaped like
`startSshd(credential: CredentialSource) async throws -> SSHHost`.
If the actual signature differs, adapt.

- [ ] **Step 2: Add the chain success test**

Append to `EndToEndSSHTests`:

```swift
	func testSingleHopChainSuccess() async throws {
		// Spin up two sshd containers; configure host B with
		// jumpHostServerId pointing to A.
		let a = try await startSshd(credential: .keyFile(keyPath: "/k/a", hasPassphrase: false))
		var b = try await startSshd(credential: .keyFile(keyPath: "/k/b", hasPassphrase: false))
		b.jumpHostServerId = a.serverId
		let store = makeProductionLikeStore(hosts: [a, b])
		let tabId = store.openTab(host: b)
		try await store.awaitConnectionAttempt(tabId: tabId)
		guard case .connected = store.tabs.first(where: { $0.id == tabId })?.state
		else { return XCTFail("chain did not connect") }
	}

	func testSingleHopChainWithPasswordOnJump() async throws {
		let a = try await startSshd(credential: .password)
		// Seed A's password into the keychain via the existing askpass-stuff
		// dev-mode pattern (see EndToEndSSHTests existing seeding).
		try seedPassword("aPassword", forHostId: a.id)
		var b = try await startSshd(credential: .keyFile(keyPath: "/k/b", hasPassphrase: false))
		b.jumpHostServerId = a.serverId
		let store = makeProductionLikeStore(hosts: [a, b])
		let tabId = store.openTab(host: b)
		try await store.awaitConnectionAttempt(tabId: tabId)
		guard case .connected = store.tabs.first(where: { $0.id == tabId })?.state
		else { return XCTFail("chain did not connect with password jump") }
	}

	func testSingleHopChainWithKeyPassphraseOnJump() async throws {
		let a = try await startSshd(credential: .keyFile(keyPath: "/k/a", hasPassphrase: true))
		try seedPassphrase("aPassphrase", forHostId: a.id)
		var b = try await startSshd(credential: .keyFile(keyPath: "/k/b", hasPassphrase: false))
		b.jumpHostServerId = a.serverId
		let store = makeProductionLikeStore(hosts: [a, b])
		let tabId = store.openTab(host: b)
		try await store.awaitConnectionAttempt(tabId: tabId)
		guard case .connected = store.tabs.first(where: { $0.id == tabId })?.state
		else { return XCTFail("chain did not connect with passphrase jump") }
	}

	func testBrokenChainFailsFastWithoutSpawningSsh() async throws {
		var b = try await startSshd(credential: .keyFile(keyPath: "/k/b", hasPassphrase: false))
		b.jumpHostServerId = "nonexistent-server-id"
		let store = makeProductionLikeStore(hosts: [b])
		let tabId = store.openTab(host: b)
		guard case .failed(let kind) = store.tabs.first(where: { $0.id == tabId })?.state,
		      case .networkUnreachable(.other(_, let msg)) = kind
		else { return XCTFail("expected fail-fast on broken chain") }
		XCTAssertTrue(msg.contains("Jump host chain is broken"))
	}

	func testMissingCredentialOnJumpFailsFastWithoutSpawningSsh() async throws {
		var a = try await startSshd(credential: .password)
		// Intentionally do NOT seed A's password.
		var b = try await startSshd(credential: .keyFile(keyPath: "/k/b", hasPassphrase: false))
		b.jumpHostServerId = a.serverId
		let store = makeProductionLikeStore(hosts: [a, b])
		let tabId = store.openTab(host: b)
		guard case .failed(let kind) = store.tabs.first(where: { $0.id == tabId })?.state,
		      case .networkUnreachable(.other(_, let msg)) = kind
		else { return XCTFail("expected fail-fast on missing credential") }
		XCTAssertTrue(msg.contains(a.name) &&
		              msg.contains("needs credentials configured first"))
		_ = b
	}
```

(`makeProductionLikeStore` and the password/passphrase seeding helpers either already exist in this test file or follow patterns from prior tests. If they don't exist, copy the production `SessionStore.init(...)` invocation from `apps/macos/Sources/Caterm/CatermApp.swift` and inject `CatermSSHConfigSink()`.)

- [ ] **Step 3: Run the chain integration tests**

```
cd apps/macos && swift test --filter SessionStoreTests.EndToEndSSHTests 2>&1 | tail -20
```

Expected: pre-existing tests still pass; 5 new tests pass.

- [ ] **Step 4: Run the full suite**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 747 / 12 / 0 (742 + 5). Some integration tests may be skipped in environments without docker — that's fine; the skipped count rises by however many docker-gated tests there are.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift
git commit -m "test(macos): add chain integration cases (single hop, password jump, key passphrase jump, broken chain, missing cred)"
```

---

## Task 17: Manual verification checklist

**Files:**
- Create: `apps/macos/Manual/host-chaining-checklist.md`

- [ ] **Step 1: Create the checklist**

Create `apps/macos/Manual/host-chaining-checklist.md`:

```markdown
# Host Chaining — Manual Verification

Run after any change to `SSHHost` data model, `SSHCommandBuilder`,
`CatermAskpass`/`CatermAskpassCore`, `SessionStore`, the host form,
the sidebar, or any of the connection overlays.

Build + launch:

```
cd apps/macos && make run-app
```

## 1. Single hop — keyFile + agent (happy path)
- Configure host A with key auth and connect once to seed credentials.
- Configure host B; in the **Via host** picker, select A. The caption
  should read `Will connect via A`. Save.
- Connect B.
- **Expect:** `ConnectingOverlay` shows `via u@A.example.com` below
  the host line. Connection succeeds.

## 2. Single hop — password jump
- Configure A with password auth; connect once to seed the password.
- Configure B with `Via host = A`.
- Connect B.
- **Expect:** Connection succeeds. `caterm-askpass.log` (in
  `~/Library/Logs/Caterm/`) contains a line with
  `mode=chain account=<A-uuid>.password`.

## 3. Single hop — key+passphrase jump (also exercises Task 1 prereq fix)
- Configure A with `keyFile` + passphrase; connect once to seed.
- Configure B with `Via host = A`.
- Connect B.
- **Expect:** Connection succeeds. Log line shows
  `mode=chain account=<A-uuid>.keyPassphrase`.

## 4. Multi-hop — A → B → target
- Configure C with `Via host = B` (where B has `Via host = A`).
- Connect C.
- **Expect:** ConnectingOverlay shows `via u@A → u@B`. Connection
  succeeds.

## 5. Cycle prevention at edit time
- Edit B and try to set `Via host = B`. The picker excludes B
  (self-reference rule).
- Edit A and try to set `Via host = B`. The picker excludes B
  because B's chain references A (cycle prevention).

## 6. Broken chain after deletion
- Configure B → A. Verify connection works.
- Delete A. The fan-out alert appears: "A is used by 1 host as their
  jump host. Delete anyway?". Confirm.
- Open B's edit form. The chain caption reads
  `Will connect via (deleted)` in red. Save is disabled.
- Try to connect B. The tab opens directly to a `FailureOverlay`
  reading "Jump host chain is broken — edit host to fix" without
  ever spawning ssh.

## 7. Missing credential on jump
- Configure A but skip the credential setup (or revoke it via the
  sidebar's credential reset). Configure B → A.
- Try to connect B.
- **Expect:** Tab opens directly to FailureOverlay reading
  `A needs credentials configured first — connect to it directly to
  set them up`. ssh is never spawned.

## 8. Sidebar chain icon
- Hosts with `jumpHostServerId` set show the
  `arrow.triangle.branch` icon next to the name.
- Hovering surfaces a tooltip with the full chain text
  (`via A → B`).

## 9. CloudKit sync to a second device
- On device 1, configure B → A and let sync settle.
- On device 2 (same iCloud account), wait for the next sync. B's
  edit form should show `Via host = A` correctly.
- Note: credentials do NOT sync (Keychain is local). Re-enter A's
  credential on device 2 before connecting B.

## 10. Server-sync (custom backend) round-trip
- Edit B → A on device 1; trigger a push.
- On a fresh-install device 2 logged into the same Caterm account,
  pull. B's `jumpHostServerId` should match A's `serverId`.

## 11. ssh_config injection rejection
- Edit a host and try to set the hostname to `bastion\nProxyCommand /tmp/evil`
  (paste a literal newline). Save.
- **Expect:** Save is rejected with a validation error, OR the save
  succeeds at the form level but the eventual connect fails-fast
  with "ssh_config encoding error" rather than executing the
  injected ProxyCommand.
- Verify with `ls -la ~/Library/Caches/Caterm/ssh-configs/` that no
  config containing the injected ProxyCommand was written.

## 12. Cleanup of per-session ssh_config files
- Connect a chain. Note files in
  `~/Library/Caches/Caterm/ssh-configs/`. Close the tab.
- **Expect:** the corresponding `.conf` file is deleted within
  seconds of tab close.
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/Manual/host-chaining-checklist.md
git commit -m "docs(macos): manual checklist for host chaining"
```

---

## Task 18: Final lint, build, and full test run

- [ ] **Step 1: Lint**

```
bun x ultracite check
```

Expected: no new errors. Pre-existing errors in
`.superpowers/brainstorm/...` HTML scratch files are gitignored and
unrelated.

- [ ] **Step 2: Full Swift test run**

```
cd apps/macos && swift test 2>&1 | tail -10
```

Expected: 747 / 12 / 0.

- [ ] **Step 3: Build the app and smoke-test scenarios 1, 4, and 11 from the manual checklist**

```
cd apps/macos && make run-app
```

In the running app:
1. Configure a single-hop chain with key auth (checklist §1) — verify connect succeeds and overlay shows the chain caption.
4. Configure a 3-hop chain (checklist §4) — verify connect succeeds and overlay shows both ancestors in the caption.
11. Try to inject a newline into a hostname (checklist §11) — verify the build fails-closed without writing a malicious ssh_config.

- [ ] **Step 4: No final commit needed unless cleanup**

This task is verification-only.

---

## Done

The redesign is complete when:

- ✅ All 18 tasks above are merged into the rio-de-janeiro branch.
- ✅ The server-side prerequisite (Drizzle migration + ssh-host router input/output schema) has landed in a separate commit on `apps/server` / `packages/api` / `packages/db`.
- ✅ `swift test` shows 747 / 12 / 0.
- ✅ `swift build` is clean.
- ✅ Scenarios 1, 4, and 11 from `apps/macos/Manual/host-chaining-checklist.md` pass on a real macOS launch.
- ✅ A user can configure host B with `Via host = A` and connect through it. ConnectingOverlay shows the chain caption. FailureOverlay surfaces the underlying ssh stderr if any hop fails.
- ✅ Multi-hop chains (A → B → C → target) work via implicit recursion.
- ✅ Cycles, broken references, and missing credentials are caught at edit time AND at connect time, never reaching the ssh subprocess.
- ✅ The fix to `keyPassphrase` keychain account suffix means key+passphrase auth (single-host AND chain) now works.
