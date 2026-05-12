# Port Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-host SSH port forwarding (Local `-L`, Remote `-R`, Dynamic SOCKS `-D`) to Caterm: forwards are a `Host` sub-property, established when the terminal session opens, torn down when it closes.

**Architecture:** Forward configuration ships as `[PortForward]` on `Host`. `SSHCommandBuilder` emits forward lines into the target host's `ssh_config` block (chain mode) or `-o` flags (direct mode). `Preflight` adds a local-bind probe to catch port conflicts before ssh starts. Required-forward semantics map to OpenSSH `ExitOnForwardFailure=yes` only when every forward is required (the option is global). Forwards sync via a new JSON field on existing `Host` CKRecords and server payloads. Hosts with forwards skip the 30 s `ControlMaster` grace on tab close.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, Combine, Network framework (`NWListener`), CloudKit, XCTest. Existing modules: `SSHCommandBuilder`, `SessionStore`, `HostSyncStore`, `CloudKitSyncClient`, `ServerSyncClient`, `Caterm` UI target.

**Spec:** `docs/superpowers/specs/2026-05-12-port-forwarding-design.md`

---

## File Structure

### New files

- `apps/macos/Sources/SSHCommandBuilder/PortForward.swift` — `PortForward` value type, validation rules, ssh_config line serialization helper.
- `apps/macos/Tests/SSHCommandBuilderTests/PortForwardValidationTests.swift` — covers the 6 validation rules.
- `apps/macos/Tests/SSHCommandBuilderTests/PortForwardSnapshotTests.swift` — ssh_config / `-o` emission snapshots for all kinds × bind-address × required permutations, including chain mode and `ExitOnForwardFailure` gating.
- `apps/macos/Manual/port-forwarding-smoke.md` — manual smoke checklist.

### Modified files

- `apps/macos/Sources/SSHCommandBuilder/Host.swift` — add `forwards: [PortForward]` field with codec compat.
- `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift` — emit forward lines in `perHostOptions` (target only) and equivalent `-o` flags in `_build`.
- `apps/macos/Sources/SessionStore/PreflightProbing.swift` — extend protocol with `probeLocalBind(address:port:) async -> PortBindOutcome`.
- `apps/macos/Sources/SessionStore/Preflight.swift` — implement `probeLocalBind` via `NWListener`.
- `apps/macos/Sources/SessionStore/FailureKind.swift` — add `.portForwardBindFailed(forward:reason:)` case.
- `apps/macos/Sources/SessionStore/SessionStore.swift` — add `skippedForwardNotices` published state; probe forwards in `startConnection`; differentiate `closeTab` teardown; carry `forwards` through `applyRemoteMetadata` and `addRemoteHost`.
- `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift` — handle new `FailureKind` case in `shouldShowFailureOverlay`.
- `apps/macos/Sources/SessionStore/ReconnectScheduler.swift` — handle new `FailureKind` case in `shouldReconnect`.
- `apps/macos/Sources/Caterm/Views/FailurePresentation.swift` — render new case copy.
- `apps/macos/Sources/ServerSyncClient/RemoteHost.swift` — add `forwards` to `RemoteHost` / `RemoteHostCreateInput` / `RemoteHostUpdateInput`.
- `apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift` — push writes `forwards` JSON string; pull decodes back.
- `apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift` — include `forwards` in host-update diff.
- `apps/macos/Sources/Caterm/Views/HostFormView.swift` — new "Port Forwarding" Section.
- `apps/macos/Sources/Caterm/Views/MainWindow.swift` — render yellow `Banner` for `store.skippedForwardNotices`.

### Tests touched

- `apps/macos/Tests/SSHCommandBuilderTests/*` — see new files above.
- `apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift` — preflight, closeTab differentiation, applyRemoteMetadata, addRemoteHost, updatedAt bump.
- `apps/macos/Tests/SessionStoreTests/PreflightTests.swift` — new `probeLocalBind` cases.
- `apps/macos/Tests/CloudKitSyncClientTests/CloudKitSyncClientTests.swift` — push/pull of `forwards` field; `metadataUpdatedAt` advance.
- `apps/macos/Tests/HostSyncStoreTests/HostSyncStoreTests.swift` — reconciler diff includes `forwards`.

---

## Tasks

### Task 1: Define `PortForward` value type

**Files:**
- Create: `apps/macos/Sources/SSHCommandBuilder/PortForward.swift`

- [ ] **Step 1: Write the type**

```swift
import Foundation

public struct PortForward: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case local
        case remote
        case dynamic
    }

    public enum BindFailureReason: String, Codable, Error, Sendable {
        case alreadyInUse
        case permissionDenied
        case unknown
    }

    public enum ValidationError: Error, Equatable {
        case bindPortOutOfRange(Int)
        case remotePortOutOfRange(Int)
        case missingRemoteForLocalOrRemote
        case unexpectedRemoteForDynamic
        case duplicateBinding(kind: Kind, bindAddress: String, bindPort: Int)
    }

    public let id: UUID
    public var kind: Kind
    public var bindAddress: String?
    public var bindPort: Int
    public var remoteHost: String?
    public var remotePort: Int?
    public var required: Bool
    public var label: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        bindAddress: String? = nil,
        bindPort: Int,
        remoteHost: String? = nil,
        remotePort: Int? = nil,
        required: Bool = true,
        label: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bindAddress = bindAddress
        self.bindPort = bindPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.required = required
        self.label = label
    }

    /// Validates one forward in isolation. Cross-forward uniqueness lives in
    /// `validateCollection(_:)`.
    public func validate() throws {
        guard (1...65535).contains(bindPort) else {
            throw ValidationError.bindPortOutOfRange(bindPort)
        }
        if let p = remotePort, !(1...65535).contains(p) {
            throw ValidationError.remotePortOutOfRange(p)
        }
        switch kind {
        case .local, .remote:
            guard let host = remoteHost, !host.isEmpty, remotePort != nil else {
                throw ValidationError.missingRemoteForLocalOrRemote
            }
        case .dynamic:
            guard remoteHost == nil, remotePort == nil else {
                throw ValidationError.unexpectedRemoteForDynamic
            }
        }
    }

    /// Validates a list and rejects same (kind, bindAddress, bindPort) tuples.
    public static func validateCollection(_ forwards: [PortForward]) throws {
        var seen: Set<String> = []
        for f in forwards {
            try f.validate()
            let key = "\(f.kind.rawValue)|\(f.bindAddress ?? "localhost")|\(f.bindPort)"
            if !seen.insert(key).inserted {
                throw ValidationError.duplicateBinding(
                    kind: f.kind,
                    bindAddress: f.bindAddress ?? "localhost",
                    bindPort: f.bindPort
                )
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/PortForward.swift
git commit -m "feat(macos): add PortForward value type and validation"
```

---

### Task 2: Validation tests for `PortForward`

**Files:**
- Create: `apps/macos/Tests/SSHCommandBuilderTests/PortForwardValidationTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SSHCommandBuilder

final class PortForwardValidationTests: XCTestCase {

    func test_local_happyPath() throws {
        let f = PortForward(kind: .local, bindPort: 5432,
                            remoteHost: "db.internal", remotePort: 5432)
        XCTAssertNoThrow(try f.validate())
    }

    func test_dynamic_happyPath() throws {
        let f = PortForward(kind: .dynamic, bindPort: 1080)
        XCTAssertNoThrow(try f.validate())
    }

    func test_bindPort_belowRange_throws() {
        let f = PortForward(kind: .local, bindPort: 0,
                            remoteHost: "h", remotePort: 22)
        XCTAssertThrowsError(try f.validate()) { error in
            XCTAssertEqual(error as? PortForward.ValidationError,
                           .bindPortOutOfRange(0))
        }
    }

    func test_bindPort_aboveRange_throws() {
        let f = PortForward(kind: .local, bindPort: 65_536,
                            remoteHost: "h", remotePort: 22)
        XCTAssertThrowsError(try f.validate()) { error in
            XCTAssertEqual(error as? PortForward.ValidationError,
                           .bindPortOutOfRange(65_536))
        }
    }

    func test_local_missingRemote_throws() {
        let f = PortForward(kind: .local, bindPort: 5432)
        XCTAssertThrowsError(try f.validate()) { error in
            XCTAssertEqual(error as? PortForward.ValidationError,
                           .missingRemoteForLocalOrRemote)
        }
    }

    func test_remote_missingPort_throws() {
        let f = PortForward(kind: .remote, bindPort: 9090,
                            remoteHost: "h", remotePort: nil)
        XCTAssertThrowsError(try f.validate()) { error in
            XCTAssertEqual(error as? PortForward.ValidationError,
                           .missingRemoteForLocalOrRemote)
        }
    }

    func test_dynamic_withRemoteHost_throws() {
        let f = PortForward(kind: .dynamic, bindPort: 1080,
                            remoteHost: "h", remotePort: nil)
        XCTAssertThrowsError(try f.validate()) { error in
            XCTAssertEqual(error as? PortForward.ValidationError,
                           .unexpectedRemoteForDynamic)
        }
    }

    func test_collection_duplicateBindings_throws() {
        let f1 = PortForward(kind: .local, bindPort: 5432,
                             remoteHost: "a", remotePort: 5432)
        let f2 = PortForward(kind: .local, bindPort: 5432,
                             remoteHost: "b", remotePort: 5432)
        XCTAssertThrowsError(try PortForward.validateCollection([f1, f2])) { error in
            guard case .duplicateBinding(let k, let addr, let port) =
                    (error as? PortForward.ValidationError)
            else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(k, .local)
            XCTAssertEqual(addr, "localhost")
            XCTAssertEqual(port, 5432)
        }
    }

    func test_collection_differentBindAddressNotDuplicate() throws {
        let f1 = PortForward(kind: .local, bindAddress: nil,  bindPort: 5432,
                             remoteHost: "a", remotePort: 5432)
        let f2 = PortForward(kind: .local, bindAddress: "*",  bindPort: 5432,
                             remoteHost: "a", remotePort: 5432)
        XCTAssertNoThrow(try PortForward.validateCollection([f1, f2]))
    }
}
```

