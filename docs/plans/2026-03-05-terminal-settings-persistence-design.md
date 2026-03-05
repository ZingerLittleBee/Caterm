# Terminal Settings Persistence Design

## Goal

Persist terminal settings to PostgreSQL via Drizzle ORM, replacing the current in-memory-only storage. Support local caching via localStorage for instant startup, with remote sync on load.

## DB Schema

Replace individual columns with two JSONB columns:

```sql
terminal_settings (
  id          SERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL UNIQUE REFERENCES auth.user(id) ON DELETE CASCADE,
  settings_json         JSONB NOT NULL DEFAULT '{}',
  host_overrides_json   JSONB NOT NULL DEFAULT '{}'
)
```

- `settings_json`: full `TerminalSettings` object (11 fields: fontFamily, fontSize, lineHeight, letterSpacing, cursorStyle, cursorBlink, cursorInactiveStyle, scrollback, bellStyle, themeName, themeOverrides)
- `host_overrides_json`: `Record<string, Partial<TerminalSettings>>` keyed by hostId

## API Router

Two procedures on `terminalSettingsRouter`:

**`get`** (protectedProcedure):
- Returns `{ global: TerminalSettings, hostOverrides: Record<string, Partial<TerminalSettings>> }`
- Merges `settingsJson` with `DEFAULT_TERMINAL_SETTINGS` to fill missing fields

**`upsert`** (protectedProcedure):
- Input: `{ global?: Partial<TerminalSettings>, hostOverrides?: Record<string, Partial<TerminalSettings>> }`
- Uses `onConflictDoUpdate` by userId

## Provider (React Query)

Replace `useReducer` with React Query:

```
Startup:
  localStorage cache → placeholderData → immediate render
  API get → remote data → overwrite → sync to localStorage
```

**Reading**: `useQuery` with `placeholderData` from localStorage (key: `caterm-terminal-settings`)
**Writing**: `useMutation` → API upsert → invalidate query → re-fetch → update localStorage

**Context API** (unchanged for consumers):
```typescript
interface TerminalSettingsContextValue {
  settings: TerminalSettings;
  isLoading: boolean;                    // new
  getSettingsForHost(hostId: string): TerminalSettings;
  updateGlobal(partial: Partial<TerminalSettings>): void;
  updateHostOverrides(hostId: string, partial: Partial<TerminalSettings>): void;
  clearHostOverrides(hostId: string): void;
}
```

**Map serialization**: `Map<string, ...>` ↔ `Record<string, ...>` conversion happens inside Provider.

## Consumer Impact

- **TerminalSettingsForm**: No changes needed. `updateGlobal(draft)` triggers mutation internally. Optionally use `isLoading` to disable form during load.
- **SshTerminal**: No changes. `getSettingsForHost(hostId)` works as before.
- **Root layout / settings page**: No changes required.

## Loading Behavior

- With localStorage cache: render immediately with cached data, silently sync from server
- Without localStorage cache: `isLoading=true`, consumers can show loading UI
- After mutation success: invalidate query → re-fetch → update localStorage
