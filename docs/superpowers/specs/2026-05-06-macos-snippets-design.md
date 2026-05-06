# macOS Snippets — Design Spec

**Date:** 2026-05-06
**Target app:** `apps/macos/`
**Status:** Design accepted; implementation pending (proposed Plan F, see §7).

## 1. Goal

Let the user save reusable command/script snippets and inject them into the active SSH terminal as either a **Paste** (non-destructive — content sits at the prompt for the user to inspect/edit) or **Run** (executed immediately). Snippets sync across the user's Macs via CloudKit.

## 2. Scope

### In scope (v1)

- Plain-text snippets: a `name` and a multi-line `content` string.
- A reserved `placeholders` field on the schema so future variable-substitution support does not require CloudKit schema migration.
- Flat list with substring search across `name` and `content` (case-insensitive).
- Two trigger surfaces:
  - Command palette via global hotkey `⌘⇧P`.
  - Toolbar button on the terminal pane (popover with the same palette body).
- Quick create via global hotkey `⌘⇧S`.
- Dedicated management sheet via `View → Manage Snippets…`.
- CloudKit per-record sync using the `HostSyncStore` pattern (incremental token, tombstones, force-full safety net, account-switch wipe).

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

### 3.1 New SwiftPM target

`apps/macos/Sources/SnippetStore/` — new target on the same level as `HostSyncStore`, `SettingsSyncStore`, `FileTransferStore`. Holds:

- `Snippet` model.
- `SnippetStore` (`@Published var snippets: [Snippet]`, JSON persistence).
- `SnippetSyncStore` (sync coordinator — pull/push loop, LWW reconciliation, tombstone handling).

### 3.2 Data model

```swift
public struct Snippet: Identifiable, Codable, Equatable, Hashable {
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

Local persistence: `~/Library/Application Support/Caterm/snippets.json` (sibling of `hosts.json`). Atomic write via temp-file + rename, identical to the host store.

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
       ▲                     ▲
       │ apply pulled deltas │ user mutations
       │                     │
SnippetSyncStore ────────────┘
       │
       │ uses
       ▼
CloudKitSyncClient (existing, +4 new methods on Snippet record type)
```

### 3.5 New `CloudKitSyncClient` methods

```swift
func fetchSnippetChanges(since: CKServerChangeToken?) async throws
    -> (snippets: [Snippet], tombstones: [UUID], newToken: CKServerChangeToken?)

func pushSnippet(_ snippet: Snippet) async throws -> Snippet
// Returns the snippet with metadataUpdatedAt and revision back-filled
// from the server modification metadata.

func deleteSnippet(id: UUID) async throws
// Hard delete + tombstone push.

func ensureSnippetSubscription() async throws
// Mirrors ensureHostSubscription from Plan B Phase 2.
```

### 3.6 LWW reconciliation

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

### 3.7 Sync triggers

| Trigger | Path |
|---|---|
| App launch | `syncIfSignedIn()` runs incremental fetch using persisted `CKServerChangeToken`. |
| Local edit | Debounce 500 ms, then `pushSnippet`. Coalesces rapid edits. |
| Remote push (silent push) | APS `parsePushUserInfo` dispatch (`AppDelegate` adds case `.snippet` alongside the existing `.host` case). |
| 60-min force-full safety net | Reuses the existing timer in `HostSyncStore`. Both stores tick on the same cadence. |
| iCloud account change | `.catermICloudAccountChanged` → `accountSwitchHandler` wipes local snippets (snippets are user content; never bleed across accounts). |

### 3.8 Out-of-band CloudKit Dashboard setup

Required once per environment (Development + Production). **Cannot be automated — requires Apple Developer console.**

1. CloudKit Dashboard → Container `iCloud.com.caterm.app` → Schema → Record Types → New.
2. Name: `Snippet`. Fields per §3.3.
3. Indexes: `recordName` Queryable; `updatedAt` Queryable + Sortable.
4. (Subscriptions are created at runtime via `ensureSnippetSubscription`, not in schema.)
5. After dev verification: Deploy Schema to Production.