- [ ] **Step 2: Verify the tests reference an existing target**

The `SSHCommandBuilderTests` test target must include the new file. Run:

```bash
cd apps/macos && swift test --filter PortForwardValidationTests
```

Expected: tests run and pass (the new file is auto-discovered by SwiftPM under `Tests/SSHCommandBuilderTests/`).

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Tests/SSHCommandBuilderTests/PortForwardValidationTests.swift
git commit -m "test(macos): validation tests for PortForward"
```

---

### Task 3: Add `forwards` field to `Host`

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/Host.swift`

- [ ] **Step 1: Add the property**

Find the struct properties block (currently ends with `var jumpHostServerId: String?`) and add **after** it:

```swift
	/// Per-host port forwards. Empty for hosts that don't tunnel anything.
	/// Encoded as a regular array; legacy hosts.json files predating this
	/// field decode to `[]`.
	public var forwards: [PortForward]
```

- [ ] **Step 2: Extend the initializer**

In the `init(id:serverId:name:...)` signature, append the parameter (default `[]`):

```swift
	public init(id: UUID = UUID(), serverId: String? = nil,
	            name: String, hostname: String, port: Int = 22,
	            username: String, credential: CredentialSource,
	            createdAt: Date = Date(), updatedAt: Date = Date(),
	            credentialMaterialDirty: Bool = false,
	            jumpHostServerId: String? = nil,
	            forwards: [PortForward] = []) {
```

In the body, after the existing assignments add:

```swift
		self.forwards = forwards
```

- [ ] **Step 3: Extend `CodingKeys`**

Find the `enum CodingKeys` and add `forwards`:

```swift
	private enum CodingKeys: String, CodingKey {
		case id, serverId, name, hostname, port, username, credential
		case createdAt, updatedAt, credentialMaterialDirty
		case jumpHostServerId
		case forwards
	}
```

- [ ] **Step 4: Extend `init(from:)`**

At the bottom of the existing `init(from decoder:)` body (after `jumpHostServerId` decode), add:

```swift
		forwards = try c.decodeIfPresent([PortForward].self, forKey: .forwards) ?? []
```

- [ ] **Step 5: Verify host compiles**

```bash
cd apps/macos && swift build --target SSHCommandBuilder
```

Expected: clean build.

- [ ] **Step 6: Add a legacy-decode test**

In an existing test file (`apps/macos/Tests/SSHCommandBuilderTests/HostCodingTests.swift` if present, otherwise create it) add:

```swift
func test_legacyHostJSON_withoutForwards_decodesToEmpty() throws {
    let legacyJSON = """
    {
      "id": "\(UUID().uuidString)",
      "name": "Legacy",
      "hostname": "h.example.com",
      "port": 22,
      "username": "u",
      "credential": { "password": {} },
      "createdAt": 12345,
      "updatedAt": 12345
    }
    """.data(using: .utf8)!
    let h = try JSONDecoder.caterm.decode(Host.self, from: legacyJSON)
    XCTAssertEqual(h.forwards, [])
}
```

If `JSONDecoder.caterm` does not exist, use `JSONDecoder()` and adjust date strategy as needed to match the project's encoder.

- [ ] **Step 7: Run the test**

```bash
cd apps/macos && swift test --filter HostCodingTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/Host.swift apps/macos/Tests/SSHCommandBuilderTests/HostCodingTests.swift
git commit -m "feat(macos): add Host.forwards with legacy decode compat"
```

---

### Task 4: Helper — `PortForward.sshConfigLine()`

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/PortForward.swift`

- [ ] **Step 1: Write the failing test first**

Create `apps/macos/Tests/SSHCommandBuilderTests/PortForwardSnapshotTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

final class PortForwardSnapshotTests: XCTestCase {

    func test_local_noBindAddress_emitsBindPortOnly() throws {
        let f = PortForward(kind: .local, bindPort: 5432,
                            remoteHost: "db.internal", remotePort: 5432)
        XCTAssertEqual(try f.sshConfigLine(),
                       "LocalForward 5432 db.internal:5432")
    }

    func test_local_withBindAddress_emitsAddrColonPort() throws {
        let f = PortForward(kind: .local, bindAddress: "*", bindPort: 5432,
                            remoteHost: "db.internal", remotePort: 5432)
        XCTAssertEqual(try f.sshConfigLine(),
                       "LocalForward *:5432 db.internal:5432")
    }

    func test_remote_basic() throws {
        let f = PortForward(kind: .remote, bindPort: 9090,
                            remoteHost: "localhost", remotePort: 9090)
        XCTAssertEqual(try f.sshConfigLine(),
                       "RemoteForward 9090 localhost:9090")
    }

    func test_dynamic_basic() throws {
        let f = PortForward(kind: .dynamic, bindPort: 1080)
        XCTAssertEqual(try f.sshConfigLine(), "DynamicForward 1080")
    }

