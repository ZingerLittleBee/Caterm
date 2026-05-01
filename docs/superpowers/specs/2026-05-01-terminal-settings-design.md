# Terminal Settings GUI + Theme Picker — Design Spec

**Status:** Draft v2 (revised after review 2026-05-01)
**Date:** 2026-05-01
**Scope:** macOS app (`apps/macos/`) only.

---

## 1. Goal

Replace the current "⌘, opens TOML in Finder" behavior with a proper macOS Preferences window covering Font, Cursor, Bell, Scrollback, Window, and Theme settings. Add a theme picker (bundled theme catalog with 9 curated favorites). Support **per-host theme override** (other fields are global only in v1).

## 2. Architecture

### 2.1 Current state of config layering (verified)

The codebase today (`apps/macos/Sources/ConfigStore/ConfigStore.swift`) maintains two distinct files:

| File | Role | Current contents |
|---|---|---|
| `~/Library/Application Support/Caterm/config` (user TOML) | Seeded on first launch via `defaultConfig`; user edits freely | `font-family = SF Mono`, `font-size = 13`, `theme = Catppuccin Mocha`, `cursor-style = block`, `macos-titlebar-style = tabs` |
| `~/Library/Application Support/Caterm/caterm-managed.config` (managed snapshot) | Caterm-owned, written by `ConfigStore.writeManagedConfig()` | `term = xterm-256color`, 6× scroll/clear keybinds (⌘↑/⌘↓/⌘⇞/⌘⇟/⌘home/⌘end/⌘k) |

`Sources/TerminalEngine/GhosttyConfig.swift` loads them in this order:

```
ghostty_config_load_default_files(cfg)            // ghostty defaults
ghostty_config_load_file(cfg, managedPath)        // term + keybinds
ghostty_config_load_file(cfg, userPath)           // user TOML — wins
ghostty_config_finalize(cfg)
```

**Critical implication:** because user TOML wins, and the seeded default user TOML already contains font/theme/cursor/titlebar lines, simply moving GUI writes into the managed snapshot **will be silently overridden** on every existing install. Section 8 details the migration that solves this.

### 2.2 New persistence: Caterm-owned plist + rendered managed snapshot

```
[Ghostty defaults]
        ↓
[managed snapshot TOML]   ← rewritten on every settings change; contains:
                              • the legacy term + keybind block (preserved)
                              • the new fields rendered from settings.plist (font, cursor, bell, scrollback, window, theme)
        ↓
[user config TOML]         ← unchanged for new fields; existing customizations preserved
        ↓
[per-host patch file]     ← optional, only for the surface; written when host has theme override
```

- New file: `~/Library/Application Support/Caterm/settings.plist` (Codable, Caterm-owned).
- `ConfigStore` is extended to render `settings.plist` into the managed snapshot on every write.
- The user TOML is no longer edited by Caterm after the migration (§8).
- Per-host theme override loads as an additional file **after** user TOML, scoped to the surface only — see §2.4.

### 2.3 Settings schema (Codable)

```swift
public struct CatermSettings: Codable, Equatable {
    public var version: Int                   // schema version, starts at 1
    public var revision: String               // ULID-like token; bumps on any change
    public var global: PartialSettings
    public var hostOverrides: [HostId: PartialSettings]
}

public struct PartialSettings: Codable, Equatable {
    public var fontFamily: String?            // system monospaced fonts only
    public var fontSize: Int?                 // 8..32
    public var lineHeight: Double?            // 0.8..2.0  → adjust-cell-height
    public var cursorStyle: CursorStyle?      // .block | .bar | .underline
    public var cursorBlink: Bool?
    public var bell: BellMode?                // .none | .audio | .visual | .both
    public var scrollbackLines: Int?          // default 10000
    public var windowOpacity: Double?         // 0.7..1.0
    public var windowPaddingX: Int?
    public var windowPaddingY: Int?
    public var theme: String?                 // theme name (matches bundled catalog)
}
```

