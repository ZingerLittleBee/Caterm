# Terminal Theme & Settings System Design

## Overview

Design a terminal theme system and enhanced settings for the Caterm SSH terminal client. Settings are stored in memory (React Context) with no persistence layer — a storage adapter will be added later.

## Data Types

### Theme Colors

```typescript
/** Complete xterm.js ITheme color definition */
interface TerminalThemeColors {
  foreground: string
  background: string
  cursor: string
  cursorAccent: string
  selectionBackground: string
  selectionForeground: string
  selectionInactiveBackground: string
  // ANSI standard 16 colors
  black: string
  red: string
  green: string
  yellow: string
  blue: string
  magenta: string
  cyan: string
  white: string
  brightBlack: string
  brightRed: string
  brightGreen: string
  brightYellow: string
  brightBlue: string
  brightMagenta: string
  brightCyan: string
  brightWhite: string
}

/** A preset theme = display name + full color set */
interface TerminalThemePreset {
  name: string // Display name, e.g. "Dracula"
  colors: TerminalThemeColors
}
```

### Terminal Settings

```typescript
type CursorStyle = "block" | "underline" | "bar"
type CursorInactiveStyle = "outline" | "block" | "bar" | "underline" | "none"
type BellStyle = "none" | "sound" | "visual" | "both"

interface TerminalSettings {
  // Font
  fontFamily: string
  fontSize: number
  lineHeight: number
  letterSpacing: number
  // Cursor
  cursorStyle: CursorStyle
  cursorBlink: boolean
  cursorInactiveStyle: CursorInactiveStyle
  // Behavior
  scrollback: number
  bellStyle: BellStyle
  // Theme
  themeName: string                            // Key into BUILTIN_THEMES
  themeOverrides: Partial<TerminalThemeColors>  // Optional color overrides
}
```

### Host-Level Overrides

```typescript
/** Per-host overrides — any subset of TerminalSettings */
type HostTerminalOverrides = Partial<TerminalSettings>
```

### Defaults

```typescript
const DEFAULT_TERMINAL_SETTINGS: TerminalSettings = {
  fontFamily: "monospace",
  fontSize: 14,
  lineHeight: 1.0,
  letterSpacing: 0,
  cursorStyle: "block",
  cursorBlink: true,
  cursorInactiveStyle: "outline",
  scrollback: 1000,
  bellStyle: "none",
  themeName: "default",
  themeOverrides: {},
}
```

## Built-in Theme Presets

Initial set (stored as `Record<string, TerminalThemePreset>`):

| Key                | Display Name       |
|--------------------|--------------------|
| `default`          | Default (xterm)    |
| `dracula`          | Dracula            |
| `one-dark`         | One Dark           |
| `solarized-dark`   | Solarized Dark     |
| `solarized-light`  | Solarized Light    |
| `monokai`          | Monokai            |
| `nord`             | Nord               |
| `github-dark`      | GitHub Dark        |
| `github-light`     | GitHub Light       |
| `catppuccin-mocha` | Catppuccin Mocha   |

## State Management

### Store Structure

```typescript
interface TerminalSettingsState {
  global: TerminalSettings
  hostOverrides: Map<string, HostTerminalOverrides>
}
```

### Resolution Functions

```typescript
/** Merge global settings with optional host overrides */
function resolveSettings(
  state: TerminalSettingsState,
  hostId?: string
): TerminalSettings {
  if (!hostId) return state.global
  const overrides = state.hostOverrides.get(hostId)
  if (!overrides) return state.global
  return { ...state.global, ...overrides }
}

/** Resolve the final xterm.js ITheme from settings */
function resolveTheme(settings: TerminalSettings): ITheme {
  const preset = BUILTIN_THEMES[settings.themeName] ?? BUILTIN_THEMES.default
  return { ...preset.colors, ...settings.themeOverrides }
}
```

### React Context API