    func test_dynamic_withBindAddress() throws {
        let f = PortForward(kind: .dynamic, bindAddress: "127.0.0.1", bindPort: 1080)
        XCTAssertEqual(try f.sshConfigLine(),
                       "DynamicForward 127.0.0.1:1080")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd apps/macos && swift test --filter PortForwardSnapshotTests
```

Expected: FAIL with "value of type 'PortForward' has no member 'sshConfigLine'".

- [ ] **Step 3: Implement the helper**

In `PortForward.swift`, after `validateCollection`, add:

```swift
    /// Serializes this forward to one `ssh_config` line. Caller is responsible
    /// for prepending any indentation. Values that contain whitespace or
    /// control characters are encoded via `SSHConfigQuote.encode`.
    public func sshConfigLine() throws -> String {
        let bindPart: String
        if let addr = bindAddress, !addr.isEmpty {
            bindPart = "\(addr):\(bindPort)"
        } else {
            bindPart = String(bindPort)
        }
        switch kind {
        case .local:
            let target = "\(remoteHost ?? ""):\(remotePort ?? 0)"
            return "LocalForward \(try SSHConfigQuote.encode(bindPart)) \(try SSHConfigQuote.encode(target))"
        case .remote:
            let target = "\(remoteHost ?? ""):\(remotePort ?? 0)"
            return "RemoteForward \(try SSHConfigQuote.encode(bindPart)) \(try SSHConfigQuote.encode(target))"
        case .dynamic:
            return "DynamicForward \(try SSHConfigQuote.encode(bindPart))"
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/macos && swift test --filter PortForwardSnapshotTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/PortForward.swift apps/macos/Tests/SSHCommandBuilderTests/PortForwardSnapshotTests.swift
git commit -m "feat(macos): PortForward.sshConfigLine helper"
```

---

### Task 5: Emit forwards in `perHostOptions` (chain mode)

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`

- [ ] **Step 1: Write the failing chain-mode test**

Append to `apps/macos/Tests/SSHCommandBuilderTests/PortForwardSnapshotTests.swift`:

```swift
import XCTest
@testable import SSHCommandBuilder

extension PortForwardSnapshotTests {

    private func makeHost(forwards: [PortForward] = []) -> Host {
        Host(id: UUID(), name: "h", hostname: "h.example.com",
             port: 22, username: "u", credential: .password,
             forwards: forwards)
    }

    func test_chain_targetForwardsEmitted_inTargetBlock() throws {
        let target = makeHost(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432, required: true),
        ])
        let jump = makeHost()
        let sink = InMemoryConfigSink()
        let out = try SSHCommandBuilder.build(
            host: target,
            ancestors: [jump],
            configSink: sink,
            askpassPath: "/tmp/askpass",
            knownHostsCaterm: "/tmp/known_caterm",
            knownHostsUser: "/tmp/known_user"
        )
        let cfg = sink.lastWritten ?? ""
        // Target block must contain the forward.
        XCTAssertTrue(cfg.contains("LocalForward 5432 db:5432"))
        // ExitOnForwardFailure yes — all forwards required.
        XCTAssertTrue(cfg.contains("ExitOnForwardFailure yes"))
        // Jump block must NOT contain the forward.
        let jumpBlock = cfg.components(separatedBy: "\n\nHost caterm-h-").first ?? ""
        XCTAssertFalse(jumpBlock.contains("LocalForward"))
        _ = out
    }

    func test_chain_mixedRequiredAndOptional_noExitOnForwardFailure() throws {
        let target = makeHost(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432, required: true),
            PortForward(kind: .local, bindPort: 8080,
                        remoteHost: "localhost", remotePort: 8080, required: false),
        ])
        let sink = InMemoryConfigSink()
        _ = try SSHCommandBuilder.build(
            host: target, ancestors: [makeHost()],
            configSink: sink,
            askpassPath: "/tmp/a", knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
        )
        let cfg = sink.lastWritten ?? ""
        XCTAssertTrue(cfg.contains("LocalForward 5432 db:5432"))
        XCTAssertTrue(cfg.contains("LocalForward 8080 localhost:8080"))
        XCTAssertFalse(cfg.contains("ExitOnForwardFailure"))
    }

    func test_chain_emptyForwards_noExitOnForwardFailure() throws {
        let sink = InMemoryConfigSink()
        _ = try SSHCommandBuilder.build(
            host: makeHost(), ancestors: [makeHost()],
            configSink: sink,
            askpassPath: "/tmp/a", knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
        )
        let cfg = sink.lastWritten ?? ""
        XCTAssertFalse(cfg.contains("ExitOnForwardFailure"))
        XCTAssertFalse(cfg.contains("LocalForward"))
    }
}

final class InMemoryConfigSink: SSHConfigSink {
    var lastWritten: String?
    func write(_ content: String) throws -> URL {
        lastWritten = content
        return URL(fileURLWithPath: "/tmp/caterm-test-\(UUID().uuidString).cfg")
    }
}
```

If the test file already has an `InMemoryConfigSink` (check existing chain tests), reuse it instead of redefining.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd apps/macos && swift test --filter PortForwardSnapshotTests
```

Expected: chain tests FAIL (`LocalForward` not found in cfg).

- [ ] **Step 3: Modify `perHostOptions` to emit forward lines**

In `SSHCommandBuilder.swift`, locate `perHostOptions(for:isTarget:...)`. After the existing `BatchMode/agent` branch and **before** the final `return PerHostOptions(...)`, insert:

```swift
		// Forwards: target only. OpenSSH's ExitOnForwardFailure is a global
		// option; we enable it solely when every forward is required so
		// optional forwards don't take down the connection on bind failure.
		// (See spec §"Known Limitations" for the mixed-required-and-optional
		// remote-bind silent-failure caveat.)
		if isTarget, !host.forwards.isEmpty {
			var anyOptional = false
			for fwd in host.forwards {
				lines.append(try fwd.sshConfigLine())
				if !fwd.required { anyOptional = true }
			}
			if !anyOptional {
				lines.append("ExitOnForwardFailure yes")
			}
		}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/macos && swift test --filter PortForwardSnapshotTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift apps/macos/Tests/SSHCommandBuilderTests/PortForwardSnapshotTests.swift
git commit -m "feat(macos): emit port forwards in target host ssh_config block"
```

---

### Task 6: Emit forwards in direct-path `_build`

**Files:**
- Modify: `apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift`

- [ ] **Step 1: Write the failing direct-path test**

Append to `PortForwardSnapshotTests.swift`:

```swift
extension PortForwardSnapshotTests {

    func test_directPath_local_emittedAsDashOFlag() throws {
        let h = makeHost(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432, required: true),
        ])
        let out = SSHCommandBuilder.build(
            host: h, askpassPath: "/tmp/a",
            knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
        )
        XCTAssertTrue(out.command.contains("-o 'LocalForward=5432 db:5432'"))
        XCTAssertTrue(out.command.contains("-o ExitOnForwardFailure=yes"))
    }

    func test_directPath_mixedRequiredOptional_noExitFlag() throws {
        let h = makeHost(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432, required: true),
            PortForward(kind: .dynamic, bindPort: 1080, required: false),
        ])
        let out = SSHCommandBuilder.build(
            host: h, askpassPath: "/tmp/a",
            knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
        )
        XCTAssertTrue(out.command.contains("LocalForward=5432 db:5432"))
        XCTAssertTrue(out.command.contains("DynamicForward=1080"))
        XCTAssertFalse(out.command.contains("ExitOnForwardFailure"))
    }

    func test_directPath_emptyForwards_unchanged() throws {
        let h = makeHost()
        let out = SSHCommandBuilder.build(
            host: h, askpassPath: "/tmp/a",
            knownHostsCaterm: "/tmp/k1", knownHostsUser: "/tmp/k2"
        )
        XCTAssertFalse(out.command.contains("LocalForward"))
        XCTAssertFalse(out.command.contains("ExitOnForwardFailure"))
    }
}
```

- [ ] **Step 2: Run and verify they fail**

```bash
cd apps/macos && swift test --filter PortForwardSnapshotTests
```

Expected: direct-path tests FAIL.

- [ ] **Step 3: Modify `_build` to emit `-o` flags for forwards**

In `_build(host:askpassPath:...)`, locate the switch over `host.credential` that emits `args += [.raw("-o"), .quoted(...)]`. After that switch and **before** `args += [.raw("-p"), .raw(String(host.port))]`, insert:

```swift
		// Forwards (direct path). Mirrors `perHostOptions` for the chain
		// path. ExitOnForwardFailure only fires when every forward is required.
		if !host.forwards.isEmpty {
			var anyOptional = false
			for fwd in host.forwards {
				let bindPart: String
				if let addr = fwd.bindAddress, !addr.isEmpty {
					bindPart = "\(addr):\(fwd.bindPort)"
				} else {
					bindPart = String(fwd.bindPort)
				}
				let value: String
				switch fwd.kind {
				case .local:
					value = "LocalForward=\(bindPart) \(fwd.remoteHost ?? ""):\(fwd.remotePort ?? 0)"
				case .remote:
					value = "RemoteForward=\(bindPart) \(fwd.remoteHost ?? ""):\(fwd.remotePort ?? 0)"
				case .dynamic:
					value = "DynamicForward=\(bindPart)"
				}
				args += [.raw("-o"), .quoted(value)]
				if !fwd.required { anyOptional = true }
			}
			if !anyOptional {
				args += [.raw("-o"), .raw("ExitOnForwardFailure=yes")]
			}
		}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/macos && swift test --filter PortForwardSnapshotTests
```

Expected: PASS.

- [ ] **Step 5: Run the full SSHCommandBuilder test suite to check for regressions**

```bash
cd apps/macos && swift test --filter SSHCommandBuilderTests
```

Expected: ALL pass — no existing tests broken by the additions.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift apps/macos/Tests/SSHCommandBuilderTests/PortForwardSnapshotTests.swift
git commit -m "feat(macos): emit port forwards as -o flags in direct ssh path"
```

---

### Task 7: Add `FailureKind.portForwardBindFailed` case

**Files:**
- Modify: `apps/macos/Sources/SessionStore/FailureKind.swift`

- [ ] **Step 1: Add the new case**

In `FailureKind`, after `case networkUnreachable(NetworkErrorReason)` and **before** `public static func classify(...)`, add:

```swift
	/// A required port forward could not bind locally during preflight.
	/// Carries the offending forward + the typed reason for UI copy.
	/// Only thrown by `Preflight`; never synthesized from ssh process exit.
	case portForwardBindFailed(forward: PortForward, reason: PortForward.BindFailureReason)
```

You'll also need to `import SSHCommandBuilder` at the top of `FailureKind.swift` for `PortForward`.

- [ ] **Step 2: Verify SessionStore package compiles**

```bash
cd apps/macos && swift build --target SessionStore
```

Expected: clean.

If `FailureKind` is `Equatable` (existing) and `PortForward` is `Hashable` (Task 1 made it `Hashable` which entails `Equatable`), the synthesis still works. Verify there are no compile errors.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/SessionStore/FailureKind.swift
git commit -m "feat(macos): add portForwardBindFailed FailureKind case"
```

---

### Task 8: Handle new `FailureKind` case in three exhaustive switches

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift`
- Modify: `apps/macos/Sources/SessionStore/ReconnectScheduler.swift`
- Modify: `apps/macos/Sources/Caterm/Views/FailurePresentation.swift`

- [ ] **Step 1: `TerminalContainerView.shouldShowFailureOverlay`**

Locate the function (around line 80). Find:

```swift
		case .authOrSetupFail, .networkUnreachable: return true
```

Replace with:

```swift
		case .authOrSetupFail, .networkUnreachable, .portForwardBindFailed: return true
```

