# Terminal Theme & Settings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement a terminal theme system with built-in presets, color overrides, and enhanced settings (lineHeight, letterSpacing, bellStyle, cursorInactiveStyle), stored in-memory via React Context with global defaults + per-host overrides.

**Architecture:** React Context + useReducer for state management. Separation of concerns: types in `types/`, theme data + resolution functions in `lib/`, Context provider in `components/terminal/`. SshTerminal consumes settings from Context instead of individual props. No persistence — memory only.

**Tech Stack:** React 19, TypeScript, xterm.js (@xterm/xterm v6), shadcn/ui components

**Note:** This project has no test framework installed. Steps focus on implementation and manual verification via `bun x ultracite check` (linting/formatting).

---

### Task 1: Add Terminal Types

**Files:**
- Modify: `apps/web/src/types/ssh.ts`

**Step 1: Add theme and settings types to `src/types/ssh.ts`**

Append the following types after the existing `SshSessionInfo` interface:

```typescript
/** Complete xterm.js ITheme color definition */
export interface TerminalThemeColors {
	background: string;
	black: string;
	blue: string;
	brightBlack: string;
	brightBlue: string;
	brightCyan: string;
	brightGreen: string;
	brightMagenta: string;
	brightRed: string;
	brightWhite: string;
	brightYellow: string;
	cursor: string;
	cursorAccent: string;
	cyan: string;
	foreground: string;
	green: string;
	magenta: string;
	red: string;
	selectionBackground: string;
	selectionForeground: string;
	selectionInactiveBackground: string;
	white: string;
	yellow: string;
}

/** A preset theme = display name + full color set */
export interface TerminalThemePreset {
	colors: TerminalThemeColors;
	name: string;
}

export type CursorStyle = "block" | "underline" | "bar";
export type CursorInactiveStyle =
	| "outline"
	| "block"
	| "bar"
	| "underline"
	| "none";
export type BellStyle = "none" | "sound" | "visual" | "both";

export interface TerminalSettings {
	bellStyle: BellStyle;
	cursorBlink: boolean;
	cursorInactiveStyle: CursorInactiveStyle;
	cursorStyle: CursorStyle;
	fontFamily: string;
	fontSize: number;
	letterSpacing: number;
	lineHeight: number;
	scrollback: number;
	themeName: string;
	themeOverrides: Partial<TerminalThemeColors>;
}

/** Per-host overrides — any subset of TerminalSettings */
export type HostTerminalOverrides = Partial<TerminalSettings>;

export interface TerminalSettingsState {
	global: TerminalSettings;
	hostOverrides: Map<string, HostTerminalOverrides>;
}
```

**Step 2: Run lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: No errors from the types file

**Step 3: Commit**

```bash
git add apps/web/src/types/ssh.ts
git commit -m "feat: add terminal theme and settings types"
```

---

### Task 2: Create Built-in Themes & Resolution Functions

**Files:**
- Create: `apps/web/src/lib/terminal-themes.ts`

**Step 1: Create `src/lib/terminal-themes.ts`**

This file contains: `DEFAULT_TERMINAL_SETTINGS`, `BUILTIN_THEMES` (Record of 10 presets with full color values), `resolveSettings()`, and `resolveTheme()`.

