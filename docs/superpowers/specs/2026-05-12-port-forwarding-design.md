# Port Forwarding — Design

**Date:** 2026-05-12
**Status:** Draft (post-brainstorm)
**Scope:** `apps/macos/`

## Summary

Add per-host SSH port forwarding (Local `-L`, Remote `-R`, Dynamic SOCKS `-D`) to Caterm. Forwards are stored as a property of `SSHHost`, established automatically when a terminal session for that host opens, and torn down with the session. No standalone tunnel entity, no runtime attach/detach, no support for forwards on intermediate jump hosts.

## Goals

- Cover the 90% case: "when I connect to host X, also forward port P locally".
- Support all three OpenSSH forwarding modes (L / R / D).
- Surface bind-port conflicts to the user before the session fails.
- Sync forward configuration alongside hosts via existing CloudKit + server channels.
- Zero migration cost for existing hosts (`forwards: []` default).

## Non-Goals

- Standalone "tunnel" sessions without a terminal.
- Runtime attach/detach via `ssh -O forward` on an existing ControlMaster.
- Per-forward "scope" (target-only vs always-on across chain).
- Forwards declared on a host that is being used as a jump hop in a different connection.
- System-level SOCKS proxy configuration (PAC, network preferences) for `-D`.
- Bandwidth statistics or traffic counting per forward.

## Decisions Reference

| # | Decision | Rationale |
|---|---|---|
| 1 | per-host attached forwards (not standalone tunnels) | Reuses session lifecycle and ControlMaster; ships smallest viable feature |
| 2 | Forwards only emitted in the **target** host's `ssh_config` block | Matches OpenSSH semantics; user mental model "forward is a property of the host I'm connecting to" |
| 3 | `required` per-forward flag → triggers `ExitOnForwardFailure=yes` only when **all** forwards are required (OpenSSH option is global; partial application is impossible) | Strict by default; mixed sets fall back to preflight-only enforcement for local-bind, soft fail for remote-bind |
| 4 | UI surface: new Section inside existing `HostFormView` | Consistent with "forwards are a host sub-property"; minimal surface area |
| 5 | Data model: `Host.forwards: [PortForward]`; CloudKit field is a JSON string on the existing Host record | No new record type; reuses host LWW conflict resolution |
| 6 | Intermediate jump hops do **not** apply their `forwards` when not the target | Matches `~/.ssh/config` semantics; avoids silent port collisions |

---

## Architecture

### Lifecycle

```
HostFormView (edit/create)
    └─> Host.forwards: [PortForward]   (persisted to hosts.json + synced)
            │
            ▼
SessionStore.connect(hostId)
    │
    ├─> Preflight.probeForwardBindPorts(host.forwards)
    │       │
    │       ├─ all clear ──> proceed
    │       └─ required port busy ──> FailureKind.portForwardBindFailed
    │
    └─> SSHCommandBuilder.build(host: target, ancestors: chain, …)
            │
            └─> ssh -F <session-config>  caterm-h-<target-uuid>
                  └─ target Host block contains:
                       LocalForward / RemoteForward / DynamicForward lines
                       ExitOnForwardFailure yes  (only if every forward is required)
```