This step blocks live verification but not local development.

## 4. UI

### 4.1 Files (new)

`apps/macos/Sources/Caterm/Views/Snippets/`:

| File | Responsibility |
|---|---|
| `SnippetPalette.swift` | Search field + result list + Enter / ⌘+Enter dispatch. Used both as the `⌘⇧P` palette and as the toolbar-button popover body. |
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
                ├── embeds SnippetPalette body (without hotkey wiring)
                └── (sheet) SnippetEditorSheet (edit mode)

⌘⇧P → SnippetPalette overlay  (does not require toolbar button)
⌘⇧S → SnippetEditorSheet (create mode, empty fields)
```

### 4.3 Hotkey registration

Both hotkeys are SwiftUI `CommandMenu` items under a new **`View → Snippets`** menu group:

- **Open Snippet Palette** — `⌘⇧P`
- **New Snippet…** — `⌘⇧S`
- **Manage Snippets…** — no default hotkey

Using `CommandMenu` rather than a global `NSEvent` monitor:

- Surfaces the feature in the menu bar (discoverability).
- Lets users rebind via macOS System Settings → Keyboard → Shortcuts → App Shortcuts.
- Avoids IME and focus edge cases that come with a low-level monitor.

If `⌘⇧P` collides with an OS-level binding observed during implementation, fall back to `⌘'`. The spec is hotkey-agnostic past the point that the menu commands exist.

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

Three-pane: search field at top → list on left → detail on right. Detail shows full content (read-only `Text` in monospaced font) plus Edit / Delete buttons. Multi-select for batch delete (⌘-click, ⇧-click).

## 5. Terminal injection

Both paths terminate at `GhosttySurface.sendText(_:)` (defined at `apps/macos/Sources/TerminalEngine/GhosttySurface+IME.swift:17`). The differentiator is the surrounding bracketed-paste behavior.

### 5.1 Paste mode (Enter)

```swift
extension GhosttySurface {
    func pasteSnippet(_ content: String) {
        sendText(content)
    }
}
```

Expected behavior: when the remote shell has bracketed paste enabled (default in modern bash/zsh/fish), the content arrives wrapped in `\e[200~ ... \e[201~` and sits at the prompt — embedded `\n` characters do **not** auto-execute. The user inspects, edits, and presses Return when ready.

> **Implementation-time check (not a design decision):** verify whether a bare `sendText` already produces the bracketed-paste wrapping or whether the wrapping only happens on the existing `paste_from_clipboard` path (`GhosttySurfaceNSView+ContextMenu.swift:24`). If `sendText` does **not** wrap, route Paste mode through the same `paste_from_clipboard` action via a clipboard hand-off (write to a private pasteboard, trigger the binding action, restore). The choice is hidden from the design — only the user-visible behavior matters.

### 5.2 Run mode (⌘+Enter)

```swift
func executeSnippet(_ content: String) {
    let payload = content.hasSuffix("\n") ? content : content + "\n"
    sendText(payload)
}
```