```typescript
import type {
	TerminalSettings,
	TerminalSettingsState,
	TerminalThemeColors,
	TerminalThemePreset,
} from "@/types/ssh";

export const DEFAULT_TERMINAL_SETTINGS: TerminalSettings = {
	bellStyle: "none",
	cursorBlink: true,
	cursorInactiveStyle: "outline",
	cursorStyle: "block",
	fontFamily: "monospace",
	fontSize: 14,
	letterSpacing: 0,
	lineHeight: 1.0,
	scrollback: 1000,
	themeName: "default",
	themeOverrides: {},
};

export const BUILTIN_THEMES: Record<string, TerminalThemePreset> = {
	default: {
		name: "Default",
		colors: {
			foreground: "#ffffff",
			background: "#000000",
			cursor: "#ffffff",
			cursorAccent: "#000000",
			selectionBackground: "#ffffff40",
			selectionForeground: undefined as unknown as string,
			selectionInactiveBackground: "#ffffff20",
			black: "#2e3436",
			red: "#cc0000",
			green: "#4e9a06",
			yellow: "#c4a000",
			blue: "#3465a4",
			magenta: "#75507b",
			cyan: "#06989a",
			white: "#d3d7cf",
			brightBlack: "#555753",
			brightRed: "#ef2929",
			brightGreen: "#8ae234",
			brightYellow: "#fce94f",
			brightBlue: "#729fcf",
			brightMagenta: "#ad7fa8",
			brightCyan: "#34e2e2",
			brightWhite: "#eeeeec",
		},
	},
	dracula: {
		name: "Dracula",
		colors: {
			foreground: "#f8f8f2",
			background: "#282a36",
			cursor: "#f8f8f2",
			cursorAccent: "#282a36",
			selectionBackground: "#44475a",
			selectionForeground: "#f8f8f2",
			selectionInactiveBackground: "#44475a80",
			black: "#21222c",
			red: "#ff5555",
			green: "#50fa7b",
			yellow: "#f1fa8c",
			blue: "#bd93f9",
			magenta: "#ff79c6",
			cyan: "#8be9fd",
			white: "#f8f8f2",
			brightBlack: "#6272a4",
			brightRed: "#ff6e6e",
			brightGreen: "#69ff94",
			brightYellow: "#ffffa5",
			brightBlue: "#d6acff",
			brightMagenta: "#ff92df",
			brightCyan: "#a4ffff",
			brightWhite: "#ffffff",
		},
	},
	"one-dark": {
		name: "One Dark",
		colors: {
			foreground: "#abb2bf",
			background: "#282c34",
			cursor: "#528bff",
			cursorAccent: "#282c34",
			selectionBackground: "#3e4451",
			selectionForeground: "#abb2bf",
			selectionInactiveBackground: "#3e445180",
			black: "#282c34",
			red: "#e06c75",
			green: "#98c379",
			yellow: "#e5c07b",
			blue: "#61afef",
			magenta: "#c678dd",
			cyan: "#56b6c2",
			white: "#abb2bf",
			brightBlack: "#5c6370",
			brightRed: "#e06c75",
			brightGreen: "#98c379",
			brightYellow: "#e5c07b",
			brightBlue: "#61afef",
			brightMagenta: "#c678dd",
			brightCyan: "#56b6c2",
			brightWhite: "#ffffff",
		},
	},
	"solarized-dark": {
		name: "Solarized Dark",
		colors: {
			foreground: "#839496",
			background: "#002b36",
			cursor: "#839496",
			cursorAccent: "#002b36",
			selectionBackground: "#073642",
			selectionForeground: "#93a1a1",
			selectionInactiveBackground: "#07364280",
			black: "#073642",
			red: "#dc322f",
			green: "#859900",
			yellow: "#b58900",
			blue: "#268bd2",
			magenta: "#d33682",
			cyan: "#2aa198",
			white: "#eee8d5",
			brightBlack: "#002b36",
			brightRed: "#cb4b16",
			brightGreen: "#586e75",
			brightYellow: "#657b83",
			brightBlue: "#839496",
			brightMagenta: "#6c71c4",
			brightCyan: "#93a1a1",
			brightWhite: "#fdf6e3",
		},
	},
	"solarized-light": {
		name: "Solarized Light",
		colors: {
			foreground: "#657b83",
			background: "#fdf6e3",
			cursor: "#657b83",
			cursorAccent: "#fdf6e3",
			selectionBackground: "#eee8d5",
			selectionForeground: "#586e75",
			selectionInactiveBackground: "#eee8d580",
			black: "#073642",
			red: "#dc322f",
			green: "#859900",
			yellow: "#b58900",
			blue: "#268bd2",
			magenta: "#d33682",
			cyan: "#2aa198",
			white: "#eee8d5",
			brightBlack: "#002b36",
			brightRed: "#cb4b16",
			brightGreen: "#586e75",
			brightYellow: "#657b83",
			brightBlue: "#839496",
			brightMagenta: "#6c71c4",
			brightCyan: "#93a1a1",
			brightWhite: "#fdf6e3",
		},
	},
	monokai: {
		name: "Monokai",
		colors: {
			foreground: "#f8f8f2",
			background: "#272822",
			cursor: "#f8f8f0",
			cursorAccent: "#272822",
			selectionBackground: "#49483e",
			selectionForeground: "#f8f8f2",
			selectionInactiveBackground: "#49483e80",
			black: "#272822",
			red: "#f92672",
			green: "#a6e22e",
			yellow: "#f4bf75",
			blue: "#66d9ef",
			magenta: "#ae81ff",
			cyan: "#a1efe4",
			white: "#f8f8f2",
			brightBlack: "#75715e",
			brightRed: "#f92672",
			brightGreen: "#a6e22e",
			brightYellow: "#f4bf75",
			brightBlue: "#66d9ef",
			brightMagenta: "#ae81ff",
			brightCyan: "#a1efe4",
			brightWhite: "#f9f8f5",
		},
	},
	nord: {
		name: "Nord",
		colors: {
			foreground: "#d8dee9",
			background: "#2e3440",
			cursor: "#d8dee9",
			cursorAccent: "#2e3440",
			selectionBackground: "#434c5e",
			selectionForeground: "#d8dee9",
			selectionInactiveBackground: "#434c5e80",
			black: "#3b4252",
			red: "#bf616a",
			green: "#a3be8c",
			yellow: "#ebcb8b",
			blue: "#81a1c1",
			magenta: "#b48ead",
			cyan: "#88c0d0",
			white: "#e5e9f0",
			brightBlack: "#4c566a",
			brightRed: "#bf616a",
			brightGreen: "#a3be8c",
			brightYellow: "#ebcb8b",
			brightBlue: "#81a1c1",
			brightMagenta: "#b48ead",
			brightCyan: "#8fbcbb",
			brightWhite: "#eceff4",
		},
	},
	"github-dark": {
		name: "GitHub Dark",
		colors: {
			foreground: "#c9d1d9",
			background: "#0d1117",
			cursor: "#c9d1d9",
			cursorAccent: "#0d1117",
			selectionBackground: "#264f78",
			selectionForeground: "#c9d1d9",
			selectionInactiveBackground: "#264f7880",
			black: "#484f58",
			red: "#ff7b72",
			green: "#3fb950",
			yellow: "#d29922",
			blue: "#58a6ff",
			magenta: "#bc8cff",
			cyan: "#39c5cf",
			white: "#b1bac4",
			brightBlack: "#6e7681",
			brightRed: "#ffa198",
			brightGreen: "#56d364",
			brightYellow: "#e3b341",
			brightBlue: "#79c0ff",
			brightMagenta: "#d2a8ff",
			brightCyan: "#56d4dd",
			brightWhite: "#f0f6fc",
		},
	},
	"github-light": {
		name: "GitHub Light",
		colors: {
			foreground: "#24292f",
			background: "#ffffff",
			cursor: "#044289",
			cursorAccent: "#ffffff",
			selectionBackground: "#0969da33",
			selectionForeground: "#24292f",
			selectionInactiveBackground: "#0969da1a",
			black: "#24292f",
			red: "#cf222e",
			green: "#116329",
			yellow: "#4d2d00",
			blue: "#0969da",
			magenta: "#8250df",
			cyan: "#1b7c83",
			white: "#6e7781",
			brightBlack: "#57606a",
			brightRed: "#a40e26",
			brightGreen: "#1a7f37",
			brightYellow: "#633c01",
			brightBlue: "#218bff",
			brightMagenta: "#a475f9",
			brightCyan: "#3192aa",
			brightWhite: "#8c959f",
		},
	},
	"catppuccin-mocha": {
		name: "Catppuccin Mocha",
		colors: {
			foreground: "#cdd6f4",
			background: "#1e1e2e",
			cursor: "#f5e0dc",
			cursorAccent: "#1e1e2e",
			selectionBackground: "#585b70",
			selectionForeground: "#cdd6f4",
			selectionInactiveBackground: "#585b7080",
			black: "#45475a",
			red: "#f38ba8",
			green: "#a6e3a1",
			yellow: "#f9e2af",
			blue: "#89b4fa",
			magenta: "#f5c2e7",
			cyan: "#94e2d5",
			white: "#bac2de",
			brightBlack: "#585b70",
			brightRed: "#f38ba8",
			brightGreen: "#a6e3a1",
			brightYellow: "#f9e2af",
			brightBlue: "#89b4fa",
			brightMagenta: "#f5c2e7",
			brightCyan: "#94e2d5",
			brightWhite: "#a6adc8",
		},
	},
};

/** Merge global settings with optional host overrides */
export function resolveSettings(
	state: TerminalSettingsState,
	hostId?: string
): TerminalSettings {
	if (!hostId) {
		return state.global;
	}
	const overrides = state.hostOverrides.get(hostId);
	if (!overrides) {
		return state.global;
	}
	return { ...state.global, ...overrides };
}

/** Resolve the final xterm.js ITheme object from settings */
export function resolveTheme(
	settings: TerminalSettings
): Partial<TerminalThemeColors> {
	const preset = BUILTIN_THEMES[settings.themeName] ?? BUILTIN_THEMES.default;
	return { ...preset.colors, ...settings.themeOverrides };
}
```

