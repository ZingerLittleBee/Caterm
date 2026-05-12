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
| 3 | `required` per-forward flag → triggers `ExitOnForwardFailure=yes` when any required forward exists | Strict by default (visible failure), opt-in soft mode for optional forwards |
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
                       ExitOnForwardFailure yes  (if any required forward)
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
    public enum BindFailureReason: String, Codable {
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
- `-o ExitOnForwardFailure=yes` when any required forward exists

### `perHostOptions` extension

In the existing `for line in opts.optionLines { ... }` block (used by `buildChain`), append after the credential / control-master lines:

```swift
if isTarget {
    var anyRequired = false
    for fwd in host.forwards {
        lines.append(try sshConfigLine(for: fwd))
        if fwd.required { anyRequired = true }
    }
    if anyRequired {
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

`SessionStore/Preflight.swift` gains a new probe step that runs **after** existing identity-file / known-hosts checks and **before** the ssh subprocess spawn.

```swift
func probeForwardBindPorts(_ forwards: [PortForward]) async throws {
    for forward in forwards where forward.kind != .remote {
        let bindAddr = forward.bindAddress ?? "127.0.0.1"
        let port = forward.bindPort
        do {
            try await tryBindAndRelease(host: bindAddr, port: port)
        } catch let reason as BindFailureReason {
            if forward.required {
                throw FailureKind.portForwardBindFailed(forward: forward, reason: reason)
            } else {
                // Surface a non-fatal info-level notice via SettingsBannerState
                // (yellow `Banner`, not red `DiagnosticBanner`); continue connection.
                emitForwardSkipNotice(forward: forward, reason: reason)
            }
        }
    }
}
```

Implementation uses `NWListener` (Network framework): create, bind, immediately cancel. `.remote` forwards bind on the remote side and cannot be locally probed; we accept that this will only be caught at session start via stderr parsing.

Failure surface:
- `required && bind fails` → connection aborts; user sees `FailureOverlay` (existing component) with the new copy.
- `!required && bind fails` → connection proceeds; a yellow info `Banner` (reuses the existing settings-style banner component in `MainWindow.swift`, not the red `DiagnosticBanner`) lists which optional forwards were skipped. Backed by a new `skippedForwardNotices: [String]` field on `SettingsBannerState`.

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

### stderr parsing

When `ExitOnForwardFailure=yes` is set and a remote-side bind fails (the only failure mode the preflight can't catch), ssh exits with a stderr line like:

```
Warning: remote port forwarding failed for listen port 9090
```

We parse this in the existing ssh stderr handler. If we can match a port number to a known `host.forwards` entry, surface `portForwardBindFailed(forward: matched, reason: .unknown)`. If we cannot match, fall back to the existing generic ssh-failure presentation.

Local-side bind failure post-spawn (e.g., race window between preflight and ssh) follows the same stderr-parsing path.

### Optional-forward soft failure banner

When `required == false` and bind fails, the session connects but a yellow info `Banner` (the existing settings-style banner in `MainWindow.swift`) appears above the terminal:

```
Port forward 1080 (SOCKS) skipped: already in use.
```

Dismissible. Cleared when the user reconnects.

---

## Sync

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

## Testing

### Unit tests

| Test file | What it covers |
|---|---|
| `SSHCommandBuilderTests` | ssh_config snapshot for each `Kind`; `bindAddress` nil vs `"*"`; `ExitOnForwardFailure` emitted iff any required forward; chain mode: only target's forwards emitted, intermediate hops have none; direct-path `_build` emits matching `-o` flags |
| `PortForwardValidationTests` (new) | Each validation rule (1–6 above) — happy + failing cases |
| `HostSyncStoreTests` | Legacy hosts.json without `forwards` decodes to `[]`; new hosts.json roundtrips; multi-host file with mixed legacy + new entries |
| `CloudKitSyncClientTests` | Encode → decode roundtrip; missing CloudKit field → `[]`; corrupt JSON → `[]` + diagnostic; `[]` encodes to `"[]"` not omitted |
| `SessionStoreTests` (extended) | Preflight: occupied port + required → `bindFailed` thrown; occupied port + optional → connection proceeds + warning emitted; remote forward skipped by preflight |

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

- **Wildcard / explicit-IP bind address UI**: currently nil-only (loopback). Add to UI later if requested.
- **IPv6 bind syntax**: OpenSSH wants brackets for IPv6 literals in some contexts; defer until first user need.
- **GatewayPorts**: required for non-loopback `-R` to be externally reachable. Defer; mention in docs if a user reports.
- **Per-host `ExitOnForwardFailure` override**: currently derived from any-required logic. If users want all-or-nothing they can mark every forward required.

---

## Rollout

1. Land `SSHCommandBuilder` + tests (no UI yet, no UI tests).
2. Land `SessionStore` Preflight + FailureKind + stderr parsing.
3. Land `HostSyncStore` / persistence + sync encoder.
4. Land `HostFormView` UI Section.
5. Manual smoke pass on a real two-Mac setup before merging to main.

Steps 1–3 can ship behind feature visibility — `forwards` always serialized but UI hidden — if we need to stage; default plan is single PR.