- [ ] **Step 2: `ReconnectScheduler.shouldReconnect`**

Locate the function (around line 19). Find:

```swift
		case .authOrSetupFail, .cleanExit, .networkUnreachable: return false
```

Replace with:

```swift
		case .authOrSetupFail, .cleanExit, .networkUnreachable, .portForwardBindFailed: return false
```

- [ ] **Step 3: `FailurePresentation.text(for:)` — add new case**

Locate the switch that ends with `case .cleanExit, .connectionDropped:` (around line 48). **Before** that final case, insert:

```swift
		case let .portForwardBindFailed(forward, reason):
			let portDesc: String
			if let addr = forward.bindAddress, !addr.isEmpty {
				portDesc = "\(addr):\(forward.bindPort)"
			} else {
				portDesc = String(forward.bindPort)
			}
			let reasonText: String
			switch reason {
			case .alreadyInUse:     reasonText = "is already in use on your Mac"
			case .permissionDenied: reasonText = "requires elevated privileges to bind"
			case .unknown:          reasonText = "could not be bound"
			}
			return "Port \(portDesc) \(reasonText). Edit the host to change the forward or pick a free port."
```

- [ ] **Step 4: Compile the full project**

```bash
cd apps/macos && swift build
```

Expected: no compile errors. Any module that still has a non-exhaustive switch over `FailureKind` will fail loudly here — if a fourth switch surfaces, treat it like the others.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/TerminalContainerView.swift apps/macos/Sources/SessionStore/ReconnectScheduler.swift apps/macos/Sources/Caterm/Views/FailurePresentation.swift
git commit -m "feat(macos): wire portForwardBindFailed through overlay/reconnect/copy"
```

---

### Task 9: Extend `PreflightProbing` protocol with `probeLocalBind`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/PreflightProbing.swift`

- [ ] **Step 1: Add the new outcome type and protocol method**

Replace the contents of `PreflightProbing.swift` with:

```swift
import Foundation
import SSHCommandBuilder

/// Outcome of a TCP preflight probe. Independent of NWError so callers
/// don't need to import Network.framework.
public enum PreflightOutcome: Equatable {
	case ok
	case failed(NetworkErrorReason)
}

/// Outcome of a local-bind probe (used for port-forward conflict detection).
public enum PortBindOutcome: Equatable {
	case available
	case unavailable(PortForward.BindFailureReason)
}

/// Abstraction over `Preflight.probe` / `Preflight.probeLocalBind`.
/// `SessionStore` consumes a value of this protocol so tests can inject a
/// fake without spinning up real `NWConnection` / `NWListener`s.
public protocol PreflightProbing: Sendable {
	func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome
	func probeLocalBind(address: String, port: UInt16) async -> PortBindOutcome
}
```

- [ ] **Step 2: Verify package compiles** (it will fail in `Preflight.swift` — fixed in Task 10)

```bash
cd apps/macos && swift build --target SessionStore
```

Expected: error in `Preflight.swift` — "type `Preflight` does not conform to protocol `PreflightProbing`". This is intentional; the next task adds the implementation.

- [ ] **Step 3: Commit (with the partial state)**

Don't commit yet — chain with Task 10 so we don't push a broken state. Skip this step and go straight to Task 10.

---

### Task 10: Implement `Preflight.probeLocalBind`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/Preflight.swift`

- [ ] **Step 1: Write the failing test**

Create or extend `apps/macos/Tests/SessionStoreTests/PreflightTests.swift`:

```swift
import XCTest
import Network
import SSHCommandBuilder
@testable import SessionStore

final class PreflightLocalBindTests: XCTestCase {

    func test_freePort_returnsAvailable() async throws {
        // Bind a real ephemeral port to find one that's known-free at this instant,
        // then release it and probe the same port. There's a small race window;
        // sufficient for a smoke-level test.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.start(queue: .global())
        // Wait for the listener to acquire its port.
        var port: UInt16 = 0
        for _ in 0..<50 {
            if let p = listener.port?.rawValue { port = p; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(port, 0)
        listener.cancel()
        // Brief wait for the OS to release the port.
        try await Task.sleep(nanoseconds: 50_000_000)

        let outcome = await Preflight().probeLocalBind(address: "127.0.0.1", port: port)
        XCTAssertEqual(outcome, .available)
    }

    func test_occupiedPort_returnsAlreadyInUse() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.start(queue: .global())
        var port: UInt16 = 0
        for _ in 0..<50 {
            if let p = listener.port?.rawValue { port = p; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(port, 0)
        defer { listener.cancel() }

        let outcome = await Preflight().probeLocalBind(address: "127.0.0.1", port: port)
        XCTAssertEqual(outcome, .unavailable(.alreadyInUse))
    }
}
```

- [ ] **Step 2: Verify test fails to compile**

```bash
cd apps/macos && swift test --filter PreflightLocalBindTests
```

Expected: compile error — `Preflight` lacks `probeLocalBind`.

- [ ] **Step 3: Implement `probeLocalBind`**

In `Preflight.swift`, add the import for `SSHCommandBuilder` at the top:

```swift
import Foundation
import Network
import SSHCommandBuilder
```

Inside the `Preflight` struct, after the existing `probe(host:port:timeout:)` method, add:

```swift
	public func probeLocalBind(address: String, port: UInt16) async -> PortBindOutcome {
		guard let nwPort = NWEndpoint.Port(rawValue: port) else {
			return .unavailable(.unknown)
		}
		let parameters: NWParameters = .tcp
		// Bind to the specific address: pass via `requiredLocalEndpoint`.
		if !address.isEmpty, address != "*" {
			parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
				host: NWEndpoint.Host(address), port: nwPort
			)
		}
		do {
			let listener = try NWListener(using: parameters, on: nwPort)
			return await withCheckedContinuation { continuation in
				let resumed = ResumedFlag()
				listener.stateUpdateHandler = { state in
					switch state {
					case .ready:
						if resumed.markIfFirst() {
							listener.cancel()
							continuation.resume(returning: .available)
						}
					case .failed(let error):
						if resumed.markIfFirst() {
							listener.cancel()
							continuation.resume(returning:
								.unavailable(Self.mapBindError(error)))
						}
					case .cancelled, .setup, .waiting:
						break
					@unknown default:
						break
					}
				}
				listener.start(queue: .global(qos: .userInitiated))
			}
		} catch {
			return .unavailable(Self.mapBindError(error))
		}
	}

	static func mapBindError(_ error: Error) -> PortForward.BindFailureReason {
		guard let nw = error as? NWError else { return .unknown }
		switch nw {
		case .posix(let code):
			switch code {
			case .EADDRINUSE: return .alreadyInUse
			case .EACCES:     return .permissionDenied
			default:          return .unknown
			}
		default:
			return .unknown
		}
	}
```

- [ ] **Step 4: Run tests**

```bash
cd apps/macos && swift test --filter PreflightLocalBindTests
```

Expected: PASS (both cases).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SessionStore/PreflightProbing.swift apps/macos/Sources/SessionStore/Preflight.swift apps/macos/Tests/SessionStoreTests/PreflightTests.swift
git commit -m "feat(macos): PreflightProbing.probeLocalBind for forward conflict detection"
```

---

### Task 11: `SessionStore.skippedForwardNotices` published state

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`

- [ ] **Step 1: Add the data type and published field**

Inside the `SessionStore` class (before the existing `@Published` fields if grouped, otherwise alongside them):

```swift
	public struct SkippedForwardNotice: Identifiable, Equatable, Sendable {
		public let id: UUID
		public let hostId: UUID
		public let forward: PortForward
		public let reason: PortForward.BindFailureReason
		public let timestamp: Date

		public init(hostId: UUID, forward: PortForward,
		            reason: PortForward.BindFailureReason,
		            id: UUID = UUID(), timestamp: Date = Date()) {
			self.id = id
			self.hostId = hostId
			self.forward = forward
			self.reason = reason
			self.timestamp = timestamp
		}
	}

	@Published public private(set) var skippedForwardNotices: [SkippedForwardNotice] = []

	public func clearSkippedForwardNotices(forHost: UUID? = nil) {
		if let target = forHost {
			skippedForwardNotices.removeAll { $0.hostId == target }
		} else {
			skippedForwardNotices.removeAll()
		}
	}
```

Add `import SSHCommandBuilder` at the top if not already imported.

- [ ] **Step 2: Verify compile**

```bash
cd apps/macos && swift build --target SessionStore
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift
git commit -m "feat(macos): SessionStore.skippedForwardNotices published state"
```

---