**Step 2: Run lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: PASS

**Step 3: Commit**

```bash
git add apps/web/src/lib/terminal-themes.ts
git commit -m "feat: add built-in terminal theme presets and resolution functions"
```

---

### Task 3: Create Terminal Settings Provider

**Files:**
- Create: `apps/web/src/components/terminal/terminal-settings-provider.tsx`

**Step 1: Create the provider**

Follow the same Context pattern as `ssh-session-provider.tsx`: `createContext(null)`, typed hook with error throw, named provider component, `useReducer` for state.

```typescript
import type { ReactNode } from "react";
import { createContext, useCallback, useContext, useReducer } from "react";
import { DEFAULT_TERMINAL_SETTINGS } from "@/lib/terminal-themes";
import type {
	HostTerminalOverrides,
	TerminalSettings,
	TerminalSettingsState,
} from "@/types/ssh";

// --- Reducer ---

type TerminalSettingsAction =
	| { type: "UPDATE_GLOBAL"; payload: Partial<TerminalSettings> }
	| {
			type: "UPDATE_HOST_OVERRIDES";
			hostId: string;
			payload: Partial<TerminalSettings>;
	  }
	| { type: "CLEAR_HOST_OVERRIDES"; hostId: string };

function terminalSettingsReducer(
	state: TerminalSettingsState,
	action: TerminalSettingsAction
): TerminalSettingsState {
	switch (action.type) {
		case "UPDATE_GLOBAL":
			return {
				...state,
				global: { ...state.global, ...action.payload },
			};
		case "UPDATE_HOST_OVERRIDES": {
			const next = new Map(state.hostOverrides);
			const existing = next.get(action.hostId) ?? {};
			next.set(action.hostId, { ...existing, ...action.payload });
			return { ...state, hostOverrides: next };
		}
		case "CLEAR_HOST_OVERRIDES": {
			const next = new Map(state.hostOverrides);
			next.delete(action.hostId);
			return { ...state, hostOverrides: next };
		}
	}
}

// --- Context ---

interface TerminalSettingsContextValue {
	clearHostOverrides: (hostId: string) => void;
	getSettingsForHost: (hostId: string) => TerminalSettings;
	settings: TerminalSettings;
	updateGlobal: (partial: Partial<TerminalSettings>) => void;
	updateHostOverrides: (
		hostId: string,
		partial: Partial<TerminalSettings>
	) => void;
}

const TerminalSettingsContext =
	createContext<TerminalSettingsContextValue | null>(null);

export function useTerminalSettings(): TerminalSettingsContextValue {
	const context = useContext(TerminalSettingsContext);
	if (!context) {
		throw new Error(
			"useTerminalSettings must be used within a TerminalSettingsProvider"
		);
	}
	return context;
}

// --- Provider ---

export function TerminalSettingsProvider({
	children,
}: {
	children: ReactNode;
}) {
	const [state, dispatch] = useReducer(terminalSettingsReducer, {
		global: DEFAULT_TERMINAL_SETTINGS,
		hostOverrides: new Map<string, HostTerminalOverrides>(),
	});

	const updateGlobal = useCallback((partial: Partial<TerminalSettings>) => {
		dispatch({ type: "UPDATE_GLOBAL", payload: partial });
	}, []);

	const updateHostOverrides = useCallback(
		(hostId: string, partial: Partial<TerminalSettings>) => {
			dispatch({ type: "UPDATE_HOST_OVERRIDES", hostId, payload: partial });
		},
		[]
	);

	const clearHostOverrides = useCallback((hostId: string) => {
		dispatch({ type: "CLEAR_HOST_OVERRIDES", hostId });
	}, []);

	const getSettingsForHost = useCallback(
		(hostId: string): TerminalSettings => {
			const overrides = state.hostOverrides.get(hostId);
			if (!overrides) {
				return state.global;
			}
			return { ...state.global, ...overrides };
		},
		[state.global, state.hostOverrides]
	);

	return (
		<TerminalSettingsContext.Provider
			value={{
				settings: state.global,
				getSettingsForHost,
				updateGlobal,
				updateHostOverrides,
				clearHostOverrides,
			}}
		>
			{children}
		</TerminalSettingsContext.Provider>
	);
}
```

