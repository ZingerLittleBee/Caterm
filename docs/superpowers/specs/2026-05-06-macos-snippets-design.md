# macOS Snippets — Design Spec

**Date:** 2026-05-06
**Revised:** 2026-05-06 (post-review fixes for target layout, Run-mode injection, surface targeting, delete durability, zone/token separation, and menu-shortcut wording)
**Target app:** `apps/macos/`
**Status:** Design accepted; implementation pending (proposed Plan F, see §7). Run mode is gated on a Task 0 spike — see §5.

## 1. Goal

Let the user save reusable command/script snippets and inject them into the active SSH terminal as either a **Paste** (non-destructive — content sits at the prompt for the user to inspect/edit) or **Run** (executed immediately). Snippets sync across the user's Macs via CloudKit.

## 2. Scope

### In scope (v1)

- Plain-text snippets: a `name` and a multi-line `content` string.
- A reserved `placeholders` field on the schema so future variable-substitution support does not require CloudKit schema migration.
- Flat list with substring search across `name` and `content` (case-insensitive).
- Two trigger surfaces:
  - Command palette via app-scoped menu shortcut `⌘⇧P` (only active when Caterm is frontmost).
  - Toolbar button on the terminal pane (popover with the same palette body).
- Quick create via app-scoped menu shortcut `⌘⇧S`.
- Dedicated management sheet via `View → Manage Snippets…`.
- CloudKit per-record sync using the `HostSyncStore` pattern (incremental token, tombstones, force-full safety net, account-switch wipe), in a **dedicated `Snippets` zone** (not the existing `Caterm` host zone — see §3.5).

### Out of scope (deferred)

| Feature | Why deferred |
|---|---|
| Variable placeholder substitution UI | Schema reserved; UI complexity not justified for v1. |
| Tags / folders | Flat + search adequate at expected snippet counts. |
| Per-host scoping | Most useful commands are universal. |
| Save-from-terminal-buffer ("save last command") | Requires shell-prompt detection that ghostty does not expose stably. |
| Manual reorder / usage-frequency sort | Default `updatedAt DESC` is sufficient. |
| Import / export / sharing | Not requested. |
| Snippet content encryption | Snippets are explicitly **not** for sensitive data — credentials must use the Plan C path. |
| Dangerous-command confirmation prompts | Independent feature. |

## 3. Architecture

### 3.1 SwiftPM target layout

The existing host pattern factors the model + sync protocol into a low-level types target (`ServerSyncClient`) so that `CloudKitSyncClient` can conform to the protocol without depending on the high-level coordinator (`HostSyncStore`). We mirror this exactly:

| New target | Kind | Depends on | Holds |
|---|---|---|---|
| `SnippetSyncClient` | Library (types-only) | none | `Snippet` model · `SnippetChangeBatch` · `SnippetSyncCheckpoint` (protocol) · `IncrementalSnippetSyncClient` (protocol) · `Notification.Name.catermCloudKitSnippetChanged` |
| `SnippetStore` | Library (high-level coordinator) | `SnippetSyncClient` | `SnippetStore` (`@Published var snippets`, JSON persistence, pending-delete outbox) · `SnippetSyncStore` (pull/push loop, LWW reconciliation, tombstone application) · `SnippetSyncReconciler` |

**Modified existing target:**

| Target | Change |
|---|---|
| `CloudKitSyncClient` | Add `SnippetSyncClient` to its `dependencies`. Add a new file `CloudKitSyncClient+Snippet.swift` that extends `CloudKitSyncClient: IncrementalSnippetSyncClient`. |
| `Caterm` (executable) | Add both `SnippetSyncClient` and `SnippetStore` to `dependencies`; wire the concrete `CloudKitSyncClient` into `SnippetSyncStore` at app boot. |

**Why this split:** putting both the model and the high-level store in the same target while having `CloudKitSyncClient` return `Snippet` would create the cycle `SnippetStore → CloudKitSyncClient → SnippetStore`. The split puts the wire types one level below the coordinator, identical to how `RemoteHost` / `HostChangeBatch` / `IncrementalHostSyncClient` are defined in `ServerSyncClient` and consumed by both `CloudKitSyncClient` and `HostSyncStore`.