### Task 12: Wire forward preflight into `startConnection`

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`
- Modify: `apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift`

- [ ] **Step 1: Read the existing `startConnection`**

Find `public func startConnection(tabId: UUID)` (line ~318). Identify where the existing TCP preflight runs — the `failConnection` and Connected-state transition points are the anchors. The new forward probe runs **after** the existing TCP preflight resolves successfully and **before** the ssh subprocess spawn.

- [ ] **Step 2: Add a helper method to perform the forward probe**

In `SessionStore`, near the existing connection helpers, add:

```swift
	/// Returns `nil` on success. Returns a `FailureKind` to abort the
	/// connection with on the first **required** forward whose local bind
	/// fails. Optional forwards that fail are appended to
	/// `skippedForwardNotices` and do not abort.
	private func probeForwards(_ forwards: [PortForward],
	                            host: SSHHost) async -> FailureKind? {
		for forward in forwards where forward.kind != .remote {
			let addr = forward.bindAddress ?? "127.0.0.1"
			guard let nwPort = UInt16(exactly: forward.bindPort) else { continue }
			let outcome = await preflight.probeLocalBind(address: addr, port: nwPort)
			guard case .unavailable(let reason) = outcome else { continue }
			if forward.required {
				return .portForwardBindFailed(forward: forward, reason: reason)
			} else {
				await MainActor.run {
					self.skippedForwardNotices.append(
						SkippedForwardNotice(hostId: host.id,
						                     forward: forward, reason: reason)
					)
				}
			}
		}
		return nil
	}
```

If `SessionStore` is already `@MainActor`-isolated (check the class declaration), drop the `MainActor.run` wrapper.

- [ ] **Step 3: Call the helper in `startConnection`**

Locate the point in `startConnection` (or its async work block) **immediately after** the TCP preflight succeeds — typically just before the call that constructs the `SSHCommandBuilder` output / spawns the surface. Insert:

```swift
		// Clear any stale notices from a prior attempt before re-populating.
		clearSkippedForwardNotices(forHost: host.id)
		if let failure = await probeForwards(host.forwards, host: host) {
			failConnection(tabId: tabId, kind: failure)
			return
		}
```

(Adjust `failConnection(tabId:kind:)` to whatever the existing failure-routing API on `SessionStore` is — check by reading around the existing `.networkUnreachable` failure path inside `startConnection`; mirror that.)

- [ ] **Step 4: Add tests**

In `SessionStoreTests.swift`, add:

```swift
final class PortForwardPreflightTests: XCTestCase {

    final class FakePreflight: PreflightProbing {
        var tcpOutcome: PreflightOutcome = .ok
        var bindOutcomes: [String: PortBindOutcome] = [:]
        func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome { tcpOutcome }
        func probeLocalBind(address: String, port: UInt16) async -> PortBindOutcome {
            bindOutcomes["\(address):\(port)"] ?? .available
        }
    }

    @MainActor
    func test_requiredForwardOccupied_failsConnection() async throws {
        let fake = FakePreflight()
        fake.bindOutcomes["127.0.0.1:5432"] = .unavailable(.alreadyInUse)
        let store = try await makeStoreFixture(preflight: fake)
        let host = try await store.addHostFixture(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432, required: true),
        ])
        let tabId = store.openTab(for: host.id)
        await store.startConnectionAndAwait(tabId: tabId)
        guard case .failed(.portForwardBindFailed) = store.state(for: tabId) else {
            return XCTFail("expected failed(.portForwardBindFailed), got \(store.state(for: tabId))")
        }
    }

    @MainActor
    func test_optionalForwardOccupied_connectsAndPublishesNotice() async throws {
        let fake = FakePreflight()
        fake.bindOutcomes["127.0.0.1:1080"] = .unavailable(.alreadyInUse)
        let store = try await makeStoreFixture(preflight: fake)
        let host = try await store.addHostFixture(forwards: [
            PortForward(kind: .dynamic, bindPort: 1080, required: false),
        ])
        let tabId = store.openTab(for: host.id)
        await store.startConnectionAndAwait(tabId: tabId)
        XCTAssertEqual(store.skippedForwardNotices.count, 1)
        XCTAssertEqual(store.skippedForwardNotices.first?.forward.bindPort, 1080)
    }

    @MainActor
    func test_remoteForward_notProbed() async throws {
        let fake = FakePreflight()
        // Configure bind outcome that, if probed, would abort the connection.
        fake.bindOutcomes["127.0.0.1:9090"] = .unavailable(.alreadyInUse)
        let store = try await makeStoreFixture(preflight: fake)
        let host = try await store.addHostFixture(forwards: [
            PortForward(kind: .remote, bindPort: 9090,
                        remoteHost: "localhost", remotePort: 9090, required: true),
        ])
        let tabId = store.openTab(for: host.id)
        await store.startConnectionAndAwait(tabId: tabId)
        // No failure from preflight — remote forwards skip the probe.
        XCTAssertNotEqual(store.state(for: tabId), .failed(.portForwardBindFailed(
            forward: host.forwards[0], reason: .alreadyInUse
        )))
    }
}
```

`makeStoreFixture(preflight:)`, `addHostFixture(forwards:)`, `openTab(for:)`, `startConnectionAndAwait(tabId:)`, and `state(for:)` are test helpers — use whatever helpers the existing `SessionStoreTests` already defines for fixture setup. If they don't exist, write them in a shared test helpers file.

- [ ] **Step 5: Run tests**

```bash
cd apps/macos && swift test --filter SessionStoreTests
```

Expected: new tests PASS, no existing regressions.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift
git commit -m "feat(macos): probe local bind ports before ssh spawn"
```

---

### Task 13: Differentiated `closeTab` teardown for hosts with forwards

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`
- Modify: `apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SessionStoreTests.swift`:

```swift
final class CloseTabTeardownTests: XCTestCase {

    final class RecordingTearDowner: ControlMasterTearDowning {
        var tornDown: [UUID] = []
        var scheduledTearDownAll = 0
        func register(hostId: UUID, destination: String) {}
        func isAlive(hostId: UUID) async -> Bool { false }
        func tearDown(hostId: UUID) async { tornDown.append(hostId) }
        func tearDownAll() async { scheduledTearDownAll += 1 }
    }

    @MainActor
    func test_closeLastTab_hostWithForwards_tearsDownImmediately() async throws {
        let rec = RecordingTearDowner()
        let store = try await makeStoreFixture(controlMaster: rec, teardownGraceSeconds: 999)
        let host = try await store.addHostFixture(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432),
        ])
        let tabId = store.openTab(for: host.id)
        store.closeTab(tabId: tabId)
        // Immediate teardown (no 999 s grace).
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rec.tornDown, [host.id])
    }

    @MainActor
    func test_closeLastTab_hostWithoutForwards_useGrace() async throws {
        let rec = RecordingTearDowner()
        let store = try await makeStoreFixture(controlMaster: rec, teardownGraceSeconds: 0.05)
        let host = try await store.addHostFixture(forwards: [])
        let tabId = store.openTab(for: host.id)
        store.closeTab(tabId: tabId)
        // Before grace elapses: nothing.
        XCTAssertEqual(rec.tornDown, [])
        try await Task.sleep(nanoseconds: 100_000_000)
        // After grace: tear down.
        XCTAssertEqual(rec.tornDown, [host.id])
    }

    @MainActor
    func test_closeOneOfMultipleTabs_sameHost_doesNotTeardown() async throws {
        let rec = RecordingTearDowner()
        let store = try await makeStoreFixture(controlMaster: rec, teardownGraceSeconds: 0.05)
        let host = try await store.addHostFixture(forwards: [
            PortForward(kind: .local, bindPort: 5432,
                        remoteHost: "db", remotePort: 5432),
        ])
        let tab1 = store.openTab(for: host.id)
        let tab2 = store.openTab(for: host.id)
        store.closeTab(tabId: tab1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rec.tornDown, [])
        store.closeTab(tabId: tab2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rec.tornDown, [host.id])
    }
}
```

If `ControlMasterTearDowning` protocol's exact method set differs from the stub above, copy the real signatures from `SessionStore.swift:21`.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd apps/macos && swift test --filter CloseTabTeardownTests
```

Expected: FAIL on the "tearsDownImmediately" assertion (host with forwards currently goes through the same 30 s scheduleTeardown).

- [ ] **Step 3: Modify `closeTab`**

Locate `public func closeTab(tabId: UUID)` (line ~251). Find the section that, after removing the tab, determines whether to schedule a teardown. The existing check is along the lines of:

```swift
let isLast = !tabs.contains(where: { $0.host.id == hostId })
if isLast {
    scheduleTeardown(hostId: hostId)
}
```

Replace with:

```swift
let isLast = !tabs.contains(where: { $0.host.id == hostId })
let hostHadForwards: Bool = {
    if let host = hosts.first(where: { $0.id == hostId }) {
        return !host.forwards.isEmpty
    }
    return false
}()
if isLast {
    if hostHadForwards {
        // Forwards leaving listening sockets bound is observable to the user.
        // Skip the grace; tear down the master immediately.
        if let manager = controlMasterManager {
            Task { await manager.tearDown(hostId: hostId) }
        }
    } else {
        scheduleTeardown(hostId: hostId)
    }
}
```

Match the surrounding variable names (`hostId`, `tab.host.id`) to whatever the existing code uses — the only structural change is the new branch on `hostHadForwards`.