**Step 2: Run lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: PASS

**Step 3: Commit**

```bash
git add apps/web/src/components/terminal/terminal-settings-provider.tsx
git commit -m "feat: add TerminalSettingsProvider with useReducer state management"
```

---

### Task 4: Update SshTerminal to Consume Settings from Context

**Files:**
- Modify: `apps/web/src/components/ssh/ssh-terminal.tsx`

**Step 1: Replace individual setting props with `hostId` prop and Context consumption**

The new `SshTerminalProps` interface:

```typescript
interface SshTerminalProps {
	hostId: string;
	isActive: boolean;
	onRetry?: () => void;
	sessionId: string;
	status: SshSessionStatus;
}
```

Changes to the component:
1. Import `useTerminalSettings` and `resolveTheme` at the top
2. Remove all individual setting props (`fontSize`, `fontFamily`, `cursorStyle`, `cursorBlink`, `scrollback`)
3. Add `hostId` prop
4. Inside the component body, call `const { getSettingsForHost } = useTerminalSettings()` and `const settings = getSettingsForHost(hostId)`
5. Store settings in the existing `optionsRef` pattern, but now include ALL fields:
   ```typescript
   const optionsRef = useRef(settings);
   optionsRef.current = settings;
   ```
6. In the `Terminal` constructor (inside the `useEffect`), read from `optionsRef.current` and add the new fields:
   ```typescript
   const options = optionsRef.current;
   const theme = resolveTheme(options);
   const terminal = new Terminal({
       allowProposedApi: true,
       cursorBlink: options.cursorBlink,
       cursorStyle: options.cursorStyle,
       cursorInactiveStyle: options.cursorInactiveStyle,
       fontFamily: options.fontFamily,
       fontSize: options.fontSize,
       letterSpacing: options.letterSpacing,
       lineHeight: options.lineHeight,
       scrollback: options.scrollback,
       theme,
   });
   ```