Bypasses bracketed paste deliberately — equivalent to "user types content + presses Return". Multi-line content is interpreted line-by-line by the shell unless the user wrote shell-level continuations (`\`, heredocs).

### 5.3 Targeting the active terminal

The palette resolves the target `GhosttySurface` from the currently focused terminal tab in `MainWindow`. If there is no active session (no host connected, or the host pane is reconnecting):

- Buttons disabled (greyed out).
- A status string in the palette header explains why.

If the surface releases mid-flight (reconnect window race), the send is silently dropped and a transient toast surfaces: `Snippet not sent — terminal not ready`.

### 5.4 Non-goals

- No "are you sure?" confirmation. Trust the user's own saved content.
- No audit log of which snippets ran on which host.
- No interpolation, expansion, or transformation of `content` — what is saved is what is sent.

## 6. Testing

### 6.1 Unit / integration tests (Swift Testing or XCTest, matching surrounding modules)

| Target | Coverage |
|---|---|
| `SnippetStoreTests` | JSON encode/decode round-trip, CRUD, `@Published` emission, search filter (case-insensitive, name + content). |
| `SnippetSyncStoreTests` | LWW reconciliation matrix (revision <, =, > with metadataUpdatedAt and updatedAt tie-breakers), tombstone application, incremental token advance, force-full path, account-switch wipe. |
| `CloudKitSyncClientSnippetTests` | `CKDatabaseProtocol` mock — fetch returns deltas, push round-trips metadata, delete propagates, subscription created idempotently. |
| `SnippetPaletteTests` | Search filtering, Enter / ⌘+Enter dispatch, disabled state when no active session, empty-store CTA. |
| `SnippetEditorSheetTests` | Required-field validation, save invokes store.upsert, cancel does not write. |

### 6.2 Manual two-Mac verification

Document at `docs/macos-snippet-sync-manual-verification.md` (mirrors Plan D's manual-verification doc). Six scenarios:

1. Single Mac: create → quit → relaunch → snippet still present.
2. Single Mac: create → edit → delete → relaunch → list reflects the final state.
3. Two Macs (Production + silent push): A creates → B sees within ~30 s (push) or by next force-full.
4. Two Macs concurrent edit: A and B edit the same snippet simultaneously; later push wins; earlier push observes server-token mismatch on its next pull and reconciles.
5. Two Macs: A deletes → B sees the snippet disappear.
6. iCloud account switch: log out → snippets cleared; log in to a different account → snippets fetched for the new account.

Scenarios 3–6 require Production CloudKit env (silent push is throttled in dev — see Plan B Phase 0/Phase 2 notes).

## 7. Plan integration

This work lands as **Plan F**, independent of the pending Plan E.

**Why not bundle into Plan E:**

- Plan E is scoped as cleanup + ship-readiness (SFTP bookmark sync, server-mode UI removal, three-fold pre-ship smoke). Adding a new feature widens the ship commitment and slows release.
- Snippets introduces a new CKRecord type, new subscription, new UI surface — clean boundary as its own plan.

**Cross-plan timing constraint:**

- Plan F **dev** environment work (record type creation, local dev, unit tests) can proceed in parallel with Plan E.
- Plan F **production** rollout (Deploy Schema to Production, two-Mac live verification) waits until Plan E ships, so the production CloudKit env is not perturbed during Plan E's smoke window.

## 8. Risk register

| Risk | Mitigation |
|---|---|
| `sendText` already adds bracketed-paste wrapping → Run mode would not auto-execute. | §5.1 implementation-time check. If true, Run drops the wrap; Paste keeps using `sendText` as-is. |
| `⌘⇧P` collides with an OS or Ghostty-bound shortcut. | §4.3 fallback `⌘'`. Final value chosen during implementation. |
| Concurrent edits across Macs cause unexpected loss. | LWW is documented in §3.6 — last write wins, matches host behavior; users already familiar. |
| User stores credentials in snippet `content`. | §2 explicit non-goal; §4.6 management page footer carries a one-line warning. Snippets travel through CloudKit's data plane unencrypted-at-app-layer (CK transport encryption applies). |
| CloudKit Dashboard schema misconfiguration silently breaks fetch. | §3.8 checklist + a smoke step in §6.2 scenario 3. |
| `ensureSnippetSubscription` over-creates subscriptions on app relaunch. | Idempotent by subscription ID, same pattern as `ensureHostSubscription` already in tree. |

## 9. Open questions for implementation

These are deliberately deferred to the implementation plan, not blockers for this design:

- Final hotkey values (`⌘⇧P` / `⌘⇧S` vs alternatives).
- Precise layout coordinates of the toolbar Snippet button inside `TerminalContainerView`.
- Whether `SnippetEditorSheet` should offer monospaced vs system font for the content editor (likely monospaced; confirm by feel).
- Whether the manager sheet's multi-select supports keyboard ⌫ for batch delete.
