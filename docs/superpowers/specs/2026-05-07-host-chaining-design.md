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
  access group. (The exact suffix needs unification — see §1.1.)
- A small per-session `caterm-askpass` helper (already in
  `apps/macos/Sources/CatermAskpass/main.swift`) is what actually serves
  passwords to ssh.
- Each `SSHHost` carries TWO identifiers: a local-only `id: UUID`
  (regenerated on every device's pull) and a CloudKit-stable
  `serverId: String?`. Anything that crosses devices must reference
  `serverId`, not `id`.

### 1.1 Prerequisite fix: `keyPassphrase` keychain account suffix

The current code is internally inconsistent for key+passphrase auth:

- `SessionStore.setHostCredentialMaterial` writes the passphrase to
  Keychain account `<host-id>.keyPassphrase`
  (`SessionStore.swift:454, 501`).
- `SSHCommandBuilder` sets env `CATERM_ASKPASS_KIND=passphrase`
  (`SSHCommandBuilder.swift:100`).
- `caterm-askpass` then looks up `<host-id>.passphrase`
  (`CatermAskpass/main.swift:89`).

So for a key+passphrase host, ssh asks the askpass for the passphrase
and the askpass returns `KeychainError.notFound` because the secret is
under `keyPassphrase`, not `passphrase`. This is a latent bug today.

This spec fixes it by standardizing the env value on `keyPassphrase`
(matching what SessionStore stores). One-line change in
`SSHCommandBuilder` (env value) and one-line change in `CatermAskpass`
(accept `keyPassphrase` instead of `passphrase`). No Keychain
migration is needed because the on-disk Keychain accounts were already
written under `.keyPassphrase`.

The chain-aware askpass design in §4.5 then uses `keyPassphrase`
consistently, so the chain feature does not propagate the bug.

## 2. Goals

- A user can configure any saved host to connect "via" another saved
  host. The relationship is recursive — if host B itself has a "via",
  the chain is followed automatically. No explicit list editor, no
  hardcoded depth limit.
- Chain configuration syncs across devices via CloudKit, using
  `serverId` (cross-device-stable) as the chain reference, alongside
  the rest of `Host` metadata.
- All three credential methods (`.password`, `.keyFile`, `.agent`) work
  on intermediate hops, matching Termius. No "intermediate hops must be
  agent/key" v1 cut.
- Cycles in the chain are rejected at edit time and at runtime; broken
  chains (referenced host deleted, or referenced host has no local
  credential set up yet) surface as a fail-fast error in the
  connection state machine rather than a silent hang or a half-launched
  ssh.
- The connection-progress UI (the overlays from the previous SSH
  connection progress feature) shows the chain so the user knows which
  hosts the connection is going through.
- Existing single-host connections (`jumpHostServerId == nil`) take
  the exact same code path they do today. Chain code is opt-in per
  host.

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
  to B directly first to establish the credential. The chain connect
  fails fast with a clear message; we do not auto-pop a credential
  prompt for B from inside the connect-to-A flow.
- **Picking a not-yet-synced host as a jump host.** The picker only
  shows hosts that already have `serverId` set. A host created locally
  in offline mode (or just created in this session before the next
  CloudKit push) is excluded with a footnote until sync completes.

## 4. Architecture

### 4.1 Data model: `SSHHost.jumpHostServerId`

`SSHHost` (in `apps/macos/Sources/SSHCommandBuilder/Host.swift`) gains
one optional field:

```swift
public struct SSHHost: Codable, Equatable, Hashable, Identifiable {
    // ... all existing fields unchanged ...

    /// CloudKit-stable reference to another host that should be used
    /// as the jump host. Stored as `serverId` (not the local `id`)
    /// because local `id` UUIDs are regenerated on each device's
    /// pull. Nil = no chain (direct connect).
    public var jumpHostServerId: String?
}
```

- Backwards-compatible Codable: a missing `jumpHostServerId` decodes to
  `nil`.
- The init signature gets a `jumpHostServerId: String? = nil` default
  parameter at the end so existing call sites compile unchanged.
- `Hashable` / `Equatable` synthesized — the new field participates.

There is intentionally NO persistent `jumpHostId: UUID?` field. The
local UUID is resolved at use sites by looking up the host whose
`serverId` matches `self.jumpHostServerId` in the in-memory hosts
list (see §4.2). This keeps cross-device sync correct by construction.

### 4.2 Chain resolver

A pure helper used by everything else:

```swift
public extension SSHHost {
    /// Returns the chain ancestors in connect order — index 0 is the
    /// host ssh dials *first* (deepest ancestor); the last entry is
    /// `self`'s direct parent. Returns an empty array when
    /// `jumpHostServerId` is nil. Throws when the chain cycles or
    /// references a host not present in `hosts`.
    func resolvedChain(in hosts: [SSHHost]) throws -> [SSHHost]
}

public enum ChainResolutionError: Error, Equatable {
    /// The `jumpHostServerId` references a host that's not in the
    /// in-memory list (deleted, or not yet pulled from CloudKit on
    /// this device).
    case missingHost(serverId: String)

    /// Self-loop or cycle. The associated `serverId` is the first
    /// node revisited.
    case cycle(involvingServerId: String)
}
```

Algorithm: walk via `jumpHostServerId`, looking up each step in
`hosts` by `serverId`. Track visited serverIds; revisiting one ⇒
`cycle`. Missing lookup ⇒ `missingHost`. Self with `serverId == nil`
that has a non-nil `jumpHostServerId` is allowed at runtime — only
the parents need a serverId.

`firstHopAddress(in:)` is sugar for the SessionStore preflight site:

```swift
public extension SSHHost {
    /// First TCP endpoint ssh actually dials — i.e., the deepest
    /// ancestor's `(hostname, port)` when there's a chain, else
    /// `self`'s. Returns nil only when the chain is broken; the
    /// caller is expected to surface the underlying `resolvedChain`
    /// error rather than rely on this nil signal.
    func firstHopAddress(in hosts: [SSHHost]) -> (hostname: String, port: Int)?
}
```

### 4.3 Cycle / breakage / credential precheck

`HostFormView`:

- The "Via host" `Picker(.menu)` excludes:
  1. The host being edited.
  2. Any host whose chain (resolved against the in-memory hosts list)
     transitively passes through the host being edited (cycle
     prevention).
  3. Any host with `serverId == nil` (not yet synced — see §3 NoGoal).
- Below the picker, a `.caption` shows the resolved chain preview
  ("Will connect via Bastion-A → Bastion-B"). If the chain hits a
  missing serverId, the line reads "via Bastion-A → (deleted)" in red.
- `isValid` rejects Save if `resolvedChain(...)` throws — defense in
  depth.

`SessionStore.openTab(host:)`:

- **Resolves the chain immediately.** On `ChainResolutionError`, the
  new tab opens directly to
  `.failed(.networkUnreachable(.other(code: 0, message: "Jump host
  chain is broken — edit host to fix")))`. No preflight, no askpass
  spawn, no ssh subprocess.
- **Credential precheck (target + every ancestor).** Calls the
  existing `needsCredentialSetup(_:)` for the target and each
  ancestor. If any returns true, the tab opens directly to
  `.failed(.networkUnreachable(.other(code: 0, message: "<name>
  needs credentials configured first — connect to it directly to
  set them up")))` and `runConnection` is not started. This honors
  the existing single-host credential-prompt flow: the bastion has
  to be touched at least once on this device before it can be used
  as a jump.

### 4.4 `SSHCommandBuilder` — emits a chain config when needed

Today's `SSHCommandBuilder.build()` returns
`(command: String, env: [(String, String)])`. With chains it must also
write a per-session config file and remember its URL so SessionStore
can clean it up. Three changes:

(a) The internal "per-host options" generator is **factored out** so
the chain code path uses the exact same set of options the direct
path uses today (`UserKnownHostsFile`, `StrictHostKeyChecking`,
`PreferredAuthentications`, `PubkeyAuthentication=no`,
`PasswordAuthentication=no`, `KbdInteractiveAuthentication=no`,
`IdentitiesOnly=yes`, `IdentityFile`, `BatchMode=yes`,
`ControlMaster=auto`, `ControlPersist=10m`,
`ControlPath ~/Library/Caches/Caterm/cm/<host-id>.sock`,
`ServerAliveInterval`, terminfo wrapper). Each `Host` block in the
generated config is the moral equivalent of "what we'd build on the
command line for that host alone".

```swift
internal struct PerHostOptions {
    let hostName: String
    let port: Int
    let user: String
    let lines: [String]    // "<key> <value>" — already escaped
    let env: [(String, String)]   // SSH_ASKPASS / CATERM_HOST_ID etc — only for target
}

internal func perHostOptions(
    for host: SSHHost,
    isTarget: Bool,
    askpassPath: String,
    accessGroup: String?
) -> PerHostOptions
```

The direct (non-chain) path `build()` already calls a function with
this shape implicitly; the refactor just lifts and names it.

(b) The signature gains an `ancestors` parameter and an
`SSHConfigSink`:

```swift
public protocol SSHConfigSink: Sendable {
    /// Writes `config` to a file with mode 0600 and returns the URL.
    /// The caller passes the URL back to `cleanup(_:)` when done.
    func write(_ config: String) throws -> URL

    /// Removes the previously-written config file. No-op if it's
    /// already gone. Errors are swallowed (logged) — best-effort.
    func cleanup(_ url: URL)
}

public extension SSHCommandBuilder {
    public struct Output {
        public let command: String
        public let env: [(String, String)]
        public let configURL: URL?    // non-nil only when chain was emitted
    }

    static func build(
        host: SSHHost,
        ancestors: [SSHHost] = [],
        configSink: SSHConfigSink,
        askpassPath: String,
        accessGroup: String?
    ) throws -> Output
}
```

(c) Behavior split:

- **`ancestors.isEmpty == true`** — exact code path as today; the
  `configSink` is not called and `Output.configURL` is nil. No
  behavioral change for non-chain hosts.
- **`ancestors.isEmpty == false`** — emit one `Host` block per host
  (each ancestor + the target), aliased `caterm-h-<host-id-uuid>`
  (using the local UUID as the alias is fine — the alias only lives
  inside the per-session config file and is never persisted). Each
  non-deepest block adds `ProxyJump caterm-h-<parent-host-id-uuid>`.
  The shell command becomes:

  ```
  /usr/bin/ssh -F <config-url> caterm-h-<target-host-id-uuid>
  ```

  The terminfo wrapper continues to wrap this command. The env
  returned in `Output.env` includes `SSH_ASKPASS`, `CATERM_HOST_ID`
  (set to the target's UUID for back-compat with the single-host
  fallback), and `CATERM_CHAIN` (see §4.5).

`InMemorySSHConfigSink` (a test fake) records calls without touching
the filesystem. Real implementation is `CatermSSHConfigSink` in
`SessionStore` (sibling file of `SessionStore.swift`).

### 4.5 Chain-aware `caterm-askpass`

`apps/macos/Sources/CatermAskpass/main.swift` today reads
`CATERM_HOST_ID` + `CATERM_ASKPASS_KIND` and looks up
`<host-id>.<kind>` in the Keychain. Single-host case: unchanged.

Chain case adds one new env var, `CATERM_CHAIN`, holding a JSON array
describing every host in the chain (target + every ancestor) as seen
on **this device**:

```json
[
  { "hostId": "<local UUID>", "user": "admin",
    "hostname": "jump1.example.com", "port": 22,
    "keyPath": "/Users/u/.ssh/jump1_key" },
  { "hostId": "<local UUID>", "user": "app",
    "hostname": "target.example.com", "port": 22,
    "keyPath": null }
]
```

`hostId` is the **local UUID** (Keychain is local). `keyPath` is null
when the host's credential is `.password` or `.agent`.

The askpass binary's main routine, when `CATERM_CHAIN` is present:

1. Read `argv[1]` (the prompt ssh passes).
2. Match against two regexes:
   - Password: `^(?P<user>[^@]+)@(?P<host>[^:'\s]+)(:(?P<port>\d+))?'s password: $`
   - Passphrase: `^Enter passphrase for key '(?P<path>.+)': $`
3. On password match: scan `CATERM_CHAIN` for the entry with matching
   `user` and `hostname` (port enforced only when the prompt includes
   one). Look up Keychain `<entry.hostId>.password`.
4. On passphrase match: scan `CATERM_CHAIN` for the entry with
   matching `keyPath`. Look up Keychain
   `<entry.hostId>.keyPassphrase` — note the `.keyPassphrase` suffix,
   matching the prerequisite fix in §1.1.
5. On no match (unrecognized prompt format) **while in chain mode**:
   exit 2 with a diagnostic to stderr (`askpass: chain mode but
   prompt did not match: <prompt>`). Do not fall through to the
   single-host path — that would risk serving the target's secret in
   answer to an unknown prompt that might actually be coming from a
   different hop.

`CATERM_CHAIN` not being set leaves askpass in single-host mode
(reading `CATERM_HOST_ID` + `CATERM_ASKPASS_KIND`, with the suffix
unified to `keyPassphrase` as part of the prerequisite fix). Existing
single-host SSH tests are unaffected.

The matching logic is extracted into a pure helper in
`apps/macos/Sources/CatermAskpass/ChainResolver.swift`:

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

`SessionStore.Tab` gains two fields (defaults: `[]` and `nil`):

```swift
struct Tab {
    // ... existing fields ...
    var resolvedChain: [SSHHost]
    var sshConfigURL: URL?    // populated when SSHCommandBuilder
                              // emits a per-session config; deleted
                              // by closeTab / markChildExited.
}
```

`openTab(host:)`:
1. Resolve the chain. On `ChainResolutionError`, fail fast as in §4.3.
2. Run the credential precheck (target + every ancestor) via
   `needsCredentialSetup(_:)`. On any miss, fail fast as in §4.3.
3. Otherwise, set `resolvedChain` on the new tab and proceed to
   `runConnection(tabId:)`.

`runConnection(tabId:)`:
- TCP preflight target changes from `host.hostname:host.port` to
  `host.firstHopAddress(in: hosts)`.
- The `surfaceConfig()` call passes `resolvedChain` to
  `SSHCommandBuilder.build(...)` as the `ancestors` parameter and
  receives `Output { command, env, configURL }`. The tab's
  `sshConfigURL` is set to `configURL` (nil for non-chain hosts).

`closeTab(tabId:)` and `markChildExited(...)`: in addition to the
existing control-socket cleanup, they call
`configSink.cleanup(tab.sshConfigURL)` if non-nil. The cleanup is
idempotent and best-effort.

### 4.7 UI — `HostFormView`

A new row in the existing **Connection** section, after `Username`:

```
LabeledContent("Via host") {
    Picker(selection: $jumpHostServerIdBinding) {
        Text("(none)").tag(String?.none)
        ForEach(eligibleHosts) { other in
            Text("\(other.name) (\(other.username)@\(other.hostname))")
                .tag(String?.some(other.serverId!))   // safe: filtered
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
- `host.serverId != nil` (must be synced — see §3)
- The host's resolved chain does NOT pass through the host being
  edited (no cycle introduction)

`chainPreview` reads "Will connect via X → Y → Z" (from-near-to-far)
when the picker's selection is non-nil. If a referenced serverId no
longer resolves, the corresponding segment renders as `(deleted)`.

`isValid` adds: `host.resolvedChain(in: hosts)` must succeed.

If no other host has `serverId` yet (e.g., brand-new install before
first sync), the picker shows "(none)" only and a caption "Hosts must
finish syncing before they can be used as jump hosts." This is a
temporary state lasting until next sync push.

### 4.8 UI — `HostListSidebar`

Each host row gains a small SF Symbol on the trailing edge when
`host.jumpHostServerId != nil`:

- Symbol: `arrow.triangle.branch` at `.caption2` size, `.secondary`
  color (no badge background). Hover tooltip via `.help(...)` shows
  the full chain text ("via Bastion-A → Bastion-B").
- Hosts without a chain render unchanged.

The sidebar's deletion handler gains a fan-out alert: if any other
host references the to-be-deleted host's `serverId` as
`jumpHostServerId`, prompt "`<name>` is used by N hosts as their
jump host. Delete anyway?". On confirm, the dependent hosts are NOT
cascade-deleted; their `jumpHostServerId` becomes a dangling
reference (which the form will surface as `(deleted)` for the user
to fix).

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
substates. Aggregate `Connecting…` / `Authenticating…` /
`Reconnecting…` covers chains transparently from the user's POV.

### 4.10 CloudKit sync

`apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift`:

- `Field` enum gains `case jumpHostServerId` mapped to record key
  `"jumpHostServerId"`.
- `makeRecord(_:)` writes `host.jumpHostServerId as String?` (nil
  when no chain).
- `applyMetadata(_:to:)` reads the key as `String?`, assigns to
  `host.jumpHostServerId`. Missing key → unchanged
  (decode-old-records compat).
- `decode(_:)` adds the same parse step.

Eventual consistency: a device may pull the target host before its
referenced jump-host record arrives. The form / overlays render the
referenced jump as `(deleted)` until the second pull lands and the
hosts list rebuilds — no special-case sync logic needed; the rest of
the system is already idempotent.

## 5. Testing

### 5.1 Unit (no IO, runs in `swift test`)

- **`SSHHost.resolvedChain(in:)`** — direct (no chain), single hop,
  multi-hop, broken chain (missing serverId), self-loop, two-host
  cycle, three-host cycle, ancestor missing serverId (impossible by
  picker contract but must still be handled by the resolver).
- **`SSHHost.firstHopAddress(in:)`** — same scenarios.
- **HostFormView cycle filter** (extracted into a pure helper for
  testability) — same scenarios + the "filter eligible hosts" case
  + "exclude hosts with nil serverId" case.
- **`AskpassChainEntry` JSON decode** — round-trip golden + missing
  fields tolerance.
- **`resolveAskpassPrompt(prompt:chain:)`** — password prompt with no
  port, password prompt with `:port`, passphrase prompt with
  absolute path, passphrase prompt with `~/...` path (must NOT
  match — ssh always resolves these), unknown prompt format, empty
  chain.
- **`SSHCommandBuilder.perHostOptions(...)`** — covers each of the
  three credential kinds; output options match what `build()` used
  to inline-emit before the refactor (golden snapshots of the
  options string for each case).
- **`SSHCommandBuilder.build(...)`** — single host (golden output
  identical to today; no `configURL`), single jump (config snippet
  contains both Host blocks, target has `ProxyJump`), multi-hop
  (deepest ancestor has no `ProxyJump`, others do), credential
  combinations (all keyFile, all agent, mixed, target password +
  jumps keyFile, target keyFile-with-passphrase + jumps password).
  Asserts: alias names = `caterm-h-<uuid>`; `CATERM_CHAIN` env
  contains every chain host; `Output.configURL` non-nil; ControlPath
  uses `cm/<host-id>.sock` matching the existing convention.
- **CloudKit `CKRecordHostMapping` round-trip** — encode + decode
  for `jumpHostServerId`-nil and -non-nil hosts; old-record decode
  (no field present) yields nil.
- **Prerequisite `keyPassphrase` regression test** — single-host key
  + passphrase auth: `SSHCommandBuilder` emits
  `CATERM_ASKPASS_KIND=keyPassphrase`; `caterm-askpass` accepts
  `kind == "keyPassphrase"`.

### 5.2 Integration (real `sshd`, existing `EndToEndSSHTests`
infrastructure)

- **Single-jump chain success** — start two sshd containers (existing
  fixture), configure host B with `jumpHostServerId` pointing to A,
  open tab, assert `.connected` and an echo command round-trips.
- **Single-jump chain with password on the jump** — variant of the
  above where A uses `.password` credential. Verifies chain-aware
  askpass routes the prompt correctly.
- **Single-jump chain with key+passphrase on the jump** — also
  exercises the prerequisite `keyPassphrase` fix end-to-end.
- **Broken chain** — host B references a serverId not in the in-memory
  hosts list. Open tab, assert tab lands in
  `.failed(.networkUnreachable(.other))` with the "Jump host chain
  is broken" message and `runConnection` never spawns ssh.
- **Missing credential on jump** — host B references A; A has no
  Keychain credential set up yet. Open tab, assert tab lands in
  `.failed(.networkUnreachable(.other))` with the
  "<A's name> needs credentials configured first" message and
  `runConnection` never spawns ssh.

### 5.3 Manual verification

`apps/macos/Manual/host-chaining-checklist.md` covers:

1. Configure A → connect → set credential. Configure B with `Via host
   = A` → connect → success.
2. Open the host edit form for B; switch the picker between (none),
   A, and any other host; verify the live chain preview updates each
   click.
3. Delete A. Open B's edit form; verify "via A → (deleted)" appears
   in red; verify Save is disabled.
4. Re-create A (new UUID, new serverId). The dangling reference
   doesn't auto-heal — user must re-pick A in B's form. (Documented.)
5. ConnectingOverlay shows the `via root@A` caption while connecting.
6. FailureOverlay shows the same caption when B is misconfigured.
7. HostListSidebar shows the chain icon on B; hovering surfaces the
   tooltip.
8. Restart the app — chain config persists.
9. On a second iCloud-paired device, observe B's `jumpHostServerId`
   syncs and the picker shows A correctly **after the user
   re-enters credentials for A on this second device** (Keychain
   does not sync; existing single-host behavior).
10. Configure C with `Via host = B` (B already has Via = A). Connect
    C — verify it works (multi-hop via implicit recursion).

## 6. Migration / Rollout

Single PR. No feature flag; chain is opt-in per host
(`jumpHostServerId` default nil) so existing users see no change
until they configure one.

Order of changes inside the PR (matches plan task order):

1. **Prerequisite fix**: standardize on `keyPassphrase`. One-line
   env value change in `SSHCommandBuilder`; validation update in
   `CatermAskpass`. No Keychain account migration is needed because
   `SessionStore.setHostCredentialMaterial` already writes
   `.keyPassphrase`.
2. Data model — `SSHHost.jumpHostServerId`, Codable + CloudKit
   field.
3. Pure helpers — `resolvedChain`, `firstHopAddress`, cycle filter,
   `resolveAskpassPrompt`. All unit-tested.
4. SSHCommandBuilder refactor — extract `perHostOptions`, no
   behavior change; followed by the chain config emission +
   `Output.configURL`.
5. caterm-askpass — chain-aware mode.
6. SessionStore — `Tab.resolvedChain`, `Tab.sshConfigURL`,
   openTab early-fail (broken chain + missing credential), runConnection
   firstHop preflight, closeTab + markChildExited cleanup.
7. CatermSSHConfigSink concrete impl in `SessionStore` module.
8. HostFormView — Via picker + cycle filter + chain preview +
   `isValid` update.
9. HostListSidebar — chain icon + fan-out delete alert.
10. Overlays — chain caption in three overlays.
11. EndToEndSSHTests chain cases.
12. Manual checklist.
13. Final lint + smoke.

No data migrations; old hosts simply have `jumpHostServerId == nil`
and take the existing code path.

## 7. Open Questions

None blocking. All design decisions (control-path matches existing
`cm/` convention, host-key policy `accept-new`, cross-device race
handled by existing eventual-consistency rendering, chain ref via
serverId, prerequisite `keyPassphrase` fix) have definitive answers
above.

## Appendix A — files touched

```
NEW:
apps/macos/Sources/SSHCommandBuilder/Chain.swift                 // resolvedChain, firstHopAddress, ChainResolutionError
apps/macos/Sources/SSHCommandBuilder/HostFormCycleFilter.swift   // pure helper
apps/macos/Sources/SSHCommandBuilder/SSHConfigSink.swift         // protocol
apps/macos/Sources/SessionStore/CatermSSHConfigSink.swift        // real impl + cleanup
apps/macos/Sources/CatermAskpass/ChainResolver.swift             // resolveAskpassPrompt + AskpassChainEntry
apps/macos/Tests/SSHCommandBuilderTests/ChainTests.swift
apps/macos/Tests/SSHCommandBuilderTests/SSHCommandBuilderChainTests.swift
apps/macos/Tests/CatermAskpassTests/ChainResolverTests.swift
apps/macos/Tests/SessionStoreTests/SessionStoreChainTests.swift
apps/macos/Manual/host-chaining-checklist.md

MODIFY:
apps/macos/Sources/SSHCommandBuilder/Host.swift                  // + jumpHostServerId
apps/macos/Sources/SSHCommandBuilder/SSHCommandBuilder.swift     // perHostOptions extraction; chain config emission; CATERM_ASKPASS_KIND=keyPassphrase
apps/macos/Sources/CatermAskpass/main.swift                      // CATERM_CHAIN parse; accept kind=keyPassphrase
apps/macos/Sources/SessionStore/SessionStore.swift               // Tab.resolvedChain, Tab.sshConfigURL, openTab precheck, runConnection, closeTab, markChildExited
apps/macos/Sources/CloudKitSyncClient/CKRecordHostMapping.swift  // + jumpHostServerId field
apps/macos/Sources/Caterm/Views/HostFormView.swift               // Via picker, preview, isValid
apps/macos/Sources/Caterm/Views/HostListSidebar.swift            // chain icon, fan-out alert
apps/macos/Sources/Caterm/Views/ConnectingOverlay.swift          // chain caption
apps/macos/Sources/Caterm/Views/FailureOverlay.swift             // chain caption
apps/macos/Sources/Caterm/Views/ReconnectOverlay.swift           // chain caption
apps/macos/Tests/SessionStoreTests/EndToEndSSHTests.swift        // chain integration cases
```