- [ ] **Step 4: Run tests**

```bash
cd apps/macos && swift test --filter CloseTabTeardownTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift
git commit -m "feat(macos): immediate ControlMaster teardown for hosts with forwards"
```

---

### Task 14: Render skipped-forward `Banner` in `MainWindow`

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/MainWindow.swift`

- [ ] **Step 1: Add the banner above the existing banner stack**

Locate the top of `MainWindow.body` where `DiagnosticBanner` and the new-surface `Banner` are rendered. **Before** the `if !bannerState.diagnosticMessages.isEmpty` check, add:

```swift
				if !skippedForwardBannerText.isEmpty {
					Banner(
						text: skippedForwardBannerText,
						onDismiss: { store.clearSkippedForwardNotices(forHost: activeHost?.id) }
					)
				}
```

- [ ] **Step 2: Add the derived text helper**

Inside `MainWindow`, near the other private helpers:

```swift
	private var skippedForwardBannerText: String {
		let notices = store.skippedForwardNotices.filter {
			activeHost.map($0.hostId == $0.hostId == .some(activeHost?.id ?? UUID())) ?? false
		}
		// Filter exactly to current host:
		let scoped = store.skippedForwardNotices.filter {
			$0.hostId == activeHost?.id
		}
		guard !scoped.isEmpty else { return "" }
		let descs = scoped.map { n -> String in
			let bind: String
			if let addr = n.forward.bindAddress, !addr.isEmpty {
				bind = "\(addr):\(n.forward.bindPort)"
			} else {
				bind = String(n.forward.bindPort)
			}
			return "\(n.forward.kind.rawValue) \(bind) (\(n.reason.rawValue))"
		}
		return "Skipped optional port forward(s): " + descs.joined(separator: ", ")
		_ = notices  // suppress unused
	}
```

Remove the `_ = notices` and the unused first declaration — the helper should be one clean filter scoped to `activeHost?.id`:

```swift
	private var skippedForwardBannerText: String {
		let scoped = store.skippedForwardNotices.filter {
			$0.hostId == activeHost?.id
		}
		guard !scoped.isEmpty else { return "" }
		let descs = scoped.map { n -> String in
			let bind: String
			if let addr = n.forward.bindAddress, !addr.isEmpty {
				bind = "\(addr):\(n.forward.bindPort)"
			} else {
				bind = String(n.forward.bindPort)
			}
			return "\(n.forward.kind.rawValue) \(bind) (\(n.reason.rawValue))"
		}
		return "Skipped optional port forward(s): " + descs.joined(separator: ", ")
	}
```

- [ ] **Step 3: Compile**

```bash
cd apps/macos && swift build
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/MainWindow.swift
git commit -m "feat(macos): show banner when optional port forwards were skipped"
```

---

### Task 15: Carry `forwards` through `RemoteHost` DTOs

**Files:**
- Modify: `apps/macos/Sources/ServerSyncClient/RemoteHost.swift`

- [ ] **Step 1: Add field to `RemoteHost`**

In `RemoteHost` struct, after `jumpHostServerId: String?` add:

```swift
    public let forwards: [PortForward]
```

Add `import SSHCommandBuilder` at the top.

Extend the `init` to accept and store it, defaulting to `[]`:

```swift
    public init(id: String, name: String, hostname: String, port: Int,
                username: String, authType: String, createdAt: Date, updatedAt: Date,
                jumpHostServerId: String? = nil,
                forwards: [PortForward] = []) {
        self.id = id
        // ...
        self.jumpHostServerId = jumpHostServerId
        self.forwards = forwards
    }
```

- [ ] **Step 2: Add field to `RemoteHostCreateInput` and `RemoteHostUpdateInput`**

```swift
public struct RemoteHostCreateInput: Codable {
    // ...existing fields...
    public let jumpHostServerId: String?
    public let forwards: [PortForward]

    public init(name: String, hostname: String, port: Int, username: String,
                jumpHostServerId: String? = nil,
                forwards: [PortForward] = []) {
        // ...existing...
        self.forwards = forwards
    }
}

public struct RemoteHostUpdateInput: Codable {
    // ...existing fields...
    public let jumpHostServerId: String?
    public let forwards: [PortForward]?

    public init(id: String, name: String? = nil, hostname: String? = nil,
                port: Int? = nil, username: String? = nil,
                jumpHostServerId: String? = nil,
                forwards: [PortForward]? = nil) {
        // ...existing...
        self.forwards = forwards
    }
}
```

`RemoteHostUpdateInput.forwards` is `[PortForward]?` so callers that aren't editing forwards omit the field entirely (existing optional-field pattern of `RemoteHostUpdateInput`).

- [ ] **Step 3: Verify package compiles**

```bash
cd apps/macos && swift build --target ServerSyncClient
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Sources/ServerSyncClient/RemoteHost.swift
git commit -m "feat(macos): carry forwards on RemoteHost DTOs"
```

---

### Task 16: Push & pull `forwards` in `CKRecordHostMapping`

**Files:**
- Modify: `apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`
- Modify: `apps/macos/Tests/CloudKitSyncClientTests/...`

- [ ] **Step 1: Add the field constant**

In the `Field` namespace at the top of `CKRecordHostMapping`, add:

```swift
		static let forwards = "forwards"
```

- [ ] **Step 2: Update `makeRecord` (create path)**

After the existing `jumpHostServerId` assignment, add:

```swift
		// `forwards` is never present on create-from-input today (UI doesn't
		// expose it on the create path), but we serialize for future-proofing.
		rec[Field.forwards] = (try? jsonEncoded(input.forwards)) ?? "[]" as CKRecordValue
```

Add a helper at the bottom of the file (file-private):

```swift
private func jsonEncoded(_ forwards: [PortForward]) throws -> CKRecordValue {
	let data = try JSONEncoder().encode(forwards)
	return (String(data: data, encoding: .utf8) ?? "[]") as CKRecordValue
}
```

- [ ] **Step 3: Update `applyMetadata(into:from:)` (update path)**

After the existing `jumpHostServerId` block, add:

```swift
		existing[Field.forwards] = (try? jsonEncoded(host.forwards)) ?? "[]" as CKRecordValue
		// `metadataUpdatedAt` was already advanced above to host.updatedAt;
		// callers (HostSyncStore) MUST bump host.updatedAt on any forwards
		// mutation, otherwise this push will not be considered newer by
		// other devices' LWW.
```

- [ ] **Step 4: Update the pull path (decode → `RemoteHost`)**

Locate the decode site around line 113 (`let updatedAt: Date = ...`). After the existing `jumpHostServerId` decode (the constructor call that builds `RemoteHost`), pull `forwards` from the record:

```swift
		let forwardsJSON = (rec[Field.forwards] as? String) ?? "[]"
		let decoded: [PortForward] = {
			guard let data = forwardsJSON.data(using: .utf8) else { return [] }
			do {
				return try JSONDecoder().decode([PortForward].self, from: data)
			} catch {
				// Corrupt JSON should NEVER fail the whole sync — log and
				// degrade to empty forwards.
				NSLog("[CKRecordHostMapping] forwards JSON decode failed for record \(rec.recordID.recordName): \(error)")
				return []
			}
		}()
```

Then add `forwards: decoded` to the `RemoteHost(...)` constructor invocation.

- [ ] **Step 5: Add tests**

Locate `CloudKitSyncClientTests` and add:

```swift
final class CKRecordHostMappingForwardsTests: XCTestCase {

    func test_makeRecord_writesForwardsJsonAndMetadataUpdatedAt() throws {
        let input = RemoteHostCreateInput(
            name: "h", hostname: "h.example", port: 22, username: "u",
            forwards: [PortForward(kind: .local, bindPort: 5432,
                                    remoteHost: "db", remotePort: 5432)]
        )
        let rec = CKRecordHostMapping.makeRecord(
            recordName: "rec",
            zoneID: CKRecordZone.ID(zoneName: "z"),
            input: input
        )
        let json = rec["forwards"] as? String ?? ""
        XCTAssertTrue(json.contains("\"bindPort\":5432"))
        XCTAssertNotNil(rec["metadataUpdatedAt"] as? Date)
    }

    func test_applyMetadata_writesForwardsAndAdvancesMetadataUpdatedAt() throws {
        let rec = CKRecord(recordType: "Host",
                           recordID: .init(recordName: "rec",
                                           zoneID: .init(zoneName: "z")))
        let original = Date(timeIntervalSince1970: 1000)
        rec["metadataUpdatedAt"] = original as CKRecordValue
        let host = SSHHost(name: "h", hostname: "h.example", port: 22,
                            username: "u", credential: .password,
                            updatedAt: Date(timeIntervalSince1970: 2000),
                            forwards: [
                                PortForward(kind: .dynamic, bindPort: 1080),
                            ])
        CKRecordHostMapping.applyMetadata(into: rec, from: host)
        let json = rec["forwards"] as? String ?? ""
        XCTAssertTrue(json.contains("\"kind\":\"dynamic\""))
        XCTAssertEqual((rec["metadataUpdatedAt"] as? Date)?.timeIntervalSince1970, 2000)
    }

