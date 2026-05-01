# Terminal Settings GUI + Theme Picker — Design Spec

**Status:** Draft v3 (revised after second review 2026-05-01)
**Date:** 2026-05-01
**Scope:** macOS app (`apps/macos/`) only.

---

## 1. Goal

Replace the current "⌘, opens config in Finder" behavior with a proper macOS Preferences window covering Font, Cursor, Bell, Scrollback, Window, and Theme settings. Add a theme picker (bundled theme catalog with 9 curated favorites). Support **per-host theme override** (other fields are global only in v1).

## 2. Architecture

### 2.0 Config file format (NOT TOML)

Ghostty uses its own line-based configuration syntax, not TOML. The default file `font-family = SF Mono` (`ConfigStore.swift:8`) would fail TOML parsing because `SF Mono` is unquoted. The high-level shape (sufficient to scope this spec; the canonical parser is Ghostty itself):

```
ghostty-config := { line }
line           := comment | blank | entry
comment        := '#' { any } NL
entry          := key WS? '=' WS? value NL
key            := [a-z][a-z0-9-]*
value          := <free-form text up to NL; some keys (theme, palette, font-family, …)
                   accept optional outer double-quotes that the parser strips, and some
                   accept comma-separated sub-fields. The exact tokenization is
                   delegated to GhosttyConfigParser (§2.0.1).>
```

Notable real-world cases observed via `ghostty +show-config --default`:
- `foreground = #ffffff` (plain unquoted)
- `selection-word-chars = … ` followed by literal punctuation including `'"`
- `command-palette-entry = title:"Change Tab Title…",description:"…",action:"…"` (inner quoting as part of value semantics)
- `font-family = ` (empty value)
- Repeated `font-family = X` lines build a fallback chain (multi-value semantics)
- `theme = light:Catppuccin Latte,dark:Catppuccin Mocha` (system-appearance switching)

#### 2.0.1 GhosttyConfigParser

A small Swift utility (single file in the `ConfigStore` target, ~120 LOC) responsible for:

- **Reading**: tokenize a config file into `[ConfigEntry { key, rawValue, sourceLine }]`. Comments and blank lines are dropped. Outer double-quotes around `rawValue` are stripped if present (matches Ghostty's tolerant behavior). Repeated keys are preserved in order (callers decide whether to merge or treat as multi-value).
- **Writing**: emit entries with idiomatic spacing (`key = value`, no quotes unless the original had them and we're preserving). The renderer emits unquoted values; users round-trip whatever they typed.
- **Lossless edit**: when removing a specific key from an existing user config (Branch B migration), preserve all other lines, comments, blank lines, and ordering byte-for-byte.

The parser is **not** a full Ghostty config validator. It is deliberately tolerant: unrecognized keys pass through unchanged. Invalid Ghostty-side semantics surface only when libghostty's own parser produces diagnostics (§2.4.2). This avoids divergence between Caterm's understanding and Ghostty's.

All Caterm code that reads or writes these files (`SettingsRenderer`, `SettingsMigrationStep`, `ThemeCatalogBuilder`) goes through `GhosttyConfigParser` — never a TOML parser. Tests fixture against `ghostty +show-config --default` output captured at a known version.

### 2.1 Current state of config layering (verified)

The codebase today (`apps/macos/Sources/ConfigStore/ConfigStore.swift`) maintains two distinct files:

| File | Role | Current contents |
|---|---|---|
| `~/Library/Application Support/Caterm/config` (user config) | Seeded on first launch via `defaultConfig`; user edits freely | `font-family = SF Mono`, `font-size = 13`, `theme = Catppuccin Mocha`, `cursor-style = block`, `macos-titlebar-style = tabs` |
| `~/Library/Application Support/Caterm/caterm-managed.config` (managed snapshot) | Caterm-owned, written by `ConfigStore.writeManagedConfig()` | `term = xterm-256color`, 6× scroll/clear keybinds (⌘↑/⌘↓/⌘⇞/⌘⇟/⌘home/⌘end/⌘k) |

`Sources/TerminalEngine/GhosttyConfig.swift` loads them in this order:

```
ghostty_config_load_default_files(cfg)            // ghostty defaults
ghostty_config_load_file(cfg, managedPath)        // term + keybinds
ghostty_config_load_file(cfg, userPath)           // user config — wins
ghostty_config_finalize(cfg)
```

**Critical implication:** because user config wins, and the seeded default user config already contains font/theme/cursor/titlebar lines, simply moving GUI writes into the managed snapshot **will be silently overridden** on every existing install. Section 8 details the migration that solves this.

### 2.2 New persistence: Caterm-owned plist + rendered managed snapshot

```
[Ghostty defaults]
        ↓
[managed snapshot]        ← Ghostty config syntax; rewritten on every settings change; contains:
                              • the legacy term + keybind block (preserved)
                              • the new fields rendered from settings.plist (font, cursor, bell, scrollback, window, theme, macos-titlebar-style)
        ↓
[user config]              ← unchanged for new fields; existing customizations preserved
        ↓
[per-host patch file]     ← optional, only for the surface; written when host has theme override
```

- New file: `~/Library/Application Support/Caterm/settings.plist` (Codable, Caterm-owned).
- `ConfigStore` is extended to render `settings.plist` into the managed snapshot on every write.
- The user config file is no longer edited by Caterm after the migration (§8).
- Per-host theme override loads as an additional file **after** user config, scoped to the surface only — see §2.4.

### 2.3 Settings schema (Codable)

```swift
public struct CatermSettings: Codable, Equatable {
    public var version: Int                   // schema version, starts at 1
    public var revision: String               // ULID-like token; bumps on any change
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
    public var migrationsCompleted: Set<String>  // e.g. ["settings-gui-v1"]; tracks one-shot
                                                 //   migrations like the user-config rewrite
                                                 //   in §8. Persists in plist alongside data.
}

public struct PartialSettings: Codable, Equatable {
    public var fontFamily: String?            // system monospaced fonts only
    public var fontSize: Int?                 // 8..32
    public var lineHeight: Double?            // 0.8..2.0  → adjust-cell-height (% form)
    public var cursorStyle: CursorStyle?      // .block | .bar | .underline
    public var cursorBlink: Bool?
    public var bell: BellMode?                // .none | .audio | .visual | .both
    public var scrollbackBytes: Int?          // memory budget; default 10_000_000 (10 MB)
                                              // Ghostty's scrollback-limit is bytes, not lines
                                              // and only takes effect on new surfaces (per docs)
    public var windowOpacity: Double?         // 0.7..1.0
    public var windowPaddingX: Int?
    public var windowPaddingY: Int?
    public var titlebarStyle: TitlebarStyle?  // .tabs | .transparent | .native | .hidden
                                              // → macos-titlebar-style; required to preserve
                                              // existing default's `macos-titlebar-style = tabs`
    public var theme: String?                 // theme name (matches bundled catalog)
}
```

In v1 only `theme` is read from `hostOverrides[hostId]`; other fields in `PartialSettings` exist for future use (data model permits expansion without migration).

### 2.4 Live reload pipeline (using actual GhosttyKit API)

The framework header (`Frameworks/GhosttyKit.xcframework/.../ghostty.h`) exposes:

```
ghostty_config_t ghostty_config_new();                                    // line 1069
void ghostty_config_load_default_files(ghostty_config_t);                 // line 1074
void ghostty_config_load_file(ghostty_config_t, const char*);             // line 1073
void ghostty_config_finalize(ghostty_config_t);                           // line 1076
uint32_t ghostty_config_diagnostics_count(ghostty_config_t);              // line 1081
ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t,      // line 1082
                                                   uint32_t);
void ghostty_config_free(ghostty_config_t);                               // line 1070
void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);          // line 1095 — VOID
void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);  // line 1108 — VOID
```

Note: `ghostty_surface_reload_config` and `ghostty_config_load_string` (mentioned in v1 spec) **do not exist**. Reload goes through new-config construction. Both `update_config` calls return `void`, so success/failure must be detected via the **diagnostics API** before the apply, not via return value.

#### 2.4.1 Settings-change scope (field-aware)

Not every field can live-reload. Per Ghostty docs:
- `scrollback-limit` — "can be changed at runtime but will only affect new terminal surfaces"
- `macos-titlebar-style` — only affects new windows (NSWindow style is set at construction)

So a single `.global` scope that always broadcasts `surface_update_config` is wrong. We classify each field at compile time:

```swift
public enum FieldReloadKind {
    case live          // surface_update_config picks up the change immediately
    case newSurface    // takes effect only on next ghostty_surface_new
}

// Static map maintained alongside SettingsRenderer. Single source of truth.
let liveReloadable: [PartialSettingsKeyPath: FieldReloadKind] = [
    \.fontFamily:       .live,
    \.fontSize:         .live,
    \.lineHeight:       .live,
    \.cursorStyle:      .live,
    \.cursorBlink:      .live,
    \.bell:             .live,
    \.windowOpacity:    .live,
    \.windowPaddingX:   .live,
    \.windowPaddingY:   .live,
    \.theme:            .live,
    \.scrollbackBytes:  .newSurface,
    \.titlebarStyle:    .newSurface,
]
```

`SettingsChangeScope` is computed from the diff between the old and new `settings.plist` by `SettingsStore` before posting:

```swift
public enum SettingsChangeScope {
    case globalLive          // ≥1 changed field is .live
    case globalNewSurface    // all changed fields are .newSurface only
    case hostOverride(HostId)
}
```

`SettingsStore` posts `Notification.Name.catermSettingsChanged` with the scope in `userInfo`. Listeners apply:

| Scope | Action |
|---|---|
| `.globalLive` | Render new managed snapshot. Build new config + call `surface_update_config` for every open surface. Newly-created surfaces also see the change. |
| `.globalNewSurface` | Render new managed snapshot. **No** `surface_update_config` calls. Show a one-time non-modal banner: "Some settings (scrollback / titlebar) apply to new tabs only." |
| `.hostOverride(id)` | Write/delete the per-host patch file at `~/Library/Application Support/Caterm/per-host/<id>.config` (see §2.4.3 for storage rationale and boot regeneration). **No** `surface_update_config` on existing surfaces (existing tabs keep their current theme until reconnect, per Q4a). New surfaces to that host pick up the patch via §2.4.3. |

If a single user action changes both live and new-surface fields (debounced together), scope is `.globalLive` (covers both: live fields apply now, new-surface fields take effect on next `surface_new`).

This explicit scoping resolves three conflicts in the original §2.4: scrollback-as-live-reload, titlebar-as-live-reload, and per-host-as-broadcast.

#### 2.4.2 Reload sequence (scope = `.global`)

1. `SettingsStore.update(...)` writes plist + bumps revision.
2. `ConfigStore.renderManagedSnapshot(from: settings.global)` rewrites the managed snapshot file.
3. Build a fresh `ghostty_config_t`:
   ```
   cfg = ghostty_config_new()
   ghostty_config_load_default_files(cfg)
   ghostty_config_load_file(cfg, managedPath)
   ghostty_config_load_file(cfg, userPath)
   ghostty_config_finalize(cfg)
   ```
4. **Pre-apply validation:** call `ghostty_config_diagnostics_count(cfg)`. If > 0, iterate `ghostty_config_get_diagnostic(cfg, i)` for `i in 0..<count`, collecting each diagnostic's `message` field. The `ghostty_diagnostic_s` struct (header lines 397-401) **contains only `message`** — there is no severity field exposed. All diagnostics are surfaced together in a non-modal banner ("Configuration warnings: <bullet list>"); the apply still proceeds because Ghostty already finalized the config to a usable state (offending fields fall back to defaults internally). If a future GhosttyKit version adds severity, `ConfigDiagnostic.parse(_:)` is the single point to update.
5. `ghostty_app_update_config(app, cfg)` — updates the app-level baseline.
6. For each open `GhosttySurfaceNSView`, build a per-surface `cfg2` (cloning the global build path, plus per-host patch if `hostOverrides[surface.hostId]?.theme` is present), then `ghostty_surface_update_config(surface, cfg2)`. Free `cfg2` after the call.
7. Free the global `cfg` once all surfaces are updated.

#### 2.4.3 Reload sequence (scope = `.hostOverride(id)`) and per-host patch application

**Storage location.** Per-host patch files live in **Application Support**, not Caches:
`~/Library/Application Support/Caterm/per-host/<id>.config`. Reason: macOS cleans `~/Library/Caches/` opportunistically (and on iCloud syncing settings, can wipe it), but the source of truth is `settings.plist`, so a wiped cache would silently restore "no override" for hosts whose plist still has a theme. Application Support is where Caterm already keeps `settings.plist`; using the same root keeps backup/restore semantics consistent.

**Boot regeneration (idempotent).** On every app start, after `SettingsStore.load()` succeeds, `SettingsStore.regeneratePerHostPatchesFromPlist()` is called:
1. For each `(hostId, override)` in `settings.hostOverrides` where `override.theme != nil`: write/overwrite the patch file deterministically.
2. Delete any patch file in `per-host/` whose hostId is not in `settings.hostOverrides` (orphan cleanup).
This guarantees the on-disk patches always reflect the plist, even after manual deletes, file-system corruption, or `xattr` quarantine.

**On settings change:**
1. `SettingsStore.update(...)` writes plist + bumps revision.
2. Compute new value:
   - If `settings.hostOverrides[id]?.theme` is non-nil, write `~/Library/Application Support/Caterm/per-host/<id>.config` containing exactly one line: `theme = <name>` (Ghostty config syntax).
   - Else, delete the file if present.
3. **No surface_update_config calls** for existing surfaces.

**Applying the per-host patch on new surfaces (current architecture)**

`GhosttyApp.shared` (`Sources/TerminalEngine/GhosttyApp.swift:27`) holds a single process-level `ghostty_app_t` configured with the global chain (defaults → managed → user). `ghostty_surface_new` (`Sources/TerminalEngine/GhosttySurface.swift:137`) creates surfaces from that app handle and currently has no point at which a per-host config is mixed in.

Rather than restructuring the surface-creation path, we apply the per-host patch immediately *after* surface creation:

1. `GhosttySurface.init(host:)` calls `ghostty_surface_new(GhosttyApp.shared.raw, &surfaceConfig)` (unchanged).
2. If `settings.hostOverrides[host.id]?.theme` exists at construction time:
   - Build a host-scoped `ghostty_config_t` mirroring the §2.4.2 chain plus `ghostty_config_load_file(perHostPatchPath)`.
   - Call `ghostty_surface_update_config(handle, hostCfg)` immediately.
   - Free `hostCfg`.
3. The user briefly (single frame) sees the global theme before the host theme applies. Acceptable trade-off; alternative (refactoring `GhosttySurface` to accept a custom config in `surface_new`) is a larger change deferred to a separate spec.

Implementation notes:
- The patch file is loaded *after* user config in the chain, matching §2.4.4 precedence.
- If GhosttyKit later exposes a way to pass per-surface config to `surface_new`, this two-step apply collapses naturally.

#### 2.4.4 Per-host theme override precedence

The per-host file loads **after** user config, so a host override does override a `theme = ...` line in user config. Rationale: per-host override is an explicit per-host action by the user via GUI; treating it as the highest-precedence layer matches user intent. Other settings categories (font, cursor, etc.) have no per-host layer in v1 and continue to honor "user config wins".

## 3. UI Components

### 3.1 Preferences window (`PreferencesWindowController`)

Standard NSWindow + Toolbar with tabs:

```
┌───────────────────────────────────────────┐
│ ⚙️ General  📺 Terminal  🎨 Themes  ☁ Sync │
├───────────────────────────────────────────┤
│                                           │
│         (active tab content)              │
│                                           │
└───────────────────────────────────────────┘
```

- Replaces `AppDelegate.openSettings()` (currently opens Finder).
- ⌘, opens this window. ⌘W closes it.
- Window saves frame to UserDefaults (`PreferencesWindowFrame`).
- Each tab is a SwiftUI view embedded via `NSHostingController`.

### 3.2 Tab: General (v1 placeholder)

Empty for v1. Renders a "Coming soon" placeholder; do not ship visible empty controls.

### 3.3 Tab: Terminal (`TerminalSettingsView`)

```
Font
  Family       [Dropdown: SF Mono ▾]    (system monospaced fonts only)
  Size         [Stepper: 13]   ◀━━━━●━━━▶
  Line height  ━━━━●━━━━━  1.0  (0.8–2.0)

Cursor
  Style        [Block | Bar | Underline]   (segmented)
  Blink        ☐

Bell
  Mode         [None | Audio | Visual | Both]   (segmented)

Scrollback
  Memory       [Stepper: 10 MB]   (1–500 MB; applies to new tabs only)

Window
  Opacity      ━━━━━━●━  0.95
  Padding X    [Stepper: 4]
  Padding Y    [Stepper: 4]

──────────────────────────────────────────
[Edit Advanced Config…]   3 user-config overrides active
```

The "Edit Advanced Config" button opens user config in Finder (preserves the previous ⌘, behavior). The hint count counts user-config keys (parsed via `GhosttyConfigParser`) that are *also* in `PartialSettings` (i.e. would be overridden by GUI changes) — gives users a heads-up when their user config is shadowing the GUI.

### 3.4 Tab: Themes (`ThemePickerView`)

```
[ Search themes…                           ]

Favorites
  ┌─────────┐ ┌─────────┐ ┌─────────┐
  │ Default │ │ Dracula │ │ One Dark│
  │ ▮▮▮▮▮▮  │ │ ▮▮▮▮▮▮ │ │ ▮▮▮▮▮▮ │   ← color swatches preview
  └─────────┘ └─────────┘ └─────────┘
   …(9 cards: Default, Dracula, One Dark, Solarized {Dark,Light},
     Monokai, Nord, Gruvbox {Dark,Light})

All Themes  (300+)
  ┌─────────┐ ┌─────────┐ ...
```

- **Source: bundled catalog generated at build time from the Ghostty submodule.** Not a runtime CLI call.
- Each card shows ANSI color swatches (parsed from theme files at build time, stored as RGB tuples) + name.
- Click → set as global theme + live reload.
- Search filters the "All Themes" grid (favorites always visible above the fold).

**Build-time pipeline.** The exact location of theme files inside the Ghostty submodule is **not stable across upstream releases** (the path `Vendor/ghostty/resources/themes/` claimed by an earlier draft does not exist; themes are emitted under `zig-out/share/ghostty/themes/` after a `zig build install`, or live in the source under different paths in different versions). The pipeline therefore *discovers* themes at build time:

1. `Scripts/build-theme-catalog.sh` runs as part of `make macos-ghostty-kit` after `make macos-ghostty-submodule` initializes `Vendor/ghostty/`. The build of GhosttyKit (`build-libghostty.sh`) already runs `zig build` which populates `zig-out/`.
2. The script searches for theme files under `Vendor/ghostty/` using a fixed list of candidate roots (in order):
   - `Vendor/ghostty/zig-out/share/ghostty/themes/`
   - `Vendor/ghostty/zig-out/themes/`
   - `Vendor/ghostty/src/config/themes/` (older versions)
   - `Vendor/ghostty/pkg/iterm2-themes/themes/` (git-subtree fallback)
   The first directory containing recognizable theme files (parseable `palette = N=#rgb` lines) wins. The chosen path is logged to stderr at build time so it surfaces in CI on regression.
3. Each file is parsed via `GhosttyConfigParser` (§2.0.1). We extract: `palette = N=#rgb` (16 entries), `background`, `foreground`, `cursor-color`, `selection-background`.
4. Output: `Sources/SettingsStore/Resources/themes.json` with `{ name, palette: [hex×16], background, foreground, cursorColor?, selectionBackground? }` per theme. Theme name = file's basename (no canonicalization), so it round-trips into `theme = <name>` exactly as Ghostty expects.
5. Bundle is loaded once at app start into an in-memory `ThemeCatalog` actor.

**Fallback when discovery fails.** If no candidate root contains parseable themes, the build emits a non-fatal warning and writes `themes.json` from a small **vendored** fallback set (nine theme files committed directly into `Sources/SettingsStore/Resources/fallback-themes/`) so development builds without an initialized submodule still produce a usable app.

**Favorites list — verified against actual Ghostty catalog.** The names below are the **exact** names returned by `ghostty +list-themes` (verified locally against Ghostty 1.3.x; the v3 spec list contained `Default`, `One Dark`, `Solarized Dark`, `Solarized Light`, and bare `Monokai`, which are **not** in the catalog under those exact names):

| # | Display name (favorites tab) | Exact Ghostty theme name |
|---|---|---|
| 1 | Catppuccin Mocha (matches current managed-config default) | `Catppuccin Mocha` |
| 2 | Catppuccin Latte | `Catppuccin Latte` |
| 3 | Dracula | `Dracula` |
| 4 | Gruvbox Dark | `Gruvbox Dark` |
| 5 | Gruvbox Light | `Gruvbox Light` |
| 6 | Nord | `Nord` |
| 7 | One Dark Two | `One Dark Two` |
| 8 | Solarized Dark Higher Contrast | `Solarized Dark Higher Contrast` |
| 9 | Monokai Classic | `Monokai Classic` |

`ThemeCatalog.favorites: [String]` holds these nine names. If the build-time catalog is missing any (upstream rename/removal), the missing entry is silently dropped from the favorites grid. `ThemeCatalogTests.testFavoritesPresentInCatalog` asserts the build emits all nine when run against the pinned Ghostty version in the submodule.

### 3.5 Tab: Sync (existing `SyncSettingsView`)

Migrate the current sheet into this tab. Functionality unchanged.

### 3.6 Per-host theme override UI

In existing `HostFormView`, append a section:

```
Theme Override
  [Use global ▾]          ← dropdown: "Use global" + theme list
```

When set to anything other than "Use global", the host stores `hostOverrides[hostId].theme = "..."`. Cleared → entry deleted from `hostOverrides`.

Effect timing per §2.4: new tabs use the override; existing tabs keep their current theme until reconnect.

## 4. Module Layout

```
Sources/
├─ ConfigStore/
│   ├─ ConfigStore.swift                    ← MODIFIED: render from settings; preserve term+keybinds
│   └─ SettingsRenderer.swift               ← NEW: PartialSettings → Ghostty config lines
├─ SettingsStore/                           ← NEW target
│   ├─ SettingsStore.swift                  (ObservableObject; load/save plist; debounce)
│   ├─ CatermSettings.swift                 (Codable schema)
│   ├─ PartialSettings.swift                (field-level types and ranges)
│   ├─ ThemeCatalog.swift                   (loads bundled themes.json; favorites list)
│   └─ Resources/
│       └─ themes.json                      ← generated at build time
├─ Caterm/Views/
│   ├─ Preferences/                         ← NEW
│   │   ├─ PreferencesWindowController.swift
│   │   ├─ TerminalSettingsView.swift
│   │   ├─ ThemePickerView.swift
│   │   ├─ ThemeCardView.swift
│   │   └─ GeneralSettingsView.swift        (placeholder)
│   ├─ HostFormView.swift                   ← MODIFIED: add theme override picker
│   └─ SyncSettingsView.swift               ← MOVED to Preferences tab; remove sheet entry
├─ Caterm/AppDelegate.swift                 ← MODIFIED: ⌘, opens PreferencesWindow
└─ TerminalEngine/
    └─ GhosttyConfig.swift                  ← MODIFIED: support reload + per-host patch path
Scripts/
└─ build-theme-catalog.sh                   ← NEW: parses Vendor/ghostty themes into JSON
```

## 5. Data Flow Detail

### 5.1 Read path (boot)

1. `SettingsStore.load()` reads `settings.plist`. If absent → seed defaults using values that match the **current** observed defaults in production (SF Mono, size 13, theme Catppuccin Mocha, block cursor) so an empty plist produces no visual change.
2. `MigrationStep.runIfNeeded()` (§8) executes once per install version; may rewrite user config and seed `settings.plist`.
3. `ConfigStore.renderManagedSnapshot(from: settings.global)` writes the managed snapshot — **always preserving the existing `term` + scrollback keybinds block** (Section 6.4).
4. `ThemeCatalog.load()` reads bundled `themes.json` into memory.
5. Ghostty surfaces are constructed with the standard config chain.

### 5.2 Write path (user edits in Preferences)

1. UI action mutates `SettingsStore.settings.global.<field>` (or `hostOverrides[id].theme`).
2. Store debounces 200ms then:
   - Bumps `revision` (ULID).
   - Persists plist atomically (`.write(to:options:.atomic)`).
   - Triggers `ConfigStore.renderManagedSnapshot(from: ...)`.
   - Posts `.catermSettingsChanged` notification.
3. Listening surfaces run §2.4 reload sequence.

### 5.3 Per-host theme resolution (new tab opened)

```swift
let effectiveTheme = settings.hostOverrides[hostId]?.theme   // wins if present
                  ?? userConfigTheme                           // legacy support
                  ?? settings.global.theme                     // GUI baseline
                  ?? "Catppuccin Mocha"                        // ultimate fallback
```

The patch file written for the surface contains only the `theme` line when a host override is set; absence of the file means "use the chain as-is" (and resolution above happens implicitly via the loaded config files).

## 6. Field → Ghostty config mapping

| Schema field | Ghostty config key | Notes |
|---|---|---|
| `fontFamily` | `font-family` | dropdown enforces system monospaced fonts |
| `fontSize` | `font-size` | integer 8..32 |
| `lineHeight` | `adjust-cell-height` | percent string: `1.1` → `10%`, `0.9` → `-10%` |
| `cursorStyle` | `cursor-style` | `block` / `bar` / `underline` |
| `cursorBlink` | `cursor-style-blink` | bool |
| `bell` | `bell-features` | comma-separated set; see §6.3 |
| `scrollbackBytes` | `scrollback-limit` | bytes; only applies to **new** surfaces (§6.5); UI shows MB |
| `windowOpacity` | `background-opacity` | |
| `windowPaddingX/Y` | `window-padding-x` / `window-padding-y` | |
| `titlebarStyle` | `macos-titlebar-style` | `tabs` / `transparent` / `native` / `hidden` (preserves existing default) |
| `theme` | `theme` | name from bundled catalog |

### 6.3 Bell mapping (verified against Ghostty default)

Ghostty's `bell-features` is a comma-separated set of named features. Default per `ghostty +show-config --default --docs` is `no-system,no-audio,attention,title,no-border`. Available features (each can be prefixed with `no-` to disable): `system`, `audio`, `attention`, `title`, `border`.

Caterm's high-level `BellMode` maps to explicit feature sets:

| `BellMode` | Rendered `bell-features` | Effect |
|---|---|---|
| `.none` | `no-system,no-audio,no-attention,no-title,no-border` | All bell feedback off |
| `.audio` | `no-system,audio,no-attention,no-title,no-border` | Audio file plays; no visual feedback |
| `.visual` | `no-system,no-audio,attention,title,no-border` | Matches Ghostty default visual feedback set |
| `.both` | `no-system,audio,attention,title,no-border` | Audio + visual |

Notes:
- `system` (system notification) is intentionally always disabled in v1: it routes through OS-level notifications (UNUserNotificationCenter) which Caterm already uses for sync-failure notifications. Routing terminal bell through the same pipeline is a UX call we defer to v2.
- For `.audio` and `.both`, `bell-audio-path` is left at Ghostty's default (uses bundled audio). Custom audio file is v2.

### 6.5 Scrollback semantics

Per Ghostty's docs (`+show-config --default --docs` confirms): `scrollback-limit` is the buffer size **in bytes**, not lines, and the value "can be changed at runtime but will only affect new terminal surfaces." Implications for the GUI:

- UI shows the value as MB (e.g., "Scrollback memory: 10 MB"), not lines, with a stepper in 1 MB increments.
- A `?` tooltip explains: "Scrollback is stored in memory; larger values use more RAM. Changes apply to new terminals only."
- Live reload code path for scrollback-only changes does NOT call `surface_update_config` (no effect anyway). Banner shows once: "Scrollback change applies to new tabs."
- Default in `settings.plist` matches Ghostty's default of 10 MB.

### 6.6 Header comment

`SettingsRenderer` emits a header comment: `# managed by Caterm — do not edit; use Caterm Preferences (⌘,)`.

### 6.7 Preserved-from-legacy block

`SettingsRenderer.render(...)` ALWAYS prepends the existing managed-snapshot constants:

```
term = xterm-256color
keybind = super+up=scroll_page_lines:-1
keybind = super+down=scroll_page_lines:1
keybind = super+page_up=scroll_page_fractional:-1
keybind = super+page_down=scroll_page_fractional:1
keybind = super+home=scroll_to_top
keybind = super+end=scroll_to_bottom
keybind = super+k=clear_screen
```

These are the existing managed snapshot per `ConfigStore.swift:60-78`. Dropping them would break SSH to remotes without Ghostty terminfo and remove user-visible scroll/clear keybinds. They live in `SettingsRenderer` as constants alongside the new field renderer. A dedicated test (`SettingsRendererTests.testLegacyBlockAlwaysPresent`) guards this.

## 7. Error Handling

| Failure | Behavior |
|---|---|
| `settings.plist` corrupted | Quarantine to `settings.plist.broken-<timestamp>`; seed defaults; surface a non-modal alert on next launch |
| Bundled `themes.json` missing or invalid | Fall back to embedded 9-favorites list; show banner in Themes tab "Theme catalog failed to load" |
| `ghostty_config_diagnostics_count` > 0 after finalize | Aggregate all diagnostic messages (no severity field exists in `ghostty_diagnostic_s` per header line 397-401); non-modal banner "Configuration warnings: <bullet list>"; apply still proceeds with Ghostty's internal fallback to defaults for the offending fields |
| Invalid font-family typed (shouldn't happen with dropdown but defensive) | Renderer omits the line; managed snapshot stays valid |
| User config has same key as managed (still wins, except theme on host-override) | Show "N user-config overrides active" hint in Terminal tab footer |
| Migration script fails mid-way | Roll back via backup of user config kept at `~/Library/Application Support/Caterm/config.bak-<timestamp>`; user sees alert pointing to backup |

## 8. Migration

This is the core architectural change vs v1 spec, addressing the issue where the legacy default user config shadows GUI changes.

### 8.1 Detection

On first launch with the new version, `SettingsMigrationStep` runs once (gated by a `"settings-gui-v1"` token in `settings.migrationsCompleted`):

1. Read user config from `~/Library/Application Support/Caterm/config`.
2. Compute SHA-256 of the trimmed bytes.
3. Compare against the **legacy fingerprint set**: hashes of every historical `defaultConfig` value baked into prior Caterm releases. (Initially just the current one in `ConfigStore.swift:8-17`. Future releases append new fingerprints.)

### 8.2 Branches

**Branch A — fingerprint matches (user has not edited their seeded defaults):**

1. Backup current user config to `~/Library/Application Support/Caterm/config.bak-pre-settings-gui-<timestamp>`.
2. Parse the legacy seed values (`font-family`, `font-size`, `theme`, `cursor-style`, `macos-titlebar-style`) into `settings.plist.global` — **all five fields**, including `titlebarStyle: .tabs` from the legacy `macos-titlebar-style = tabs` line.
3. Replace user config with a minimal placeholder (Ghostty config syntax — comments only, no entries):
   ```
   # User overrides for Caterm. Anything you put here wins over the
   # Caterm-managed config. Use Caterm Preferences (⌘,) for normal settings.
   ```
4. Render managed snapshot from `settings.plist`. The render output **must** include the `macos-titlebar-style = tabs` line because we just put it in `settings.plist.global.titlebarStyle`. (Test: `SettingsMigrationTests.testBranchA_titlebarPreserved` asserts no visual change.)
5. Insert `"settings-gui-v1"` into `settings.migrationsCompleted`.

After this, GUI changes flow correctly: managed wins over defaults, user config is empty so doesn't shadow anything.

**Branch B — fingerprint does NOT match (user has edited):**

1. Parse user config with `GhosttyConfigParser` (§2.0.1; not a TOML parser).
2. For each key that maps to a `PartialSettings` field, attempt **lossless extraction** (`PartialSettings.tryExtract(key:rawValue:) -> ExtractResult`):
   - `ExtractResult.ok(value)` — the line maps cleanly into a single `PartialSettings` field (e.g. `font-family = SF Mono` → `fontFamily = "SF Mono"`).
   - `ExtractResult.unrepresentable(reason:)` — the value cannot be losslessly represented. Examples (verified from Ghostty docs):
     - `font-family = X` followed by another `font-family = Y` (Ghostty fallback chain; `PartialSettings.fontFamily: String?` is single-valued).
     - `theme = light:Catppuccin Latte,dark:Catppuccin Mocha` (system-appearance switching; not modeled).
     - `bell-features = audio,attention` (custom feature combination not matching any of our four `BellMode` cases).
     - `palette = 0=#000000` and other deeper customizations.
3. For every line that yields `.ok`, copy the value into `settings.plist.global` (so the GUI shows what the user already had).
4. **Do not modify** user config.
5. Render managed snapshot from `settings.plist`.
6. Insert `"settings-gui-v1"` into `settings.migrationsCompleted`.
7. On next Preferences open (or a one-time modal at app start), show an informational banner whose text reflects the extraction result:

> Your user config at `~/.../Caterm/config` overrides Caterm Preferences for **<list of representable keys>**. Caterm imported these into Preferences.
>
> **<N>** other override(s) — including <bullet list of unrepresentable lines, e.g. "fallback font chain (3 entries)", "light/dark theme switching", "custom bell-features"> — remain in your user config and continue to apply. They cannot be edited from Preferences.
>
> [ Import representable keys (clear from user config) ] [ Keep as-is ] [ Open user config ]

Choosing **Import representable keys** removes only the `.ok` lines from user config (using `GhosttyConfigParser`'s lossless edit; preserves all other lines, comments, blank lines, and ordering). Unrepresentable lines stay in user config untouched, ensuring the user does not silently lose `font-family` fallback chains, `theme = light:...,dark:...`, custom `bell-features`, or anything else outside our v1 schema.

"Keep as-is" preserves the override hint count in the Terminal tab footer; the user can act on it later.

`SettingsMigrationTests.testBranchB_unrepresentableLinesPreserved` covers each `unrepresentable` reason with a golden user config.

**Branch C — user config missing or unreadable:**

Treat as Branch A (write fresh placeholder; seed defaults into `settings.plist`, including `titlebarStyle: .tabs`).

### 8.3 Why not just "always overwrite"?

We never silently overwrite user content. Many Caterm users in the wild have customized their `theme = ...` line and would be surprised to see their theme reset by an update. Branch B preserves their explicit choices.

### 8.4 Test coverage

- `SettingsMigrationTests` covers all three branches with golden-file user configs.
- A dedicated test loads the **exact** legacy default from the current `ConfigStore.defaultConfig` constant and verifies it computes to the expected fingerprint.

## 9. Testing

### 9.1 Unit tests

- **`SettingsStoreTests`**
  - plist round-trip (write → read → equal)
  - corrupted plist → quarantine + defaults
  - debounce coalesces rapid edits into one write

- **`SettingsRendererTests`**
  - each field renders to expected config line
  - `lineHeight = 1.1` → `adjust-cell-height = 10%`
  - `bell = .both` → both flags true
  - theme name with spaces (e.g. `Catppuccin Mocha`) round-trips correctly: rendered as `theme = Catppuccin Mocha` (no quoting needed; Ghostty parser accepts unquoted multi-word values)
  - empty `PartialSettings` → only the legacy block + header comment is emitted (no field lines)
  - **legacy block always present** (term=xterm-256color + 7 keybinds) regardless of `PartialSettings` content

- **`ThemeCatalogTests`**
  - bundled `themes.json` round-trip
  - missing/invalid bundle → fallback to embedded 9-favorites
  - swatch parsing matches a hand-checked theme

- **`ConfigStoreTests` (existing, extend)**
  - render produces a snapshot file with expected content (legacy block + new fields)
  - per-host patch path is created/deleted correctly

- **`SettingsMigrationTests`**
  - Branch A: legacy default → user config cleared, settings.plist seeded
  - Branch B: edited user config → user config preserved, settings.plist seeded with parsed values
  - Branch C: missing user config → fresh placeholder
  - Backup file created in branch A
  - Idempotency: running migration twice has no additional effect

### 9.2 Manual smoke (`apps/macos/Manual/settings-smoke.md`)

1. Fresh install (no user config) → ⌘, opens Preferences; defaults visible
2. Change font size → all open tabs reflow live
3. Change cursor style → live update
4. Change theme → live update (global)
5. Change theme on host A only → connect to A → tab uses override; disconnect & reconnect to A again, override still applied
6. Connect to host B (no override) → tab uses global theme
7. Change global theme while a host-overridden tab is open → existing host-overridden tab keeps override; new tabs (any host) use new global
8. Close & reopen app → settings persist
9. Edit user config to override `cursor-style` → user value wins after restart; Terminal tab shows "1 user-config override active"
10. Click "Edit Advanced Config" → user config opens in Finder
11. Quit while typing in stepper → no data loss (debounce flushes on quit)
12. **Migration A:** start with legacy default user config → upgrade → user config replaced with minimal placeholder; backup file created; settings.plist contains the legacy values
13. **Migration B:** start with edited user config → upgrade → user config untouched; banner shown; clicking "Move to Preferences" clears those keys and re-renders
14. Theme picker shows favorites + scrollable full catalog; search filters correctly; clicking a card live-applies

## 10. Out of Scope (v2)

- letter-spacing
- inactive cursor style
- per-ANSI-color overrides
- keybinding editor
- shell selection
- per-host overrides for non-theme fields
- cloud sync (Y2 deferred — requires server schema + conflict policy)
- light/dark auto-switch on system appearance
- import/export settings file
- live preview of theme card hover (just static swatches in v1)

## 11. References

- `apps/macos/Sources/ConfigStore/ConfigStore.swift` — current managed snapshot impl (line 60: legacy block; line 8: user-config seed)
- `apps/macos/Sources/TerminalEngine/GhosttyConfig.swift` — current config load order
- `apps/macos/Sources/Caterm/AppDelegate.swift` — current ⌘, handler
- `apps/macos/Sources/Caterm/Views/SyncSettingsView.swift` — sheet to migrate into tab
- `apps/macos/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h` — verified config/surface API surface (lines 1069-1108)
- `apps/macos/Vendor/ghostty/resources/themes/` — build-time theme source (requires `make macos-ghostty-submodule`)
- Web app reference: `apps/web/src/components/settings/`, `apps/web/src/lib/terminal-themes.ts`