Provider: `TerminalSettingsProvider` (wraps the SSH route)

Exposed via `useTerminalSettings()`:

| Method                                    | Description                          |
|-------------------------------------------|--------------------------------------|
| `settings`                                | Current global settings              |
| `getSettingsForHost(hostId)`              | Resolved settings for a host         |
| `updateGlobal(partial)`                   | Update global settings               |
| `updateHostOverrides(hostId, partial)`    | Set/update host-level overrides      |
| `clearHostOverrides(hostId)`              | Remove all overrides for a host      |

Implementation: `useReducer` with actions for each mutation.

## Integration Plan

### Files to modify

1. **`src/types/ssh.ts`** — Add `TerminalThemeColors`, `TerminalSettings`, `HostTerminalOverrides`, and related union types.

2. **New: `src/lib/terminal-themes.ts`** — `BUILTIN_THEMES` constant, `DEFAULT_TERMINAL_SETTINGS`, `resolveSettings()`, `resolveTheme()`.

3. **New: `src/components/terminal/terminal-settings-provider.tsx`** — React Context + useReducer for in-memory settings store.

4. **`src/components/ssh/ssh-terminal.tsx`** — Remove individual setting props (`fontSize`, `fontFamily`, etc.). Accept `hostId` prop. Consume `useTerminalSettings()` to resolve settings + theme. Pass resolved theme to `new Terminal({ theme })`. Apply settings changes to live terminal via `terminal.options`.

5. **`src/routes/ssh/route.tsx`** — Remove inline `TerminalSettings` type and SQLite loading. Wrap with `TerminalSettingsProvider`. Remove setting props from `<SshTerminal>`, pass `hostId` instead.

6. **`src/components/settings/terminal-settings-form.tsx`** — Remove SQLite read/write. Use `useTerminalSettings()` context. Add UI for: lineHeight, letterSpacing, bellStyle, cursorInactiveStyle, theme selector (preset list), optional color override inputs.

### Files NOT modified

- Tauri backend / Rust code (theme is purely frontend)
- SSH connection logic, event listeners, base64 encoding

## Notes for Future Storage Implementation

When adding persistence, consider the following:

### Storage Adapter Pattern

Design a storage interface that the Context can optionally use:

```typescript
interface TerminalSettingsStorage {
  load(): Promise<TerminalSettingsState>
  save(state: TerminalSettingsState): Promise<void>
}
```

The provider can accept an optional `storage` prop. On mount, it calls `storage.load()` to hydrate state. On every state change, it calls `storage.save()` (debounced).

### Serialization Considerations

- `Map<string, HostTerminalOverrides>` needs to be serialized to/from `Record<string, HostTerminalOverrides>` for JSON or SQLite storage.
- `themeOverrides` is already `Partial<TerminalThemeColors>` which serializes cleanly.
- Consider a version field in the stored data for future migrations.

### Database Schema (when ready)

```sql
-- Global settings (single row)
CREATE TABLE terminal_settings (
  id TEXT PRIMARY KEY DEFAULT 'default',
  settings_json TEXT NOT NULL  -- JSON blob of TerminalSettings
);

-- Per-host overrides
CREATE TABLE host_terminal_overrides (
  host_id TEXT PRIMARY KEY REFERENCES ssh_hosts(id),
  overrides_json TEXT NOT NULL  -- JSON blob of Partial<TerminalSettings>
);
```

Using JSON blobs instead of individual columns avoids schema migrations when adding new settings fields.

### Migration from Current Schema

The current `terminal_settings` table has individual columns (`font_family`, `font_size`, etc.). Migration steps:
1. Read existing column-based settings
2. Convert to new `TerminalSettings` object
3. Store as JSON in new schema
4. Drop old columns or table

### Sync & Conflict Resolution

The existing `config-sync.ts` export/import system needs to include `TerminalSettingsState` in its payload. The flat structure makes merge straightforward — last-write-wins per field.