### 3.2 Data model

```swift
// In SnippetSyncClient target
public struct Snippet: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID                    // Primary key. Equals CKRecord.recordName.
    public var name: String                // Required, non-empty after trim.
    public var content: String             // Required, non-empty.
    public var placeholders: [String]?     // Reserved. v1 always nil.
    public var createdAt: Date
    public var updatedAt: Date             // Drives default sort + LWW tie-breaker.

    // Sync fields (mirror SSHHost conventions)
    public var serverId: String?           // CKRecord.recordName as String.
    public var revision: Int               // Local version counter; bumps on every edit.
    public var metadataUpdatedAt: Date?    // Server modification date snapshot.
}
```

Local persistence: `~/Library/Application Support/Caterm/snippets.json` (sibling of `hosts.json`). Atomic write via temp-file + rename, identical to the host store. Schema version stamped in the JSON envelope for forward migrations.

### 3.3 CloudKit `Snippet` record type

| Field | Type | Indexes | Notes |
|---|---|---|---|
| `recordName` | String (system) | Queryable | UUID. |
| `name` | String | Queryable | |
| `content` | String | — | ≤ 1 MB CK string limit; ample for multi-line scripts. |
| `placeholders` | String (optional) | — | JSON-encoded array of strings. v1 never written. |
| `createdAt` | Date/Time | — | |
| `updatedAt` | Date/Time | Queryable, Sortable | Used for incremental fetch and LWW tie-break. |
| `revision` | Int64 | — | LWW primary key. |
| `schemaVersion` | Int64 | — | Default `1`. Reserved for migrations. |