    func test_pull_absentForwards_decodesEmpty() throws {
        let rec = CKRecord(recordType: "Host",
                           recordID: .init(recordName: "rec",
                                           zoneID: .init(zoneName: "z")))
        rec["name"] = "h" as CKRecordValue
        rec["hostname"] = "h.example" as CKRecordValue
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        rec["authType"] = "key" as CKRecordValue
        rec["metadataUpdatedAt"] = Date() as CKRecordValue
        let result = try CKRecordHostMapping.decodeRemoteHost(rec)  // or matching API
        XCTAssertEqual(result.host.forwards, [])
    }

    func test_pull_corruptForwardsJson_degradesToEmpty() throws {
        let rec = CKRecord(recordType: "Host",
                           recordID: .init(recordName: "rec",
                                           zoneID: .init(zoneName: "z")))
        rec["name"] = "h" as CKRecordValue
        rec["hostname"] = "h.example" as CKRecordValue
        rec["port"] = 22 as CKRecordValue
        rec["username"] = "u" as CKRecordValue
        rec["authType"] = "key" as CKRecordValue
        rec["metadataUpdatedAt"] = Date() as CKRecordValue
        rec["forwards"] = "{not valid json}" as CKRecordValue
        let result = try CKRecordHostMapping.decodeRemoteHost(rec)
        XCTAssertEqual(result.host.forwards, [])
    }
}
```

The exact name of the decode entry (`decodeRemoteHost`) and its return type — match what `CKRecordHostMapping.swift` currently exposes (re-read around line 105 if unsure).

- [ ] **Step 6: Run tests**

```bash
cd apps/macos && swift test --filter CKRecordHostMappingForwardsTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift apps/macos/Tests/CloudKitSyncClientTests/
git commit -m "feat(macos): push/pull forwards in CloudKit Host record"
```

---

### Task 17: Include `forwards` in reconciler diff

**Files:**
- Modify: `apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift`

- [ ] **Step 1: Find the diff check**

Locate the function that determines `.updateLocal` operations by comparing fields between a local `Host` and a `RemoteHost`. The existing check looks like:

```swift
if local.name != remote.name ||
   local.hostname != remote.hostname ||
   local.port != remote.port ||
   local.username != remote.username ||
   local.jumpHostServerId != remote.jumpHostServerId
{
    ops.append(.updateLocal(localHostId: local.id, remote: remote))
}
```

(Adjust to the actual current code.)

- [ ] **Step 2: Add `forwards` to the comparison**

```swift
if local.name != remote.name ||
   local.hostname != remote.hostname ||
   local.port != remote.port ||
   local.username != remote.username ||
   local.jumpHostServerId != remote.jumpHostServerId ||
   local.forwards != remote.forwards
{
    ops.append(.updateLocal(localHostId: local.id, remote: remote))
}
```

The symmetric `updateRemote` direction must also fire when local forwards diverge — find that path and apply the same `forwards != ` addition.

- [ ] **Step 3: Add a reconciler test**

In `HostSyncStoreTests.swift`:

```swift
func test_reconciler_forwardsDifferenceCausesUpdateLocal() {
    let local = SSHHost(name: "h", hostname: "h.example", port: 22,
                        username: "u", credential: .password,
                        serverId: "remote-1",
                        updatedAt: Date(timeIntervalSince1970: 1000),
                        forwards: [])
    let remote = RemoteHost(id: "remote-1", name: "h", hostname: "h.example",
                            port: 22, username: "u", authType: "key",
                            createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: 2000),
                            forwards: [
                                PortForward(kind: .local, bindPort: 5432,
                                             remoteHost: "db", remotePort: 5432),
                            ])
    let ops = HostSyncReconciler.diff(local: [local], remote: [remote])
    XCTAssertTrue(ops.contains(where: {
        if case .updateLocal(let id, _) = $0, id == local.id { return true }
        return false
    }))
}
```

- [ ] **Step 4: Run tests**

```bash
cd apps/macos && swift test --filter HostSyncStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Sources/HostSyncStore/HostSyncReconciler.swift apps/macos/Tests/HostSyncStoreTests/
git commit -m "feat(macos): reconciler diff includes forwards"
```

---

### Task 18: `applyRemoteMetadata` and `addRemoteHost` carry forwards

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`
- Modify: `apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
final class RemoteForwardsApplyTests: XCTestCase {

    @MainActor
    func test_applyRemoteMetadata_copiesForwards() async throws {
        let store = try await makeStoreFixture()
        let host = try await store.addHostFixture(forwards: [])
        let remote = RemoteHost(
            id: "rid", name: host.name, hostname: host.hostname,
            port: host.port, username: host.username, authType: "key",
            createdAt: host.createdAt,
            updatedAt: Date(),
            forwards: [
                PortForward(kind: .local, bindPort: 5432,
                             remoteHost: "db", remotePort: 5432),
            ]
        )
        try store.applyRemoteMetadata(localHostId: host.id, remote: remote)
        XCTAssertEqual(store.hosts.first(where: { $0.id == host.id })?.forwards.count, 1)
    }

    @MainActor
    func test_addRemoteHost_carriesForwards() async throws {
        let store = try await makeStoreFixture()
        let remote = RemoteHost(
            id: "rid", name: "h", hostname: "h.example", port: 22,
            username: "u", authType: "key",
            createdAt: Date(), updatedAt: Date(),
            forwards: [PortForward(kind: .dynamic, bindPort: 1080)]
        )
        try store.addRemoteHost(remote)
        let saved = store.hosts.first(where: { $0.serverId == "rid" })
        XCTAssertEqual(saved?.forwards.first?.kind, .dynamic)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd apps/macos && swift test --filter RemoteForwardsApplyTests
```

Expected: FAIL — current `applyRemoteMetadata` ignores `forwards`.

- [ ] **Step 3: Modify `applyRemoteMetadata` (line ~529)**

Inside the function, after the existing field-copy block:

```swift
        hosts[idx].forwards = remote.forwards
```

- [ ] **Step 4: Modify `addRemoteHost` (line ~543)**

In the `SSHHost(...)` constructor call, add a final argument:

```swift
            jumpHostServerId: remote.jumpHostServerId,
            forwards: remote.forwards
```

- [ ] **Step 5: Run tests**

```bash
cd apps/macos && swift test --filter RemoteForwardsApplyTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Sources/SessionStore/SessionStore.swift apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift
git commit -m "feat(macos): apply remote forwards through SessionStore"
```

---

### Task 19: `updatedAt` bump when forwards mutate locally

**Files:**
- Modify: `apps/macos/Sources/SessionStore/SessionStore.swift`
- Modify: `apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift`

- [ ] **Step 1: Verify existing `updateHost` already bumps `updatedAt`**

Look at `updateHost(_:)` near line 163. The existing line `updated.updatedAt = Date()` means that hosts edited through `updateHost` already get a fresh timestamp. **If forwards are edited via `updateHost`, no further change is needed.**

Confirm this by reading the function body. If it doesn't bump `updatedAt`, add `updated.updatedAt = Date()` before persist.

- [ ] **Step 2: Add a test asserting strict-monotonic `updatedAt` after a forwards edit**

In `SessionStoreTests.swift`:

```swift
@MainActor
func test_updateHost_changingForwards_advancesUpdatedAt() async throws {
    let store = try await makeStoreFixture()
    let initial = try await store.addHostFixture(forwards: [])
    let before = store.hosts.first(where: { $0.id == initial.id })!.updatedAt
    try await Task.sleep(nanoseconds: 10_000_000)  // ensure clock advance
    var edited = initial
    edited.forwards = [PortForward(kind: .dynamic, bindPort: 1080)]
    try store.updateHost(edited)
    let after = store.hosts.first(where: { $0.id == initial.id })!.updatedAt
    XCTAssertGreaterThan(after, before)
}
```

- [ ] **Step 3: Run the test**

```bash
cd apps/macos && swift test --filter "test_updateHost_changingForwards_advancesUpdatedAt"
```

Expected: PASS (existing logic).

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Tests/SessionStoreTests/SessionStoreTests.swift
git commit -m "test(macos): forwards edit advances host.updatedAt"
```

---

### Task 20: `HostFormView` — Port Forwarding Section UI

**Files:**
- Modify: `apps/macos/Sources/Caterm/Views/HostFormView.swift`

- [ ] **Step 1: Add state for forwards**

Near the other `@State` fields in `HostFormView`:

```swift
	@State private var forwards: [PortForward] = []
```

Seed it from the existing host in the edit path. In the existing `.onAppear` block (or wherever the form pulls existing host fields), add:

```swift
		if case let .edit(host) = mode {
			forwards = host.forwards
		}