In v1 only `theme` is read from `hostOverrides[hostId]`; other fields in `PartialSettings` exist for future use (data model permits expansion without migration).

### 2.4 Live reload pipeline (using actual GhosttyKit API)

The framework header (`Frameworks/GhosttyKit.xcframework/.../ghostty.h`) exposes:

```
ghostty_config_t ghostty_config_new();
void ghostty_config_load_default_files(ghostty_config_t);
void ghostty_config_load_file(ghostty_config_t, const char*);
void ghostty_config_finalize(ghostty_config_t);
void ghostty_config_free(ghostty_config_t);
void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);
void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
```

Note: `ghostty_surface_reload_config` and `ghostty_config_load_string` (mentioned in v1 spec) **do not exist**. Reload must go through new config object construction.

**Reload sequence on settings change:**

1. `SettingsStore.update(...)` writes plist + bumps revision.
2. `ConfigStore.renderManagedSnapshot(from: settings.global)` rewrites managed TOML.
3. For each open `GhosttySurfaceNSView`:
   - Compute effective per-host theme: `settings.hostOverrides[surface.hostId]?.theme`.
   - If present, write a per-host patch file to `~/Library/Caches/Caterm/per-host/<hostId>.config` containing only `theme = <name>`. Else, delete the file if present.
   - Build a new `ghostty_config_t`:
     ```
     cfg = ghostty_config_new()
     ghostty_config_load_default_files(cfg)
     ghostty_config_load_file(cfg, managedPath)
     ghostty_config_load_file(cfg, userPath)
     if perHostPatchExists: ghostty_config_load_file(cfg, perHostPath)
     ghostty_config_finalize(cfg)
     ```
   - Call `ghostty_surface_update_config(surface, cfg)`.
   - Free the previous config object after the call returns.
4. Also call `ghostty_app_update_config(app, cfgFromGlobalOnly)` once (no per-host patch) so newly created surfaces pick up the latest baseline before they request their own surface-level config.

**Per-host theme override precedence:** the per-host file loads **after** user TOML, so a host override does override a `theme = ...` line in user TOML. Rationale: per-host override is an explicit per-host action by the user via GUI; treating it as the highest-precedence layer matches user intent. Other settings categories (font, cursor, etc.) have no per-host layer in v1 and continue to honor "user TOML wins".

**Effect timing:**
- Global settings change → all open surfaces reload immediately.
- Per-host theme change → existing tabs keep their current theme until reconnect (per Q4a). New tabs to that host pick up the override at surface creation. Implementation: do not call `ghostty_surface_update_config` for existing surfaces on per-host theme change; only update the patch file so the next `surface_new` reads the new value.
- If `ghostty_surface_update_config` reports failure (rare; e.g. a font-family the system rejects), the surface remains on the previous config — the user sees the old setting. UI shows a non-modal banner: "Some settings will apply on next reconnect."

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
  Lines        [Stepper: 10000]

Window
  Opacity      ━━━━━━●━  0.95
  Padding X    [Stepper: 4]
  Padding Y    [Stepper: 4]

