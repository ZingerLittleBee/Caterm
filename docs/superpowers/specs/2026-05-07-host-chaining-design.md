# Host Chaining (ProxyJump)

## 1. Background

Many corporate SSH setups put the actual workload hosts behind a bastion
("jump host") that's the only publicly reachable endpoint. The user's
shell command would normally be `ssh -J user@bastion user@target`. Caterm
today has no concept of chains — each saved host is connected to
directly, so internal hosts are unreachable.

Termius (the user's prior tool) supports per-host "Connect via" chains
including password auth on intermediate hops. This spec brings the same
capability to Caterm.

Implementation works inside Caterm's existing constraints:
- Connections are spawned by libghostty as a `/bin/sh -c '<full ssh
  command>'` subprocess. We do **not** speak the SSH wire protocol
  ourselves; we drive OpenSSH's `ssh` CLI.
- Each saved host's credentials are already in the Caterm Keychain
  access group, looked up by `<host-id>.password|.passphrase`.
- A small per-session `caterm-askpass` helper (already in
  `apps/macos/Sources/CatermAskpass/main.swift`) is what actually serves
  passwords to ssh.

## 2. Goals

- A user can configure any saved host to connect "via" another saved
  host. The relationship is recursive — if host B itself has a "via",
  the chain is followed automatically. No explicit list editor, no
  hardcoded depth limit.
- Chain configuration syncs across devices via CloudKit (alongside the
  rest of `Host` metadata).
- All three credential methods (`.password`, `.keyFile`, `.agent`) work
  on intermediate hops, matching Termius. No "intermediate hops must be
  agent/key" v1 cut.
- Cycles in the chain are rejected at edit time and at runtime; broken
  chains (referenced host deleted) surface as a fail-fast error rather
  than a silent hang.
- The connection-progress UI (the overlays from the previous SSH
  connection progress feature) shows the chain so the user knows which
  hosts the connection is going through.
- Existing single-host connections (`jumpHostId == nil`) take the
  exact same code path they do today. Chain code is opt-in per host.

## 3. Non-Goals

- **SFTP through chain.** SFTP keeps its existing direct-only behavior.
  The `proxyjump` / `proxycommand` denylist in
  `SFTPCommandBuilder/SFTPCredentials.swift` stays — users cannot smuggle
  ProxyJump options into SFTP via raw config. (Future v2.)
- **Per-hop progress in the overlay.** We do not parse `ssh -vvv` debug
  output to identify which hop is currently authenticating. The
  `ConnectingOverlay` shows aggregate state (`Connecting…` /
  `Authenticating…`) plus a static chain line.
- **Per-hop failure identification.** When the connection fails, we
  surface the underlying ssh stderr verbatim
  (`FailureKind.networkUnreachable(.other(_, message))`) instead of
  parsing it to identify which hop failed.
- **Ad-hoc "Connect via…" menu.** v1 only supports persisted, per-host
  chain configuration. No transient overrides at connect time.
- **Multi-hop credential setup wizard.** If host B is referenced as a
  jump host but has no Caterm-stored credential, the user must connect
  to B directly first to establish the credential. Build fails with a
  clear message; we do not auto-pop a credential prompt for B from
  inside the connect-to-A flow.

## 4. Architecture

### 4.1 Data model: `SSHHost.jumpHostId`

`SSHHost` (in `apps/macos/Sources/SSHCommandBuilder/Host.swift`) gains
one optional field:

```swift
public struct SSHHost: Codable, Equatable, Hashable, Identifiable {
    // ... all existing fields unchanged ...
    public var jumpHostId: UUID?
}
```

- Backwards-compatible Codable: a missing `jumpHostId` decodes to `nil`.
- The init signature gets a `jumpHostId: UUID? = nil` default parameter
  added at the end so existing call sites compile unchanged.
- `Hashable` / `Equatable` synthesized — `jumpHostId` participates.

### 4.2 Chain resolver

A pure helper used by everything else:

```swift
public extension SSHHost {
    /// Returns the chain ancestors in connect order — index 0 is the
    /// host ssh dials *first* (deepest ancestor), the last entry is
    /// `self`'s direct parent. Returns an empty array if `jumpHostId`
    /// is nil. Throws if the chain has a cycle or references a host
    /// not in `hosts`.
    func resolvedChain(in hosts: [SSHHost]) throws -> [SSHHost]
}

public enum ChainResolutionError: Error, Equatable {
    case missingHost(UUID)             // jumpHostId points nowhere
    case cycle(involvingHostId: UUID)  // self-loop or cycle
}
```

Algorithm: walk from self via `jumpHostId`, tracking visited UUIDs. If
the current node's UUID is already in `visited`, throw `.cycle(...)`.
If the next host is not in `hosts`, throw `.missingHost(...)`. The
returned array is the visited chain in reverse order (so index 0 is the
deepest ancestor — the host ssh actually dials first).

`firstHopAddress(in:)` is a thin wrapper:

```swift
public extension SSHHost {
    /// First TCP endpoint ssh actually dials. Returns self's
    /// (hostname, port) when there's no chain; the deepest ancestor's
    /// (hostname, port) when there is one. Returns nil if the chain
    /// is broken (caller should fail-fast with an error message).
    func firstHopAddress(in hosts: [SSHHost]) -> (hostname: String, port: Int)?
}
```

### 4.3 Cycle / breakage detection at edit time

`HostFormView`:

- The "Via host" `Picker(.menu)` excludes:
  1. The host being edited (`mode == .edit(self)`).
  2. Any host whose chain (resolved against the in-memory hosts list)
     transitively passes through the host being edited. This prevents
     the user from picking an option that would cycle.
- Below the picker, a `.caption` shows the resolved chain preview
  ("Will connect via Bastion-A → Bastion-B"). If the chain hits a
  missing host, the line reads "via Bastion-A → (deleted)" in red.
- `isValid` rejects Save if `resolvedChain(...)` throws — defense in
  depth in case the picker filter has a bug.

`SessionStore.openTab(host:)`:

- Resolves the chain immediately. On `ChainResolutionError`, the new
  tab opens directly to `.failed(.networkUnreachable(.other(code: 0,
  message: "Jump host chain is broken — edit host to fix")))`. No
  preflight, no askpass spawn.

### 4.4 `SSHCommandBuilder` — ssh_config emission

Today's `SSHCommandBuilder.build()` returns
`(command: String, env: [(String, String)])`. With chains it must also
write a per-session config file. The signature changes minimally:

```swift
public protocol SSHConfigSink: Sendable {
    /// Writes `config` to a file with mode 0600 and returns the URL.
    /// The caller passes the URL back to `cleanup(_:)` when the session ends.
    func write(_ config: String) throws -> URL

    /// Removes the previously-written config file. No-op if it's already
    /// gone. Errors are swallowed (logged) — cleanup is best-effort.
    func cleanup(_ url: URL)
}

public extension SSHCommandBuilder {
    static func build(
        host: SSHHost,
        ancestors: [SSHHost] = [],          // empty == no chain
        configSink: SSHConfigSink,
        // ... existing parameters ...
    ) throws -> Output
}
```

Behavior split:

- **`ancestors.isEmpty == true`** — exact code path as today; the
  `configSink` is not called. No behavioral change for non-chain hosts.
- **`ancestors.isEmpty == false`** — emit a config snippet with one
  `Host` block per host (each ancestor + the target). Each block has
  `HostName`, `Port`, `User`, optional `IdentityFile`,
  `ServerAliveInterval 30`, `StrictHostKeyChecking accept-new`,
  `ControlPath ~/Library/Caches/Caterm/control/<host-id>.sock`,
  `ControlMaster auto`. Each non-deepest block adds
  `ProxyJump caterm-h-<parent-uuid>`. The command becomes
  `/usr/bin/ssh -F <config-url> caterm-h-<target-uuid>`.

The alias `caterm-h-<uuid>` is what the `Host` block name uses, and
what the final ssh invocation references — that way ssh resolves
HostName/Port/User/IdentityFile entirely from the config file and
ignores any unrelated entries the user might have in their personal
`~/.ssh/config`.

**Real `SSHConfigSink` implementation** lives next to SessionStore at
`apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift` (it has no
consumers outside SessionStore, so it doesn't need its own module).
Files go to `~/Library/Caches/Caterm/ssh-configs/<sessionId>.conf` with
mode 0600, and are deleted when the session's ssh subprocess exits
(SessionStore hooks into the existing exit-handling path it has for
control sockets).

**Test fake** `InMemorySSHConfigSink` records `write(_:)` calls without
touching the filesystem — used by the `SSHCommandBuilder` unit tests
that already cover the non-chain path.

### 4.5 Chain-aware `caterm-askpass`

`apps/macos/Sources/CatermAskpass/main.swift` today reads
`CATERM_HOST_ID` + `CATERM_ASKPASS_KIND` and looks up `<host-id>.<kind>`
in the Keychain. Single-host case: unchanged.

Chain case adds one new env var, `CATERM_CHAIN`, holding a JSON array
describing every host in the chain (target + every ancestor). Set by
`SSHCommandBuilder.build()` whenever it emits an ssh_config snippet.

```json
[
  { "hostId": "...", "user": "admin", "hostname": "jump1.example.com",
    "port": 22, "keyPath": "/Users/u/.ssh/jump1_key" },
  { "hostId": "...", "user": "app",   "hostname": "target.example.com",
    "port": 22, "keyPath": "/Users/u/.ssh/target_key" }
]
```

`keyPath` is null when the host's credential is `.password` or `.agent`.

The askpass binary's main routine, when `CATERM_CHAIN` is present:

1. Read `argv[1]` (the prompt ssh passes).
2. Match against two regexes:
   - Password: `^(?P<user>.+)@(?P<host>[^:'\s]+)(:(?P<port>\d+))?'s password: $`
   - Passphrase: `^Enter passphrase for key '(?P<path>.+)': $`
3. On password match: scan `CATERM_CHAIN` for an entry where
   `user == matched.user && hostname == matched.host`. (Port comparison
   is only enforced when `matched.port` is non-nil.) Look up the
   Keychain item `<entry.hostId>.password`.
4. On passphrase match: scan `CATERM_CHAIN` for an entry where
   `keyPath == matched.path`. Look up `<entry.hostId>.passphrase`.
5. On no match (unrecognized prompt format) **while in chain mode**:
   exit 2 with a diagnostic to stderr (`askpass: chain mode but
   prompt did not match: <prompt>`). Do not fall through to the
   single-host path — that would risk serving the target's secret in
   answer to an unrecognized prompt that might actually be coming
   from a different hop.

`CATERM_CHAIN` not being set leaves askpass in single-host mode
(reading `CATERM_HOST_ID` + `CATERM_ASKPASS_KIND` as today) —
existing single-host SSH tests are unaffected.

The matching logic is extracted into a pure helper:

```swift
struct AskpassChainEntry: Decodable, Equatable {
    let hostId: String
    let user: String
    let hostname: String
    let port: Int
    let keyPath: String?
}

enum AskpassLookup: Equatable {
    case password(hostId: String)
    case passphrase(hostId: String)
}

func resolveAskpassPrompt(_ prompt: String, chain: [AskpassChainEntry]) -> AskpassLookup?
```

Unit-tested independently of any keychain or filesystem.

### 4.6 SessionStore — chain on the tab

`SessionStore.Tab` gains `resolvedChain: [SSHHost]` (default empty).
Populated at `openTab(host:)` time by calling
`host.resolvedChain(in: hosts)`. If resolution throws, the tab opens
directly to `.failed(.networkUnreachable(.other(code: 0, message:
"Jump host chain is broken — edit host to fix")))` and `runConnection`
is not started.

`runConnection(tabId:)` adjustments:

- TCP preflight target changes from `host.hostname:host.port` to
  `host.firstHopAddress(in: hosts)` — which collapses to
  `host.hostname:host.port` for non-chain hosts. Failure rendering
  unchanged.
- The `surfaceConfig()` call passes the `resolvedChain` to
  `SSHCommandBuilder.build()` as the `ancestors` parameter and
  receives a `(command, env)` that includes `CATERM_CHAIN` when
  appropriate.

`closeTab` adds the new `ssh-configs/<sessionId>.conf` cleanup
alongside its existing control-socket cleanup.

### 4.7 UI — `HostFormView`

A new row in the existing **Connection** section, after `Username`:

```
LabeledContent("Via host") {
    Picker(selection: $jumpHostBinding) {
        Text("(none)").tag(UUID?.none)
        ForEach(eligibleHosts) { other in
            Text("\(other.name) (\(other.username)@\(other.hostname))")
                .tag(UUID?.some(other.id))
        }
    }
    .pickerStyle(.menu)
    .labelsHidden()
}
if !chainPreview.isEmpty {
    Text(chainPreview)
        .font(.caption)
        .foregroundStyle(chainHasMissingHost ? .red : .secondary)
}
```

`eligibleHosts` filters by:
- `host.id != mode.editingHostId` (no self-reference)
- `host.id` does not appear in the transitive chain of any host whose
  resolved chain currently passes through `mode.editingHostId`
  (prevents introducing a cycle on Save)

`chainPreview` reads "Will connect via X → Y → Z" (from-near-to-far)
when the picker has a non-nil selection. If a referenced host is
missing, the corresponding segment renders as `(deleted)`.

`isValid` adds: `host.resolvedChain(in: hosts)` must succeed (no cycle,
no missing host). Disable Save otherwise.

### 4.8 UI — `HostListSidebar`

Each host row gains a small SF Symbol on the trailing edge when
`host.jumpHostId != nil`:

- Symbol: `arrow.triangle.branch` at `.caption2` size, `.secondary`
  color (no badge background). Hover tooltip via `.help(...)` shows the
  full chain text ("via Bastion-A → Bastion-B").
- Hosts without a chain render unchanged.

The sidebar's deletion handler gains a fan-out alert: if any other
host references the to-be-deleted host as `jumpHostId`, prompt
"`<name>` is used by N hosts as their jump host. Delete anyway?". On
confirm, the dependent hosts are NOT cascade-deleted; their
`jumpHostId` becomes a dangling reference (which the form will surface
as `(deleted)` for the user to fix).

### 4.9 UI — connecting / failure / reconnect overlays

Each existing overlay gains a single-line chain caption rendered
**only** when `tab.resolvedChain` is non-empty:

```swift
if !chain.isEmpty {
    Text("via \(chain.map { "\($0.username)@\($0.hostname)" }.joined(separator: " → "))")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

Position: directly below the existing `user@host:port` line in
`ConnectingOverlay`, `FailureOverlay`, and `ReconnectOverlay`.

The state machine is **unchanged** — no new states, no per-hop
substates. Aggregate `Connecting…` / `Authenticating…` / `Reconnecting…`
covers chains transparently from the user's POV.

### 4.10 CloudKit sync

`apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`:

- `Field` enum gains `case jumpHostId` mapped to record key
  `"jumpHostId"`.
- `makeRecord(_:)` writes `host.jumpHostId?.uuidString as String?` (nil
  when no chain).
- `applyMetadata(_:to:)` reads the key as `String?`, parses
  `UUID(uuidString:)`, assigns to `host.jumpHostId`. Missing key →
  unchanged (decode-old-records compat).
- `decode(_:)` adds the same parse step.

Eventual consistency: a device may pull the target host before its
referenced jump-host record arrives. The form / overlays render the
referenced jump as `(deleted)` until the second pull lands and the
hosts list rebuilds — no special-case sync logic needed; the rest of
the system is already idempotent.

## 5. Testing

### 5.1 Unit (no IO, runs in `swift test`)

- **`SSHHost.resolvedChain(in:)`** — direct (no chain), single hop,
  multi-hop, broken chain (missing host), self-loop, two-host cycle,
  three-host cycle.
- **`SSHHost.firstHopAddress(in:)`** — same scenarios.
- **`HostFormView` cycle filter** (extracted into a pure helper for
  testability) — same scenarios + the "filter eligible hosts" case.
- **`AskpassChainEntry` JSON decode** — round-trip golden + missing
  fields tolerance.
- **`resolveAskpassPrompt(prompt:chain:)`** — password prompt with no
  port, password prompt with `:port`, passphrase prompt with absolute
  path, passphrase prompt with `~/...` path (should not match — ssh
  always resolves), unknown prompt format, empty chain.
- **`SSHCommandBuilder.build(...)`** — single host (verify identical
  behavior to today), single jump (config snippet contains both Host
  blocks, target has ProxyJump), multi-hop (deepest ancestor has no
  ProxyJump, others do), credential combinations (all keyFile, all
  agent, mixed, target password + jumps keyFile, target keyFile +
  jumps password), the alias names match `caterm-h-<uuid>` exactly,
  `CATERM_CHAIN` env contains every chain host.
- **CloudKit `CKRecordHostMapping` round-trip** — encode + decode for
  jumpHostId-nil and jumpHostId-non-nil hosts; old-record decode (no
  field present) yields nil.

### 5.2 Integration (real `sshd`, existing `EndToEndSSHTests`
infrastructure)

- **Single-jump chain success** — start two sshd containers (existing
  fixture), configure host B with `jumpHostId` pointing to A, open tab,
  assert `.connected` and an echo command round-trips.
- **Single-jump chain with password on the jump** — variant of the
  above where A uses `.password` credential. Verifies chain-aware
  askpass routes the prompt correctly.
- **Broken chain** — host B references a non-existent UUID. Open tab,
  assert tab lands in `.failed(.networkUnreachable(.other))` with the
  "Jump host chain is broken" message and `runConnection` never spawns
  ssh.

### 5.3 Manual verification

`apps/macos/Manual/host-chaining-checklist.md` covers:

1. Configure A → connect → set credential. Configure B with `Via host
   = A` → connect → success.
2. Open the host edit form for B; switch the picker between (none),
   A, and any other host; verify the live chain preview updates each
   click.
3. Delete A. Open B's edit form; verify "via A → (deleted)" appears
   in red; verify Save is disabled.
4. Re-create A (new UUID). The dangling reference doesn't auto-heal
   — user must re-pick A in B's form. (Documented.)
5. ConnectingOverlay shows the `via root@A` caption while connecting.
6. FailureOverlay shows the same caption when B is misconfigured.
7. HostListSidebar shows the chain icon on B; hovering surfaces the
   tooltip.
8. Restart the app — chain config persists.
9. On a second iCloud-paired device, observe B's `jumpHostId`
   syncs and the picker shows A correctly.
10. Configure C with `Via host = B` (B already has Via = A). Connect
    C — verify it works (multi-hop via implicit recursion).

## 6. Migration / Rollout

Single PR. No feature flag; chain is opt-in per host (jumpHostId
default nil) so existing users see no change until they configure one.

Order of changes inside the PR (matches plan task order):

1. Data model — SSHHost.jumpHostId, Codable + CloudKit field.
2. Pure helpers — `resolvedChain`, `firstHopAddress`,
   `cycle filter`, `resolveAskpassPrompt`. All unit-tested.
3. SSHCommandBuilder — ssh_config emission + InMemorySSHConfigSink
   for tests.
4. caterm-askpass — chain-aware mode.
5. SessionStore — Tab.resolvedChain, openTab early-fail, runConnection
   firstHop preflight, closeTab cleanup.
6. HostFormView — Via host picker + cycle filter + chain preview +
   isValid update.
7. HostListSidebar — chain icon + fan-out delete alert.
8. Overlays — chain caption in three overlays.
9. EndToEndSSHTests chain cases.
10. Manual checklist.
11. Final lint + smoke.

No data migrations; old hosts simply have `jumpHostId == nil` and take
the existing code path.

## 7. Open Questions

None blocking. All open items have a definitive answer in §4 (control
socket naming = per-alias, host-key policy = `accept-new` consistent
with current single-host policy, cross-device race handled by
existing eventual-consistency rendering).

## Appendix A — files touched

```
NEW:
apps/macos/Sources/SSHCommandBuilder/Chain.swift             // resolvedChain, firstHopAddress, ChainResolutionError
apps/macos/Sources/SSHCommandBuilder/HostFormCycleFilter.swift // pure helper
apps/macos/Sources/SSHCommandBuilder/SSHConfigSink.swift     // protocol
apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift    // real impl + cleanup (sibling of SessionStore.swift)
apps/macos/Sources/CatermAskpass/ChainResolver.swift         // resolveAskpassPrompt + AskpassChainEntry
apps/macos/Tests/SSHCommandBuilderTests/ChainTests.swift
apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderChainTests.swift
apps/macos/Tests/CatermAskpassTests/ChainResolverTests.swift
apps/macos/Tests/SessionStoreTests/SessionStoreChainTests.swift
apps/macos/Manual/host-chaining-checklist.md

MODIFY:
apps/macos/Sources/SSHCommandBuilder/Host.swift              // + jumpHostId
apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift // ancestors param + config emission
apps/macos/Sources/CatermAskpass/main.swift                  // CATERM_CHAIN parse
apps/macos/Sources/SessionStore/SessionStore.swift           // Tab.resolvedChain, openTab, runConnection, closeTab
apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift  // + jumpHostId field
apps/macos/Sources/Caterm/Views/HostFormView.swift           // Via picker, preview, isValid
apps/macos/Sources/Caterm/Views/HostListSidebar.swift        // chain icon, fan-out alert
apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift      // chain caption
apps/macos/Sources/Caterm/Views/FailureOverlay.swift         // chain caption
apps/macos/Sources/Caterm/Views/ReconnectOverlay.swift       // chain caption
apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift    // chain integration cases
```