```

- [ ] **Step 2: Add the Section to the form body**

Below the existing `Section("Authentication")` block, add:

```swift
				Section("Port Forwarding") {
					if forwards.isEmpty {
						HStack {
							Text("No port forwards")
								.foregroundStyle(.secondary)
							Spacer()
							Button("+ Add") { addForward() }
								.buttonStyle(.borderless)
						}
					} else {
						ForwardListEditor(
							forwards: $forwards,
							onAdd: addForward,
							onDelete: deleteForward
						)
					}
				}
```

Add the private helper methods:

```swift
	private func addForward() {
		let nextBind = lowestUnusedBindPort(start: 8080)
		forwards.append(PortForward(kind: .local, bindPort: nextBind,
		                            remoteHost: "localhost", remotePort: 8080))
	}

	private func deleteForward(_ id: UUID) {
		forwards.removeAll { $0.id == id }
	}

	private func lowestUnusedBindPort(start: Int) -> Int {
		let used = Set(forwards.map { $0.bindPort })
		var p = start
		while used.contains(p) { p += 1 }
		return p
	}
```

- [ ] **Step 3: Define `ForwardListEditor`**

In the same file (private to `HostFormView`):

```swift
private struct ForwardListEditor: View {
	@Binding var forwards: [PortForward]
	let onAdd: () -> Void
	let onDelete: (UUID) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			ScrollView {
				LazyVStack(spacing: 4) {
					ForEach($forwards) { $forward in
						ForwardRow(forward: $forward, onDelete: { onDelete(forward.id) })
					}
				}
			}
			.frame(maxHeight: forwards.count > 5 ? 180 : nil)

			Button("+ Add port forward", action: onAdd)
				.buttonStyle(.borderless)
		}
	}
}

private struct ForwardRow: View {
	@Binding var forward: PortForward
	let onDelete: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			Picker("", selection: $forward.kind) {
				Text("L").tag(PortForward.Kind.local)
				Text("R").tag(PortForward.Kind.remote)
				Text("D").tag(PortForward.Kind.dynamic)
			}
			.pickerStyle(.menu)
			.frame(width: 60)
			.labelsHidden()
			.onChange(of: forward.kind) { _, newKind in
				if newKind == .dynamic {
					forward.remoteHost = nil
					forward.remotePort = nil
				} else if forward.remoteHost == nil {
					forward.remoteHost = "localhost"
					forward.remotePort = forward.bindPort
				}
			}

			TextField("Bind port", value: $forward.bindPort, format: .number)
				.frame(width: 80)

			if forward.kind == .dynamic {
				Text("(dynamic)")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				HStack(spacing: 2) {
					TextField("host", text: Binding(
						get: { forward.remoteHost ?? "" },
						set: { forward.remoteHost = $0.isEmpty ? nil : $0 }
					))
					.frame(maxWidth: 140)
					Text(":")
					TextField("port", value: Binding(
						get: { forward.remotePort ?? 0 },
						set: { forward.remotePort = $0 }
					), format: .number)
					.frame(width: 70)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}

			Toggle("", isOn: $forward.required)
				.labelsHidden()
				.help("If enabled, a bind failure will abort the connection (only when ALL forwards on this host are required).")

			Button {
				onDelete()
			} label: {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
			.help("Delete this forward")
		}
		.padding(.vertical, 2)
		.overlay(alignment: .leading) {
			if (try? forward.validate()) == nil {
				EmptyView()  // OK
			} else {
				RoundedRectangle(cornerRadius: 4)
					.stroke(.red, lineWidth: 1)
					.padding(-2)
					.help("This forward has invalid settings.")
			}
		}
	}
}
```

- [ ] **Step 4: Validate forwards before Save**

Find the existing `onSubmit` / Save button click path. Add a validation gate alongside the existing one:

```swift
	private var canSave: Bool {
		// ...existing checks (hostname not empty, etc.)
		guard (try? PortForward.validateCollection(forwards)) != nil else { return false }
		return /* existing canSave expression */
	}
```

(Splice into whichever `canSave` / `isFormValid` property the form currently uses.)

When constructing the `SSHHost` to pass to `onSubmit`, include `forwards: forwards`:

```swift
		let host = SSHHost(
			// ...existing init args...
			jumpHostServerId: jumpHostServerId,
			forwards: forwards
		)
```

- [ ] **Step 5: Compile**

```bash
cd apps/macos && swift build
```

Expected: clean.

- [ ] **Step 6: Run the app and smoke-test**

```bash
cd apps/macos && make dev
```

In the running app: open Add Host sheet, expand the Port Forwarding section, add an `L 8080 → localhost:8080` forward, save. Open the host again — confirm the forward persists. Edit it to invalid (port = 0) — confirm Save disabled.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Sources/Caterm/Views/HostFormView.swift
git commit -m "feat(macos): port forwarding section in HostFormView"
```

---

### Task 21: Write the manual smoke checklist

**Files:**
- Create: `apps/macos/Manual/port-forwarding-smoke.md`

- [ ] **Step 1: Write the doc**

```markdown
# Port Forwarding — Manual Smoke

End-to-end checklist for verifying per-host port forwarding. Run on a two-Mac setup (Device A configures, Device B verifies sync) before merging.

## Prep

- A reachable test host (e.g., a Linux VM or remote box where you can `nc -l` to verify the forward landed).
- On the test host, install `nc` and ensure firewall allows the forward target ports.

## Cases

- [ ] **Local forward (happy path)**
  Add host. Add `L 8080 → localhost:8080`. Connect. On the test host, run `nc -l -p 8080`. On the Mac, `nc localhost 8080` and type — verify text appears on the test host.

- [ ] **Required forward, port pre-occupied**
  On the Mac, run `nc -l 5432` (binds 5432). In Caterm, add host with one required `L 5432 → db:5432`. Connect → expect red FailureOverlay reading "Port 5432 ... is already in use on your Mac. Edit the host..."

- [ ] **Optional forward, port pre-occupied**
  Same setup as previous, but mark the forward optional. Connect → terminal opens normally, yellow Banner appears reading "Skipped optional port forward(s): local 5432 (alreadyInUse)".

- [ ] **Dynamic SOCKS forward**
  Add `D 1080`. Connect. Run `curl --socks5 localhost:1080 https://api.ipify.org` — expect to see the remote host's public IP (not the Mac's).

- [ ] **Chain — only target's forwards bind locally**
  Add jumpbox host (with one Local forward configured, e.g., `L 9090 → localhost:9090`). Add target host using jumpbox as Via host, with its own `L 8080 → localhost:8080`. Connect to target. On Mac, `nc -l 9090` should be free (jumpbox's forward not active); `nc localhost 8080` should reach the target.

- [ ] **Remote forward (`-R`)**
  Add `R 9090 → localhost:9090`. Connect. On the test host, run `nc localhost 9090` — verify it reaches the Mac side.

- [ ] **Edit / save / reconnect persists**
  Edit an existing host, add a new forward, save. Reconnect — verify the new forward binds.

- [ ] **CloudKit sync**
  Edit forwards on Device A. Wait ≤ 30 s. Pull on Device B (or wait for push subscription). Verify Device B sees the new forwards in the host form.

- [ ] **ControlMaster teardown**
  Connect host with a Local forward (e.g., 8080). Confirm `lsof -iTCP:8080 -sTCP:LISTEN` shows the ssh process. Close the tab. Immediately re-run `lsof` — expect no listener. (Compare to a host without forwards: closing leaves the master alive for ~30 s.)
```

- [ ] **Step 2: Commit**

```bash
git add apps/macos/Manual/port-forwarding-smoke.md
git commit -m "docs(macos): manual smoke checklist for port forwarding"
```

---

## Self-Review Notes

**Spec coverage check:**
- §Data Model → Task 1 (`PortForward`), Task 3 (`Host.forwards`), Task 2 + Task 4 (validation + serialization tests).
- §Command Builder → Task 5 (chain `perHostOptions`), Task 6 (direct `_build`), Task 4 (helper).
- §Preflight → Task 9 (protocol), Task 10 (impl), Task 12 (wire into `startConnection`).
- §Failure Handling → Task 7 (`FailureKind`), Task 8 (3 exhaustive switch sites), Task 14 (banner render).
- §Sync — Pipeline touch points → Task 15 (RemoteHost DTOs), Task 16 (CKRecordHostMapping), Task 17 (reconciler diff), Task 18 (apply/add paths), Task 19 (updatedAt bump), Task 3 (local persistence via `Host` Codable).
- §ControlMaster Teardown → Task 13.
- §UI → Task 20.
- §Testing → Each implementation task ships its tests inline; Task 21 is the manual smoke.

**Placeholder scan:** None. Every step has either complete code, an exact command, or a referenced-then-defined helper that is filled in by an existing step.

**Type consistency:** `PortForward`, `PortBindOutcome`, `BindFailureReason`, `SkippedForwardNotice`, `ControlMasterTearDowning` all named identically across tasks.