Note: `bellStyle` is not a direct xterm.js Terminal option — it will be handled in a future task if needed (xterm uses `Terminal.onBell` event). For now, just store it in the settings type for data completeness.

**Step 2: Run lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: PASS

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/ssh-terminal.tsx
git commit -m "feat: SshTerminal consumes settings from TerminalSettingsProvider"
```

---

### Task 5: Update SSH Route to Use TerminalSettingsProvider

**Files:**
- Modify: `apps/web/src/routes/ssh/route.tsx`

**Step 1: Remove old settings code and wire up the provider**

Changes:
1. Remove the `TerminalSettings` interface and `DEFAULT_TERMINAL_SETTINGS` constant (lines 32-46)
2. Remove the `terminalSettings` state and the `useEffect` that loads from SQLite (lines 69-95)
3. Import `TerminalSettingsProvider` from `@/components/terminal/terminal-settings-provider`
4. Wrap `SshLayout` with `TerminalSettingsProvider` inside `SshRouteWrapper`:
   ```typescript
   function SshRouteWrapper() {
       return (
           <SshSessionProvider>
               <TerminalSettingsProvider>
                   <SshLayout />
               </TerminalSettingsProvider>
           </SshSessionProvider>
       );
   }
   ```
5. Update `<SshTerminal>` usage — remove individual setting props, add `hostId`:
   ```tsx
   <SshTerminal
       hostId={session.hostId}
       isActive={session.id === activeSessionId}
       key={session.id}
       onRetry={() => retry(session.id)}
       sessionId={session.id}
       status={session.status}
   />
   ```
6. Remove the `Database` import from `@tauri-apps/plugin-sql` if it's no longer used elsewhere in this file. Check: it's still used in `handleFormSubmit` for host CRUD, so keep it.

**Step 2: Run lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: PASS

**Step 3: Commit**

```bash
git add apps/web/src/routes/ssh/route.tsx
git commit -m "feat: wire TerminalSettingsProvider into SSH route, remove SQLite settings"
```

---

### Task 6: Update Terminal Settings Form

**Files:**
- Modify: `apps/web/src/components/settings/terminal-settings-form.tsx`

**Step 1: Rewrite the settings form to use Context**

Changes:
1. Remove `Database` import and all SQLite load/save logic
2. Import `useTerminalSettings` from `@/components/terminal/terminal-settings-provider`
3. Import `BUILTIN_THEMES` from `@/lib/terminal-themes`
4. Replace internal `TerminalSettings` interface and `DEFAULT_SETTINGS` with the Context
5. The component now:
   - Reads `settings` and `updateGlobal` from `useTerminalSettings()`
   - Each form field's `onChange` calls `updateGlobal({ fieldName: newValue })` directly (live updates, no Save button needed for in-memory)
   - OR: keep a local draft state and a Save button that calls `updateGlobal(draft)` — **choose the Save button approach** for consistency with current UX
6. Add new form fields:
   - **Line Height**: number input, min 1.0, max 2.0, step 0.1
   - **Letter Spacing**: number input, min -5, max 10
   - **Cursor Inactive Style**: Select with options: outline, block, bar, underline, none
   - **Bell Style**: Select with options: none, sound, visual, both
   - **Theme**: Select with all keys from `BUILTIN_THEMES` mapped to their display names
7. Remove the old `THEME_ITEMS` constant (was "default"/"dark"/"light")

The form pattern:
```typescript
export function TerminalSettingsForm() {
    const { settings, updateGlobal } = useTerminalSettings();
    const [draft, setDraft] = useState(settings);

    // Sync draft when global settings change externally
    useEffect(() => {
        setDraft(settings);
    }, [settings]);

    const handleSave = useCallback(() => {
        updateGlobal(draft);
        toast.success("Settings saved");
    }, [draft, updateGlobal]);

    // ... form fields using draft state and setDraft ...
}
```

**Step 2: Verify the settings form is reachable**

Check: The `TerminalSettingsForm` is rendered inside the settings route. Ensure that route is also wrapped with `TerminalSettingsProvider`, or move the provider higher in the component tree.

Look at `apps/web/src/routes/ssh/settings.tsx` — if the settings form is rendered at a route that's NOT under `/ssh`, the provider must be lifted. The simplest fix: wrap the app's root layout with `TerminalSettingsProvider`.

Check the route structure and adjust provider placement accordingly.

**Step 3: Run lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: PASS

**Step 4: Commit**

```bash
git add apps/web/src/components/settings/terminal-settings-form.tsx
git commit -m "feat: rewrite terminal settings form to use TerminalSettingsProvider"
```

---

### Task 7: Lint, Verify, and Final Commit

**Files:**
- All modified files

**Step 1: Run full lint check**

Run: `cd apps/web && bun x ultracite check`
Expected: PASS — no errors

**Step 2: Run auto-fix if needed**

Run: `cd apps/web && bun x ultracite fix`

**Step 3: Verify TypeScript compiles**

Run: `cd apps/web && bun x tsc --noEmit`
Expected: No type errors

**Step 4: Commit any remaining fixes**

```bash
git add -A apps/web/src
git commit -m "chore: fix lint and type errors from terminal settings refactor"
```