──────────────────────────────────────────
[Edit Advanced Config…]   3 user-config overrides active
```

The "Edit Advanced Config" button opens user TOML in Finder (preserves the previous ⌘, behavior). The hint count counts user-TOML keys that are *also* in `PartialSettings` (i.e. would be overridden by GUI changes) — gives users a heads-up when their user TOML is shadowing the GUI.

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

- **Source: bundled catalog generated at build time from `apps/macos/Vendor/ghostty/resources/themes/`.** Not a runtime CLI call.
- Each card shows ANSI color swatches (parsed from theme files at build time, stored as RGB tuples) + name.
- Click → set as global theme + live reload.
- Search filters the "All Themes" grid (favorites always visible above the fold).

Build-time pipeline:
1. `Scripts/build-theme-catalog.sh` runs as part of the `make macos-ghostty-kit` step (or as a SwiftPM build phase) after the Ghostty submodule is initialized.
2. Reads `Vendor/ghostty/resources/themes/*` (one theme file per name; format is the same Ghostty config TOML subset).
3. Parses `palette = N=#rgb`, `background`, `foreground`, `cursor-color`, `selection-background` keys.
4. Emits `Sources/SettingsStore/Resources/themes.json` with `{ name, palette: [hex×16], background, foreground }` per theme.
5. Bundle is loaded once at app start into an in-memory `ThemeCatalog` actor.

If the submodule is not initialized at build time, the build emits a warning and falls back to a small embedded catalog of the 9 favorites (so dev builds still work).

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
│   └─ SettingsRenderer.swift               ← NEW: PartialSettings → TOML lines
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
2. `MigrationStep.runIfNeeded()` (§8) executes once per install version; may rewrite user TOML and seed `settings.plist`.
3. `ConfigStore.renderManagedSnapshot(from: settings.global)` writes the managed TOML — **always preserving the existing `term` + scrollback keybinds block** (Section 6.4).
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

The patch file written for the surface contains only the `theme` line when a host override is set; absence of the file means "use the chain as-is" (and resolution above happens implicitly via the loaded TOMLs).

## 6. Field → TOML mapping

| Schema field | Ghostty TOML key | Notes |
|---|---|---|
| `fontFamily` | `font-family` | dropdown enforces system monospaced fonts |
| `fontSize` | `font-size` | integer 8..32 |
| `lineHeight` | `adjust-cell-height` | percent string: `1.1` → `10%` |
| `cursorStyle` | `cursor-style` | `block` / `bar` / `underline` |
| `cursorBlink` | `cursor-style-blink` | bool |
| `bell == .audio` | `audible-bell = true` | |
| `bell == .visual` | `visual-bell = true` | |
| `bell == .both` | both true | |
| `scrollbackLines` | `scrollback-limit` | |
| `windowOpacity` | `background-opacity` | |
| `windowPaddingX/Y` | `window-padding-x` / `window-padding-y` | |
| `theme` | `theme` | name from bundled catalog |

`SettingsRenderer` emits a header comment: `# managed by Caterm — do not edit; use Caterm Preferences (⌘,)`.

### 6.4 Preserved-from-legacy block

`SettingsRenderer.render(...)` ALWAYS prepends the existing managed-snapshot constants:

```toml
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
| `ghostty_surface_update_config` returns failure (or surface flagged "needs reconnect") | Subtle indicator on the affected tab |
| Invalid font-family typed (shouldn't happen with dropdown but defensive) | Renderer omits the line; managed snapshot stays valid |
| User TOML has same key as managed (still wins, except theme on host-override) | Show "N user-config overrides active" hint in Terminal tab footer |
| Migration script fails mid-way | Roll back via backup of user TOML kept at `~/Library/Application Support/Caterm/config.bak-<timestamp>`; user sees alert pointing to backup |

## 8. Migration

This is the core architectural change vs v1 spec, addressing the issue where the legacy default user TOML shadows GUI changes.

### 8.1 Detection

On first launch with the new version, `SettingsMigrationStep` runs once (gated by a `migration-v1-completed` flag in `settings.plist`):

1. Read user TOML from `~/Library/Application Support/Caterm/config`.
2. Compute SHA-256 of the trimmed bytes.
3. Compare against the **legacy fingerprint set**: hashes of every historical `defaultConfig` value baked into prior Caterm releases. (Initially just the current one in `ConfigStore.swift:8-17`. Future releases append new fingerprints.)

### 8.2 Branches

**Branch A — fingerprint matches (user has not edited their seeded defaults):**

1. Backup current user TOML to `~/Library/Application Support/Caterm/config.bak-pre-settings-gui-<timestamp>`.
2. Parse the legacy seed values (font-family, font-size, theme, cursor-style, macos-titlebar-style) into `settings.plist.global`.
3. Replace user TOML with a minimal placeholder:
   ```toml
   # User overrides for Caterm. Anything you put here wins over the
   # Caterm-managed config. Use Caterm Preferences (⌘,) for normal settings.
   ```
4. Render managed snapshot from `settings.plist`.
5. Set `migration-v1-completed = true`.

After this, GUI changes flow correctly: managed wins over defaults, user TOML is empty so doesn't shadow anything.

**Branch B — fingerprint does NOT match (user has edited):**

1. Parse user TOML (best-effort; `# managed by Caterm` comment block ignored).
2. For each key that maps to a `PartialSettings` field, copy the value into `settings.plist.global` (so the GUI shows what the user already had).
3. **Do not modify** user TOML.
4. Render managed snapshot from `settings.plist`.
5. Set `migration-v1-completed = true`.
6. On next Preferences open (or via a one-time modal at app start), show an informational banner:

> Your user config at `~/.../Caterm/config` overrides Caterm Preferences for **theme, font-family, font-size, cursor-style**. Caterm read these into Preferences; further changes here will not take effect until the user config is updated.
>
> [ Move to Preferences (clear from user config) ] [ Keep as-is ] [ Open user config ]

Choosing "Move to Preferences" clears those specific keys from the user TOML and re-renders. "Keep as-is" dismisses the banner but preserves the override hint count in the Terminal tab footer.

**Branch C — user TOML missing or unreadable:**

Treat as Branch A (write fresh placeholder; seed defaults into `settings.plist`).

### 8.3 Why not just "always overwrite"?

We never silently overwrite user content. Many Caterm users in the wild have customized their `theme = ...` line and would be surprised to see their theme reset by an update. Branch B preserves their explicit choices.

### 8.4 Test coverage

- `SettingsMigrationTests` covers all three branches with golden-file user TOMLs.
- A dedicated test loads the **exact** legacy default from the current `ConfigStore.defaultConfig` constant and verifies it computes to the expected fingerprint.

## 9. Testing

### 9.1 Unit tests

- **`SettingsStoreTests`**
  - plist round-trip (write → read → equal)
  - corrupted plist → quarantine + defaults
  - debounce coalesces rapid edits into one write

- **`SettingsRendererTests`**
  - each field renders to expected TOML line
  - `lineHeight = 1.1` → `adjust-cell-height = 10%`
  - `bell = .both` → both flags true
  - `theme` with quotes/spaces is escaped
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
  - Branch A: legacy default → user TOML cleared, settings.plist seeded
  - Branch B: edited user TOML → user TOML preserved, settings.plist seeded with parsed values
  - Branch C: missing user TOML → fresh placeholder
  - Backup file created in branch A
  - Idempotency: running migration twice has no additional effect

### 9.2 Manual smoke (`apps/macos/Manual/settings-smoke.md`)

1. Fresh install (no user TOML) → ⌘, opens Preferences; defaults visible
2. Change font size → all open tabs reflow live
3. Change cursor style → live update
4. Change theme → live update (global)
5. Change theme on host A only → connect to A → tab uses override; disconnect & reconnect to A again, override still applied
6. Connect to host B (no override) → tab uses global theme
7. Change global theme while a host-overridden tab is open → existing host-overridden tab keeps override; new tabs (any host) use new global
8. Close & reopen app → settings persist
9. Edit user TOML to override `cursor-style` → user value wins after restart; Terminal tab shows "1 user-config override active"
10. Click "Edit Advanced Config" → user TOML opens in Finder
11. Quit while typing in stepper → no data loss (debounce flushes on quit)
12. **Migration A:** start with legacy default user TOML → upgrade → user TOML replaced with minimal placeholder; backup file created; settings.plist contains the legacy values
13. **Migration B:** start with edited user TOML → upgrade → user TOML untouched; banner shown; clicking "Move to Preferences" clears those keys and re-renders
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