Forwards live and die with the ssh subprocess. ControlMaster reuse is unaffected (forward options on `ssh -O` would only matter if we did runtime attach, which we don't).

### Component Boundaries

| Module | Change |
|---|---|
| `SSHCommandBuilder` | Add `PortForward` type; emit forward lines in `perHostOptions` when `isTarget == true`; add `ExitOnForwardFailure` line; extend direct-path `_build` with matching `-o` flags |
| `SessionStore/Preflight.swift` | Add `probeForwardBindPorts(_:)` step before launching ssh |
| `SessionStore/FailureKind.swift` | Add `.portForwardBindFailed(forward:reason:)` case |
| `Caterm/Views/FailurePresentation.swift` | Render the new failure case with "Edit host" CTA |
| `Caterm/Views/HostFormView.swift` | New "Port Forwarding" Section with inline editable list |
| `HostSyncStore` / `CloudKitSyncClient` / `ServerSyncClient` | Encode/decode `forwards` field; tolerate absence on read |

No new top-level module is introduced. `PortForward` lives in `SSHCommandBuilder` because both the command builder and `Host` (also in that module) consume it.

---

## Data Model

### `PortForward`

```swift
public struct PortForward: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable, CaseIterable {
        case local    // -L: local bind → remote target via ssh server
        case remote   // -R: remote bind on ssh server → local target
        case dynamic  // -D: local SOCKS5 proxy
    }
    public enum BindFailureReason: String, Codable, Error {
        case alreadyInUse
        case permissionDenied
        case unknown
    }

    public let id: UUID
    public var kind: Kind
    public var bindAddress: String?   // nil = "localhost" (loopback); "*" = wildcard (all interfaces)
    public var bindPort: Int          // 1...65535
    public var remoteHost: String?    // required for .local/.remote; must be nil for .dynamic
    public var remotePort: Int?       // required for .local/.remote; must be nil for .dynamic
    public var required: Bool         // default true; controls ExitOnForwardFailure semantics
    public var label: String?         // optional human note; not emitted into ssh_config
}
```

### Validation

Enforced both in the model layer (throwing init) and in the Form (live red-border + disabled Save):

1. `bindPort` ∈ 1...65535.
2. `remotePort` ∈ 1...65535 when present.
3. `kind == .local || .remote` ⇒ `remoteHost` non-empty AND `remotePort != nil`.
4. `kind == .dynamic` ⇒ `remoteHost == nil` AND `remotePort == nil`.
5. Within one host's `forwards`, the 3-tuple `(kind, bindAddress ?? "localhost", bindPort)` is unique.
6. `bindAddress`, if present, is either `"*"` or matches a basic IPv4/IPv6/hostname pattern. (We do not resolve; we pass it through `SSHConfigQuote.encode`.)

### `Host` change

```swift
public struct Host: Codable, Identifiable, Hashable {
    // ...existing fields...
    public var forwards: [PortForward]   // default []
}
```

`init(from:)` uses `decodeIfPresent ?? []` for `forwards`, identical to the pattern already established for `jumpHostServerId` and `credentialMaterialDirty`. The synthesized encoder writes the key unconditionally; consumers that don't recognize it ignore it.

---

## Command Builder Changes

### Helper: serializing a forward

```swift
private func sshConfigLine(for forward: PortForward) throws -> String {
    let bindPrefix: String = {
        if let addr = forward.bindAddress, !addr.isEmpty {
            return "\(addr):\(forward.bindPort)"
        }
        return String(forward.bindPort)
    }()
    switch forward.kind {
    case .local:
        let target = "\(forward.remoteHost!):\(forward.remotePort!)"
        return "LocalForward \(try SSHConfigQuote.encode(bindPrefix)) \(try SSHConfigQuote.encode(target))"
    case .remote:
        let target = "\(forward.remoteHost!):\(forward.remotePort!)"
        return "RemoteForward \(try SSHConfigQuote.encode(bindPrefix)) \(try SSHConfigQuote.encode(target))"
    case .dynamic:
        return "DynamicForward \(try SSHConfigQuote.encode(bindPrefix))"
    }
}
```

Equivalent CLI emission for the direct-path (`_build`) case:
- `-o LocalForward=<bind> <target>` → quoted as a single `-o` value
- `-o ExitOnForwardFailure=yes` only when the host has at least one forward and **every** forward is required

### `perHostOptions` extension

In the existing `for line in opts.optionLines { ... }` block (used by `buildChain`), append after the credential / control-master lines:

```swift
if isTarget {
    var anyOptional = false
    for fwd in host.forwards {
        lines.append(try sshConfigLine(for: fwd))
        if !fwd.required { anyOptional = true }
    }
    // OpenSSH's ExitOnForwardFailure is global: setting it to `yes` aborts
    // the connection if ANY forward (required or optional) fails to bind.
    // We therefore only enable it when every forward is required. In mixed
    // sets, required forwards still benefit from local preflight (catches
    // L/D local bind conflicts before ssh starts); only remote-side `-R`
    // bind failures of required forwards in mixed sets fail silently — a
    // limitation documented in §"Known Limitations".
    if !host.forwards.isEmpty && !anyOptional {
        lines.append("ExitOnForwardFailure yes")
    }
}
```

### Direct-path `_build` extension

Mirror the same logic with `-o` flags so behavior is identical whether or not a chain is in play.

### Chain semantics

`buildChain` already calls `perHostOptions(for: hop, isTarget: hop.id == target.id, …)` per hop. With the `isTarget` gate above, intermediate hops naturally skip forward emission. **No additional changes** to chain assembly are required.

---

## Preflight

### `PreflightProbing` protocol extension

`SessionStore` injects `PreflightProbing`, currently only `probe(host:port:timeout:)`. We extend the **protocol** (not just the concrete `Preflight` struct) so SessionStore can call through, and tests can fake bind outcomes:

```swift
public enum PortBindOutcome: Equatable {
    case available
    case unavailable(PortForward.BindFailureReason)
}

public protocol PreflightProbing: Sendable {
    func probe(host: String, port: UInt16, timeout: TimeInterval) async -> PreflightOutcome
    // NEW
    func probeLocalBind(address: String, port: UInt16) async -> PortBindOutcome
}
```

`Preflight` implementation: `NWListener` create → start → on `.ready` cancel and return `.available`; on `.failed(NWError.posix(.EADDRINUSE))` return `.unavailable(.alreadyInUse)`; on `.failed(NWError.posix(.EACCES))` (privileged ports) return `.unavailable(.permissionDenied)`; otherwise `.unavailable(.unknown)`. Test fakes return canned `PortBindOutcome`.

### Probe step in connection flow

Runs **after** existing identity-file / known-hosts checks and **before** the ssh subprocess spawn.

```swift
// In SessionStore.startConnection, after existing preflight TCP probe:
for forward in host.forwards where forward.kind != .remote {
    let bindAddr = forward.bindAddress ?? "127.0.0.1"
    guard let nwPort = UInt16(exactly: forward.bindPort) else { continue }
    let outcome = await preflight.probeLocalBind(address: bindAddr, port: nwPort)
    if case .unavailable(let reason) = outcome {
        if forward.required {
            // Surface as a FailureKind, abort the connection.
            failConnection(.portForwardBindFailed(forward: forward, reason: reason))
            return
        } else {
            // Optional: continue connection, append a soft notice to
            // SessionStore's own @Published state. The view layer
            // observes it; SessionStore must NOT reach into the UI
            // target.
            skippedForwardNotices.append(.init(hostId: host.id, forward: forward, reason: reason))
        }
    }
}
```

### Crossing the module boundary

`SettingsBannerState` lives in the `Caterm` UI target; `SessionStore` is a separate Swift package and must not depend on it. New `@Published` state on `SessionStore` carries notices upward instead:

```swift
// In SessionStore.swift, alongside other @Published fields:
public struct SkippedForwardNotice: Identifiable, Equatable {
    public let id: UUID = UUID()
    public let hostId: UUID
    public let forward: PortForward
    public let reason: PortForward.BindFailureReason
    public let timestamp: Date = Date()
}
@Published public var skippedForwardNotices: [SkippedForwardNotice] = []
public func clearSkippedForwardNotices(forHost: UUID? = nil) { /* ... */ }
```

`MainWindow` observes `store.skippedForwardNotices` via the existing `@EnvironmentObject var store: SessionStore` and renders the yellow `Banner` from a derived value (similar to how `bannerState.diagnosticMessages` drives `DiagnosticBanner`). Notices for a host are cleared by `clearSkippedForwardNotices(forHost:)` when the user reconnects that host (in `startConnection`'s entry path).

`.remote` forwards bind on the remote side and **cannot be locally probed**. Required remote-forward failures are only surfaced when `ExitOnForwardFailure=yes` is set (all-required case) — see §"Known Limitations".

### Failure surface

- `required && local bind fails` → connection aborts; user sees `FailureOverlay` (existing component) with the new copy.
- `!required && local bind fails` → connection proceeds; a yellow info `Banner` (reuses the existing settings-style banner component in `MainWindow.swift`, not the red `DiagnosticBanner`) lists which optional forwards were skipped. Backed by `@Published var skippedForwardNotices` **on `SessionStore`** (see §"Crossing the module boundary" above) — not on the UI-target `SettingsBannerState`.

---

## UI

### `HostFormView` — new Section "Port Forwarding"

Placed below the existing "Authentication" Section. Stays inside the same modal sheet.

**Empty state**

Single row: muted text `No port forwards` aligned left, `+ Add` button trailing.

**Populated state**

Compact inline-editable table:

```
Type  | Bind Port | Target              | Req | ✕
------+-----------+---------------------+-----+---
L  ▾  | 5432      | db.internal : 5432  |  ☑  | ✕
L  ▾  | 8080      | localhost   : 8080  |  ☑  | ✕
D  ▾  | 1080      | (dynamic)           |  ☐  | ✕
```

- **Type** column: `Picker` with `.menu` style, three options L / R / D. Switching to D clears and disables the Target columns.
- **Bind Port** column: `TextField` numeric-only, width ~80pt.
- **Target** column: two `TextField`s separated by a colon-label — host (~140pt) and port (~70pt). Disabled and rendered as "(dynamic)" placeholder when Type == D.
- **Req** column: `Toggle` showing as checkbox. Tooltip explains `ExitOnForwardFailure` consequence.
- **✕** column: per-row delete button.
- Validation: invalid cells render with `.red` 1pt border + `.help()` tooltip showing the rule violated. Save button disabled while any row is invalid.
- Row count > 5: container takes `maxHeight: 180` with vertical scroll.
- Trailing `+ Add port forward` button beneath the table; appends a new row with defaults (`kind: .local, bindPort: lowest unused ≥ 8080, required: true`).

**Advanced bindAddress**

Out of scope for the inline UI in v1: defaults to `nil` (loopback). If users need wildcard bind they edit hosts.json directly. (Listed in §"Range Open Questions" below — can be revisited if users ask.)

### Failure overlay copy

```
Port 5432 is already in use on your Mac.

Caterm could not bind LocalForward 5432 → db.internal:5432 for
"Production DB" because another process owns the port.

  [ Edit host ]   [ Try again ]   [ Cancel ]
```

`Edit host` reopens `HostFormView` in `.edit` mode focused on the offending row (a `forwardId` parameter on the existing `editHost` notification path).

---

## Failure Handling

### New `FailureKind` case

```swift
case portForwardBindFailed(forward: PortForward, reason: PortForward.BindFailureReason)
```

### Exhaustive-switch sites — all three must be updated

The codebase has three exhaustive switches over `FailureKind`. Adding a new case is a breaking compile change; each call site gets a concrete branch:

| File:line | Function | New branch |
|---|---|---|
| `apps/macos/Sources/Caterm/Views/TerminalContainerView.swift:81-82` | `shouldShowFailureOverlay(_:)` | `case .portForwardBindFailed: return true` — show the red overlay |
| `apps/macos/Sources/SessionStore/ReconnectScheduler.swift:19-20` | `shouldReconnect(_:)` | `case .portForwardBindFailed: return false` — initial-setup failure, do not auto-reconnect |
| `apps/macos/Sources/Caterm/Views/FailurePresentation.swift:44-48` | `text(for:)` (overlay copy) | `case .portForwardBindFailed(let fwd, let reason):` — render copy per §UI |

### No ssh stderr capture in v1

Caterm currently has **no ssh stderr channel** — libghostty surfaces report only an exit code via `GhosttySurface.onChildExit(_:)`, then `SessionStore.markChildExited(exitCode:)` classifies via `FailureKind.classify(exitCode:hadConnected:)`. We are not adding a stderr pipe in this design.

Consequences:

1. **Required forwards in all-required hosts** → `ExitOnForwardFailure=yes` is set, so any bind failure (local race after preflight, or remote `-R`) makes ssh exit pre-Connected. `FailureKind.classify` routes that to `.authOrSetupFail` (existing generic copy). User sees the standard "auth or setup failed" overlay — **not** the new specific `portForwardBindFailed`. We accept the lost specificity here; precise mapping requires stderr capture which is out of scope.
2. **Required forwards in mixed sets** (some required + some optional) → `ExitOnForwardFailure` is **not** set. Local-bind failures are caught by preflight. Remote-side `-R` failures are silent — ssh prints a warning to stderr and the session continues without that forward. User sees a connected terminal with the forward not working. Documented in §"Known Limitations".

The new `portForwardBindFailed` `FailureKind` is therefore **only thrown by preflight** (where we positively identify the offending forward by examining `host.forwards` in code). It is never synthesized from ssh process exit.

### Optional-forward soft failure banner

When `required == false` and preflight detects bind failure, the session connects but a yellow info `Banner` (the existing settings-style banner in `MainWindow.swift`) appears above the terminal:

```
Port forward 1080 (SOCKS) skipped: already in use.
```

Dismissible. Cleared when the user reconnects.

---

## Sync

### Pipeline touch points — full enumeration

Adding `forwards` to `Host` is **not** sufficient. Hosts flow through several DTO / mapping layers and every one must carry the field, or pulled hosts arrive with empty forwards. Every site below must be updated:

| Site | File | Change |
|---|---|---|
| Local model | `SSHCommandBuilder/Host.swift` | `var forwards: [PortForward]` + `decodeIfPresent ?? []` + CodingKey |
| Server DTO | `ServerSyncClient/RemoteHost.swift` — `RemoteHost` struct | Add `forwards: [PortForward]` (encoded inline as JSON-compatible array; or as a String if the server stores it opaquely — decided by the server schema, but the **Swift type is `[PortForward]`** with a custom Codable bridge if needed) |
| Server create payload | `ServerSyncClient/RemoteHost.swift` — `RemoteHostCreateInput` | Add `forwards` field |
| Server update payload | `ServerSyncClient/RemoteHost.swift` — `RemoteHostUpdateInput` | Add `forwards` field (optional, same as other update fields) |
| CloudKit mapping | `CloudKitSyncClient/CKRecordHostMapping.swift` | Both directions: push writes `record["forwards"] = jsonString`; pull decodes `record["forwards"] as? String` → JSON decode → `[PortForward]`; absent → `[]`; corrupt JSON → `[]` + diagnostic log (never fail the whole sync). **Push must also bump `record[Field.metadataUpdatedAt] = host.updatedAt`** — already done at line 67 of the existing update path, but the precondition is that `host.updatedAt` itself is bumped on every forwards mutation (see next row) |
| `updatedAt` bump on forwards edit | `SessionStore.swift` — `updateHost(_:)` / any new `setForwards(...)` call site | Every code path that mutates `Host.forwards` MUST bump `host.updatedAt` before persisting / scheduling push. Without this, `metadataUpdatedAt` on the CKRecord stays stale; remote LWW (which prefers `metadataUpdatedAt`, then `modificationDate`, then `creationDate` per `CKRecordHostMapping.swift:111-113`) ignores the push, and pulls on other devices skip `updateLocal`. Add a unit test that mutates `forwards` via the production API and asserts `updatedAt > previousUpdatedAt` |
| Reconciler diff input | `HostSyncStore/HostSyncReconciler.swift` — `diff(local:remote:)` | If `local.forwards != remote.forwards`, classify as a host-level update (no separate operation type) |
| SessionStore apply (update path) | `SessionStore/SessionStore.swift:529` — `applyRemoteMetadata(localHostId:remote:)` | Add `hosts[idx].forwards = remote.forwards` to the field-copy block |
| SessionStore apply (insert path) | `SessionStore/SessionStore.swift:543` — `addRemoteHost(_:)` | Add `forwards: remote.forwards` to the `SSHHost(...)` constructor call |

Missing any of these silently drops forwards on pull.

### Local persistence

`hosts.json` carries the new `forwards` array per host. Encoded by the synthesized encoder. Decoded with `decodeIfPresent(... ) ?? []`. No migration step needed.

### CloudKit

The existing `Host` CKRecord gains one new field:

| Field | Type | Encoding |
|---|---|---|
| `forwards` | `String` (JSON-encoded `[PortForward]`) | `try JSONEncoder().encode(forwards)` → UTF-8 string |

Why a JSON string rather than a child record type or array of dictionaries: avoids CloudKit schema explosion (no new record type), keeps single-record LWW semantics intact, and matches what the rest of the codebase does for compound sub-objects (the credential blob is already shaped this way).

`CloudKitSyncClient`:
- On encode (push): always write the field, even when `forwards` is `[]` (serializes to `"[]"`). A missing field on read is treated as `[]`.
- On decode (pull): `record["forwards"]` may be absent (older client wrote the record) → `[]`. Parse with `JSONDecoder()`; on parse error log a diagnostic and treat as `[]` (better to lose forwards on a corrupt record than fail the whole sync).

No CloudKit schema migration is required: CloudKit allows fields to be added implicitly when first written.

### Self-hosted server (`ServerSyncClient`)

The host push/pull payload gains a `forwards` JSON array. Server-side schema change (`packages/db`) is **out of scope for this spec** but the macOS client encoder/decoder must already handle the field. If the server omits the field on pull, the client treats it as `[]` (forward compat with un-upgraded servers).

### Conflict resolution

Forwards ride with the host as a single LWW unit. The whole `forwards` array is replaced when a newer host record arrives. No per-forward merge. This matches existing host conflict semantics — simpler, predictable, and the worst case ("I edited forwards on two devices simultaneously") loses one device's edits, which we consider acceptable for v1.

---

## ControlMaster Teardown

### Problem

`SSHCommandBuilder.perHostOptions` emits `ControlMaster auto` + `ControlPersist 10m` for every host. The first ssh invocation becomes the master and physically holds the `LocalForward` listeners. When the user closes the last terminal tab for a host, `SessionStore.closeTab(tabId:)` (line 251) already calls `scheduleTeardown(hostId:)` (line 269), which waits `teardownGraceSeconds` (default **30 s**, not 10 min) before issuing `tearDown(hostId:)`. The 30 s grace exists so quick "close + reconnect" still benefits from a warm master.

For hosts with forwards, even 30 s is wrong: a closed terminal that still has port 5432 bound on the user's Mac is surprising. We collapse the grace to 0 for these.

### Fix: skip the teardown grace when the host has forwards

`SessionStore` already holds an injected `controlMasterManager: ControlMasterTearDowning?` (line 102) — the protocol exposed at line 21 has `tearDown(hostId:) async` and is the **only** call site `SessionStore` must use. Direct reference to `ControlMasterManager.shared` would re-introduce the package-dependency cycle the protocol was created to avoid.

`SessionStore.closeTab(tabId:)` changes:

```swift
public func closeTab(tabId: UUID) {
    // ...existing: remove from tabs, mark surface for teardown, etc.
    let hostHadForwards = !tab.host.forwards.isEmpty
    let isLastTabForHost = !tabs.contains(where: { $0.host.id == tab.host.id })

    if isLastTabForHost {
        if hostHadForwards {
            // Forwards outliving the session is observable to the user
            // (listening sockets stay bound). Skip the 30 s grace.
            Task { await controlMasterManager?.tearDown(hostId: tab.host.id) }
        } else {
            scheduleTeardown(hostId: tab.host.id)  // existing 30 s grace
        }
    }
}
```

### Differentiated behavior

| Host has forwards? | Tab close behavior |
|---|---|
| No | Existing path: `scheduleTeardown` with 30 s grace → `tearDown` |
| Yes | Immediate `controlMasterManager?.tearDown(hostId:)`, no grace |

### Edge cases

- **Multiple tabs on the same host**: SessionStore already checks "last tab for this host" before scheduling teardown (existing behavior). Same gate applies in the new branch — `tearDown` only fires when no other tab references the host.
- **SFTP file drawer open against the same host**: The SFTP subprocess piggybacks on the master via `controlPath`. Tearing down kills SFTP too. This is correct: closing the terminal closes the session entirely.
- **Crash / force-quit**: master may persist with the user's forwards bound. `ControlMasterManager.tearDownAll()` is already called at appropriate lifecycle points; no change needed.

## Known Limitations (v1)

1. **Mixed required + optional forwards on the same host**: required `-R` (remote-bind) forwards in such hosts fail silently if the remote port is taken. Workaround: mark every forward on the host as required (enables `ExitOnForwardFailure=yes`) or accept the silent-fail. Future fix: ssh stderr capture (out of scope).
2. **`portForwardBindFailed` `FailureKind` is preflight-only**: when ssh itself aborts post-spawn from `ExitOnForwardFailure=yes`, the user sees the generic `authOrSetupFail` overlay, not the specific forward overlay. Mapping requires stderr capture (out of scope).
3. **Bind address UI**: only loopback (default) is exposable through the form. Wildcard (`"*"`) and explicit IPs require editing `hosts.json` by hand. Defer until users ask.
4. **GatewayPorts**: not exposed. Required for `-R` listener on the remote to be reachable from outside the remote machine.

## Testing

### Unit tests

| Test file | What it covers |
|---|---|
| `SSHCommandBuilderTests` | ssh_config snapshot for each `Kind`; `bindAddress` nil vs `"*"`; `ExitOnForwardFailure` emitted iff **all** forwards are required (not "any"); empty `forwards` → no `ExitOnForwardFailure`; chain mode: only target's forwards emitted, intermediate hops have none; direct-path `_build` emits matching `-o` flags |
| `PortForwardValidationTests` (new) | Each validation rule (1–6 above) — happy + failing cases |
| `HostSyncStoreTests` | Legacy hosts.json without `forwards` decodes to `[]`; new hosts.json roundtrips; multi-host file with mixed legacy + new entries; reconciler treats `local.forwards != remote.forwards` as a host update |
| `CloudKitSyncClientTests` | `CKRecordHostMapping` push writes `forwards` JSON string; pull decodes round-trips; missing CloudKit field → `[]`; corrupt JSON → `[]` + diagnostic; `[]` encodes to `"[]"` not omitted |
| `SessionStoreTests` (extended) | Preflight: occupied port + required → `.portForwardBindFailed` thrown; occupied port + optional → connection proceeds + `skippedForwardNotices` populated on SessionStore; remote forward skipped by preflight; `applyRemoteMetadata` copies `forwards`; `addRemoteHost` carries `forwards`; mutating `forwards` via the public update API bumps `host.updatedAt` strictly upward; `closeTab` of host **with** forwards calls `controlMasterManager.tearDown` **immediately** (no grace, via injected `ControlMasterTearDowning` fake); `closeTab` of host **without** forwards goes through `scheduleTeardown` (existing 30 s grace); multi-tab same host → only last close triggers either teardown path |
| `CKRecordHostMappingTests` (extended) | Push writes `forwards` AND advances `metadataUpdatedAt` to `host.updatedAt`; pull with absent `forwards` → `[]`; pull with corrupt JSON `forwards` → `[]` + diagnostic |
| `PreflightTests` (extended) | New `PreflightProbing.probeLocalBind` fake honors injected outcomes; `Preflight` implementation: bound port → `.unavailable(.alreadyInUse)`; free port → `.available` |

### Manual smoke (added to `apps/macos/Manual/`)

Create `apps/macos/Manual/port-forwarding-smoke.md`:
1. Add host with one Local forward to a known service; connect; verify reachable on localhost.
2. Pre-occupy the bind port (`nc -l 5432`); connect required forward → expect FailureOverlay.
3. Same as #2 but mark forward optional → expect terminal opens + yellow banner.
4. Add Dynamic forward; configure `curl --socks5` to verify SOCKS works.
5. Two-hop chain (target has forwards, jumpbox has different forwards) → confirm only target's forwards bind locally.
6. Remote forward against test server → connect, verify remote side can reach back through the tunnel.
7. Edit existing host, add a forward, save; reconnect → forward present.
8. Pull on second device after editing forwards on first → confirm sync round-trip.

---

## Open Questions (Deferred)

- **IPv6 bind syntax**: OpenSSH wants brackets for IPv6 literals in some contexts; defer until first user need.
- **ssh stderr capture for precise post-spawn failure mapping**: would let us turn the generic `authOrSetupFail` into specific `portForwardBindFailed` after ssh exits. Significant work (libghostty surface integration); defer.

---

## Rollout

1. Model + builder: `PortForward` type, `Host.forwards`, `SSHCommandBuilder` emission (direct + chain), validation, unit tests. **No UI, no sync — `forwards` always `[]`.**
2. Failure model: `FailureKind.portForwardBindFailed` + branches in the three exhaustive switches; `FailurePresentation` copy.
3. Preflight: `PreflightProbing.probeLocalBind`, `Preflight` impl, SessionStore wiring, banner state for optional skips.
4. ControlMaster teardown: `SessionStore.closeTab` differentiated path + tests.
5. Persistence + sync (all 8 touch points in §"Pipeline touch points").
6. `HostFormView` UI Section.
7. Manual smoke pass on a real two-Mac setup before merging to main.

All steps land in a single PR by default. Steps 1–5 produce no user-visible change (UI hidden, forwards default `[]`), so they are safe to merge incrementally if the PR grows too large.