Encoding `placeholders` as a single JSON string (rather than CloudKit's `String List`) avoids edge cases in CK list-field indexing observed during Plan A and keeps the field free for future shape changes.

> **Encoding boundary:** the Swift model in §3.2 stores `placeholders: [String]?`. The push path JSON-encodes it to a CKRecord String field; the pull path JSON-decodes back. v1 always encodes/decodes `nil`; the round-trip is exercised in tests but never produces non-nil output until variable substitution lands.

### 3.4 Sync component diagram

```
SnippetStore (local state, JSON, @Published)
    ▲                              ▲
    │ apply pulled deltas          │ user mutations
    │ (via SnippetSyncStore)       │ (debounced push via SnippetSyncStore)
    │                              │
SnippetSyncStore ─── (uses) ───▶ IncrementalSnippetSyncClient
                                       △  conforms
                                       │
                          CloudKitSyncClient
                                  (uses Snippets zone, separate token namespace)
```

### 3.5 Zone, tokens, checkpoint

**Zone:** `CKRecordZone.ID(zoneName: "Snippets", ownerName: CKCurrentUserDefaultName)` — **distinct from the existing `Caterm` zone** that holds `Host` records.

**Why a separate zone:** the existing host drain (`drain(mode:)` in `CloudKitSyncClient`) sees every record in the `Caterm` zone, decodes via `CKRecordHostMapping`, silently skips non-host records, and **advances the zone token**. If `Snippet` records lived in the same zone, the host drain would consume their token deltas and snippet sync would never see them. Putting snippets in their own zone gives the snippet drain its own token state machine and makes the failure modes per-feature.

**Tokens:** parallel `UserDefaultsServerChangeTokenStore` semantics, but in a **separate UserDefaults key namespace**:

| Concern | Existing (host) | New (snippet) |
|---|---|---|
| DB token key | `cloudkit.changeToken.database` | `cloudkit.changeToken.snippet.database` |
| Zone token prefix | `cloudkit.changeToken.zone.` | `cloudkit.changeToken.snippet.zone.` |
| Epoch key | `cloudkit.changeToken.epoch` | `cloudkit.changeToken.snippet.epoch` |

Implementation either (a) instantiates a second `UserDefaultsServerChangeTokenStore` parameterized by a key prefix (preferred — cleanest), or (b) introduces a sibling `UserDefaultsSnippetChangeTokenStore`. The protocol `ServerChangeTokenStoring` is unchanged.

**Checkpoint:** parallel to `CloudKitSyncClient.Checkpoint` but for the snippet zone:

```swift
internal struct SnippetCheckpoint: SnippetSyncCheckpoint {
    let id: UUID
    let epoch: UInt64
    let prevDb: Data?
    let newDb: Data?
    let prevZones: [String: Data?]
    let newZones: [String: Data?]
}
```

CAS semantics identical to the host checkpoint (zone-key absent → skip; nil value → delete; non-nil → rotate).

### 3.6 New `CloudKitSyncClient` methods

```swift
// On IncrementalSnippetSyncClient (declared in SnippetSyncClient target)
public protocol IncrementalSnippetSyncClient: Sendable {
    func preferredSnippetSyncMode() async -> SnippetSyncMode
    func fetchSnippetChanges() async throws -> SnippetChangeBatch
    func fetchSnippetSnapshotAndCheckpoint() async throws -> SnippetChangeBatch
    func commitSnippetCheckpoint(_ checkpoint: any SnippetSyncCheckpoint) async throws
    func resetSnippetSyncState() async
    func ensureSnippetSubscription() async throws
    func deleteSnippetSubscription() async throws
    func pushSnippet(_ snippet: Snippet) async throws -> Snippet
    func deleteSnippet(id: UUID) async throws
}
```

Method shapes mirror `IncrementalHostSyncClient` so the high-level coordinator can copy proven control-flow.

### 3.7 LWW reconciliation

Algorithm copied from `HostSyncReconciler`:

```
applyPulled(cloud, local):
  if cloud.revision > local.revision: write cloud to local
  if cloud.revision < local.revision: keep local (next push will overwrite)
  if cloud.revision == local.revision:
      compare metadataUpdatedAt (server-authoritative; cloud wins on tie)
      tie-break on updatedAt
      final tie-break: cloud wins (defends against local clock drift)
```

Hard delete is terminal: a tombstone always beats a concurrent edit on the other Mac. The other Mac, on the next pull, removes the local copy regardless of its local revision.

### 3.8 Pending-delete outbox + offline durability

A naive "delete locally, then push" loses the delete intent if the push fails (network loss, app quit, account drop). The host store has the same problem and solves it via persisted intent. Snippets adopt the same model:

```swift
// Persisted alongside snippets.json (same envelope or sibling file)
struct SnippetOutbox: Codable {
    var pendingDeletedSnippetIDs: Set<UUID>
}
```

**Delete flow:**

1. `SnippetStore.delete(id:)` — remove from in-memory list, add `id` to `pendingDeletedSnippetIDs`, atomic-write both JSON files.
2. `SnippetSyncStore` push pass — for each id in `pendingDeletedSnippetIDs`, call `deleteSnippet(id:)`. On success, remove from outbox. On failure, leave for retry.
3. App relaunch — outbox is read first; pending deletes are reattempted before any other push.

**Edge case — delete then create same id:** UUIDs are random, collision is impossible by construction. No special handling.

**Edge case — delete then offline pull resurrects:** if a remote Mac re-pushed the same record while we were offline (unlikely without a stale cache, but possible), the outbox-driven retry will push the tombstone next pass and win. Worst case is a transient flicker; acceptable.

### 3.9 Account-switch wipe semantics

`AccountIdentityTracker.handleAccountChange` (`AccountIdentityTracker.swift:38`) currently resets sync tokens and deletes subscriptions. **It does not touch local user content** — that responsibility lives in the high-level stores. For snippets:

1. App boot wires `SnippetSyncStore` to observe `.catermICloudAccountChanged` (existing notification, posted by `iCloudAccountSession`).
2. On notification: `SnippetSyncStore` calls `client.resetSnippetSyncState()` (clear tokens, identical to host path), then `SnippetStore.wipeLocal()` which atomically clears `snippets.json` + `pendingDeletedSnippetIDs`, posts a `@Published` change.
3. Subsequent `syncIfSignedIn()` runs `forceFull` on the new account and repopulates from cloud.

This path is symmetric with how Plan A wipes host state — same sequence, separate target.

### 3.10 Active terminal targeting (surface registry)

The palette must dispatch to the *terminal session that was active when the user opened it*, not to whatever has first responder status when Enter is pressed (the palette TextField will have stolen first responder).

**Mechanism:**

1. Extend `SessionStore.Tab` (or add a sibling actor) with `weak var surface: GhosttySurface?`.
2. `TerminalSurfaceRepresentable.makeNSView` (`TerminalContainerView.swift:46`) registers the surface on the tab once `view.surface` is built (currently happens inside the lazy-load `Task { ... }` block at `:57-68`).
3. The palette (and its toolbar-button popover variant) **captures the active tab's surface reference at open time** — stores it in local view state. Focus changes during palette interaction do not affect the captured target.
4. If the captured surface releases mid-flight (reconnect, tab closed), `weak` resolves to nil; Enter / ⌘+Enter shows the toast described in §5.4 and closes the palette.

**Active-tab resolution:** read from existing `SessionStore` ("which tab is currently selected in the focused window"). If multiple windows are open, the palette is window-scoped — the menu-shortcut path opens a palette anchored to the key window's selected tab. Toolbar-button popover is inherently anchored to its window.

### 3.11 Sync triggers

| Trigger | Path |
|---|---|
| App launch | `syncIfSignedIn()` runs incremental fetch using persisted `CKServerChangeToken`. Pending-delete outbox drained first. |
| Local edit | Debounce 500 ms, then `pushSnippet`. Coalesces rapid edits. |
| Local delete | Outbox + immediate retry (see §3.8). |
| Remote push (silent push) | APS `parsePushUserInfo` dispatch — `AppDelegate` adds case `.snippet` alongside the existing `.host` case. New subscription ID `CloudKitPushNames.snippetSubscriptionID`. |
| 60-min force-full safety net | New timer in `SnippetSyncStore`, independent cadence from the host force-full. |
| iCloud account change | `.catermICloudAccountChanged` → §3.9 wipe sequence. |

### 3.12 Out-of-band CloudKit Dashboard setup

Required once per environment (Development + Production). **Cannot be automated — requires Apple Developer console.**

1. CloudKit Dashboard → Container `iCloud.com.caterm.app` → Schema → Record Types → New.
2. Name: `Snippet`. Fields per §3.3.
3. Indexes: `recordName` Queryable; `updatedAt` Queryable + Sortable.
4. Custom zone: `Snippets`. Created automatically on first push if missing — no Dashboard step needed for the zone itself, but record-type schema must be present first.
5. (Subscriptions are created at runtime via `ensureSnippetSubscription`, not in schema.)
6. After dev verification: Deploy Schema to Production.

This step blocks live verification but not local development.

## 4. UI

### 4.1 Files (new)

`apps/macos/Sources/Caterm/Views/Snippets/`:

| File | Responsibility |
|---|---|
| `SnippetPalette.swift` | Search field + result list + Enter / ⌘+Enter dispatch. Used both as the menu-shortcut palette and as the toolbar-button popover body. Captures target `GhosttySurface` at open (§3.10). |
| `SnippetEditorSheet.swift` | Create/edit sheet: name TextField, content TextEditor, Save/Cancel. ⌘+Enter saves. |
| `SnippetManagerSheet.swift` | Dedicated management view: search list + detail pane + Edit/Delete. Does **not** dispatch to terminal. |
| `SnippetRowView.swift` | Reusable row: name + first-line content preview + hover `…` menu (Edit / Delete / Copy content). |

### 4.2 View hierarchy

```
MainWindow
├── HostListSidebar
├── TerminalContainerView
│   └── [new] SnippetPaletteButton in toolbar
│       └── popover content: SnippetPalette
└── (sheet) SnippetEditorSheet            ← shared component
└── (sheet) SnippetManagerSheet
                ├── embeds SnippetPalette body (without dispatch wiring)
                └── (sheet) SnippetEditorSheet (edit mode)

⌘⇧P (menu shortcut) → SnippetPalette overlay  (does not require toolbar button)
⌘⇧S (menu shortcut) → SnippetEditorSheet (create mode, empty fields)
```

### 4.3 Menu-shortcut registration

App-scoped shortcuts (only fire when Caterm is frontmost), registered as SwiftUI `CommandGroup(after: .toolbar)` items in the View menu — matching the existing `Toggle Files Drawer` pattern at `CatermApp.swift:321`:

- **View → Open Snippet Palette** — `⌘⇧P` (posts a `Notification.Name.catermOpenSnippetPalette`; observed by `MainWindow`)
- **View → New Snippet…** — `⌘⇧S` (posts `.catermNewSnippet`)
- **View → Manage Snippets…** — no default shortcut (posts `.catermOpenSnippetManager`)

The notification-broadcast pattern is used (rather than direct binding) because window-local `@State` cannot be reached from `App.commands` without threading bindings through scenes — same constraint that drove the Files-drawer choice.

If `⌘⇧P` collides with an OS or system service binding observed during implementation, fall back to `⌘'`. Final shortcut values are confirmed during implementation, not pre-committed in spec.

### 4.4 Palette interaction

- TextField auto-focused on open; type to filter.
- ↑ ↓ to navigate result list.
- `Enter` = paste; `⌘+Enter` = run; `Esc` to close.
- No active SSH session: header shows `No active terminal — connect to a host first`; `Enter`/`⌘+Enter` disabled.
- Empty store: shows `No snippets yet · ⌘⇧S to create your first snippet`; tapping triggers EditorSheet (create mode).

### 4.5 EditorSheet validation

- `name`: required, trim non-empty.
- `content`: required, non-empty (no whitespace-only).
- Save disabled until both pass.

### 4.6 Manager sheet

Three-pane: search field at top → list on left → detail on right. Detail shows full content (read-only `Text` in monospaced font) plus Edit / Delete buttons. Multi-select for batch delete (⌘-click, ⇧-click, ⌫ to delete selection).

## 5. Terminal injection (Paste vs Run)

This is the riskiest part of the design. The spec is explicit about what is unknown so the implementation plan can spike before committing.

### 5.1 What we know

- `GhosttySurface.sendText(_:)` (`Sources/TerminalEngine/GhosttySurface+IME.swift:17`) calls `ghostty_surface_text(...)`. The in-tree IME comment at `GhosttySurfaceNSView+TextInput.swift:39-43` explicitly states that routing bytes through `sendText` "would re-introduce the bracketed-paste highlight that bash 5.x readline applies to every paste-wrapped keystroke." Treat `sendText` as **paste-pathed**.
- The existing `paste_from_clipboard` binding action also produces bracketed-paste-wrapped output; that wrapping is what makes Paste mode safe (multi-line content does not auto-execute).
- `sendKey(_:composing:)` exists for synthesized keystrokes (used by the IME path with `composing: true`); it is **not** paste-wrapped.

### 5.2 Paste mode (Enter) — implementable today

```swift
extension GhosttySurface {
    func pasteSnippet(_ content: String) {
        sendText(content)
    }
}
```

Bracketed-paste wrapping is the desired behavior here. Multi-line content sits at the prompt; user inspects and presses Return when ready. No spike needed.

### 5.3 Run mode (⌘+Enter) — Task 0 spike required

**Goal:** inject `content` plus a final Return such that the shell executes it as if the user typed it. Bracketed-paste wrapping must NOT be applied.

Three candidate mechanisms in priority order:

**(A) Direct ghostty API for raw text injection.** Spike: read ghostty's public surface API surface for any function that bypasses bracketed paste (e.g., a `ghostty_surface_input(...)` or a binding action whose handler directly writes to the pty). If found, Run mode wraps it cleanly.

**(B) Per-character `sendKey` synthesis.** Spike: synthesize a sequence of `NSEvent.keyDown` instances mapping each character of `content` to a key + modifier combo, route through `surface.sendKey(_:composing:false)`, then a final synthesized `Return`. Caveats:

- IME state must be quiescent (no preedit buffer); spike verifies behavior with the IME path's `imeConsumedThisEvent` flag.
- Non-ASCII characters require careful modifier mapping or fallback to `sendText` for the body (which paste-wraps the body but still allows Run via final `sendKey(Return)` — see (B') below).
- Performance: ~1ms per char synthesized acceptable for ≤10KB snippets.

**(B′) Hybrid: `sendText(content)` + synthesized `sendKey(Return)`.** Plays paste for the body but synthesizes Return as a real keystroke. The bracketed-paste end-marker `\e[201~` appears before the Return, so readline accepts the buffered content and the Return executes it. Spike verifies this against bash, zsh, fish.

**(C) Shipping fallback.** If A and all B variants fail to produce reliable execution: ship Paste-only in v1, file a follow-up to extend ghostty (the in-tree submodule at `apps/macos/Vendor/ghostty`) with a public raw-input API, gate Run on that landing.

### 5.4 Spike acceptance criteria

The spike (Task 0 of the implementation plan) chooses a path by running this matrix:

| Test | Expected |
|---|---|
| Single-line `echo hello` against a connected SSH host (bash 5, zsh 5.9, fish 3) | Output `hello` appears, prompt advances to next line. |
| Multi-line script with `for ... do ... done` | Each line executed in shell context; loop completes. |
| Snippet containing `$(command substitution)` | Substitution evaluated by shell, not pre-expanded by terminal. |
| Snippet starting with whitespace | Whitespace preserved at prompt; `HISTCONTROL=ignorespace` still works. |
| Snippet sent while IME preedit is non-empty | No corruption of preedit; preedit cleared cleanly. |

If A passes: implement A. If A fails but B/B' pass on all three shells: implement B/B'. If neither: revert to (C) and post a one-paragraph note in the implementation plan; user re-decides v1 scope before further work.

### 5.5 Non-goals

- No "are you sure?" confirmation. Trust the user's own saved content.
- No audit log of which snippets ran on which host.
- No interpolation, expansion, or transformation of `content` — what is saved is what is sent.

### 5.6 Failure modes (post-implementation)

- **No active terminal**: palette buttons disabled, header explains. Surface-registry capture (§3.10) returned nil at open.
- **Surface released mid-flight**: weak ref nil; show transient toast `Snippet not sent — terminal not ready`; close palette.
- **`sendText`/`sendKey` returns failure**: same toast; do not retry automatically.

## 6. Testing

### 6.1 Unit / integration tests (Swift Testing or XCTest, matching surrounding modules)

| Target | Coverage |
|---|---|
| `SnippetStoreTests` | JSON encode/decode round-trip, CRUD, `@Published` emission, search filter (case-insensitive, name + content), pending-delete outbox round-trip, `wipeLocal` clears both files. |
| `SnippetSyncStoreTests` | LWW reconciliation matrix (revision <, =, > with metadataUpdatedAt and updatedAt tie-breakers), tombstone application, outbox-driven delete retry, incremental token advance, force-full path, account-switch wipe sequence (tokens cleared + local cleared + repopulate). |
| `CloudKitSyncClientSnippetTests` | `CKDatabaseProtocol` mock — fetch returns deltas, push round-trips metadata, delete propagates, subscription created idempotently, separate-zone enforcement (record IDs land in `Snippets` zone, never in `Caterm` zone). |
| `SnippetPaletteTests` | Search filtering, Enter / ⌘+Enter dispatch via captured surface (§3.10), disabled state when capture is nil, empty-store CTA, focus-loss does not change captured target. |
| `SnippetEditorSheetTests` | Required-field validation, save invokes store.upsert, cancel does not write. |

### 6.2 Manual two-Mac verification

Document at `docs/macos-snippet-sync-manual-verification.md` (mirrors Plan D's manual-verification doc). Six scenarios:

1. Single Mac: create → quit → relaunch → snippet still present.
2. Single Mac: create → edit → delete → relaunch → list reflects the final state.
3. Two Macs (Production + silent push): A creates → B sees within ~30 s (push) or by next force-full.
4. Two Macs concurrent edit: A and B edit the same snippet simultaneously; later push wins; earlier push observes server-token mismatch on its next pull and reconciles.
5. Two Macs: A deletes → B sees the snippet disappear. Offline variant: A goes airplane mode, deletes, quits, relaunches, regains network → tombstone propagates from outbox, B sees disappear.
6. iCloud account switch: log out → snippets cleared and local files emptied; log in to a different account → snippets fetched for the new account; verify previous account's snippets do not bleed in.

Scenarios 3–6 require Production CloudKit env (silent push is throttled in dev — see Plan B Phase 0/Phase 2 notes).

### 6.3 Run-mode acceptance (covers Task 0 spike)

Encoded as a manual smoke per §5.4. Must pass on bash/zsh/fish before Run mode ships. If only Paste mode ships, scenarios 3–6 still apply; the Run row in the manual doc is marked `deferred — see §5.3 fallback (C)`.

## 7. Plan integration

This work lands as **Plan F**, independent of the pending Plan E.

**Why not bundle into Plan E:**

- Plan E is scoped as cleanup + ship-readiness (SFTP bookmark sync, server-mode UI removal, three-fold pre-ship smoke). Adding a new feature widens the ship commitment and slows release.
- Snippets introduces a new CKRecord type, new zone, new subscription, new UI surface — clean boundary as its own plan.

**Cross-plan timing constraint:**

- Plan F **dev** environment work (record type creation, local dev, unit tests, Task 0 spike) can proceed in parallel with Plan E.
- Plan F **production** rollout (Deploy Schema to Production, two-Mac live verification) waits until Plan E ships, so the production CloudKit env is not perturbed during Plan E's smoke window.

**Task 0 (spike) is the first task in the implementation plan.** Its outcome may shrink the v1 feature surface (per §5.3 fallback C). All other implementation tasks should be specified in a way that is robust to either the full Run+Paste delivery or Paste-only.

## 8. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `sendText` paste-wraps and no non-wrapping API exists in current ghostty version → Run mode unimplementable. | **Medium-high** — the in-tree comment confirms `sendText` is paste-pathed. Mitigation: §5.3 spike-first with three candidate paths and a (C) fallback that ships Paste-only. |
| `⌘⇧P` collides with an OS or app-bound shortcut. | Low. §4.3 fallback `⌘'`. |
| Concurrent edits across Macs cause unexpected loss. | Inherent to LWW. §3.7 documents — same as host behavior. |
| User stores credentials in snippet `content`. | Low (explicit non-goal). §4.6 manager-sheet footer carries a one-line warning. CK transport is encrypted; field-level encryption at rest is intentionally not added (snippets are not the credential path). |
| CloudKit Dashboard schema misconfiguration silently breaks fetch. | Low. §3.12 checklist + §6.2 scenario 3. |
| `ensureSnippetSubscription` over-creates subscriptions on app relaunch. | Low. Idempotent by subscription ID, same pattern as `ensureHostSubscription`. |
| Snippet zone token gets stuck after unrecoverable record corruption. | Low. Force-full safety net (§3.11 60-min) recovers; manual `Reset Sync State` debug command can also be wired if needed. |
| Outbox grows unbounded if pushes consistently fail. | Very low. §3.8 retries on every sync pass; size capped by user delete behavior. If a runaway is observed, add a max-age TTL in a follow-up. |
| Surface-registry weak refs leak or never resolve. | Low. §3.10 weak; nil resolution gracefully degrades to disabled palette + toast. |

## 9. Open questions for implementation

These are deliberately deferred to the implementation plan, not blockers for this design:

- Final menu-shortcut values (`⌘⇧P` / `⌘⇧S` vs alternatives) — confirmed during implementation.
- Precise layout coordinates of the toolbar Snippet button inside `TerminalContainerView`.
- Whether `SnippetEditorSheet` should offer monospaced vs system font for the content editor (likely monospaced; confirm by feel).
- Whether to instantiate a parameterized second `UserDefaultsServerChangeTokenStore` or write a sibling `UserDefaultsSnippetChangeTokenStore` (§3.5) — minor implementation detail.
- Run-mode mechanism — settled by Task 0 spike (§5.3).
