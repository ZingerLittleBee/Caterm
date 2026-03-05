# Terminal Settings Persistence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist terminal settings to PostgreSQL via Drizzle, with localStorage caching for instant startup and React Query for state management.

**Architecture:** JSONB storage in PostgreSQL, oRPC API layer, React Query in Provider replacing useReducer, localStorage as offline cache.

**Tech Stack:** Drizzle ORM, oRPC, React Query, localStorage, Zod

---

### Task 1: Update DB Schema to JSONB

**Files:**
- Modify: `packages/db/src/schema/terminal-settings.ts`

**Step 1: Rewrite schema with JSONB columns**

Replace the current individual columns with two JSONB columns:

```typescript
import { jsonb, pgTable, serial, text } from "drizzle-orm/pg-core";
import { user } from "./auth";

export const terminalSettings = pgTable("terminal_settings", {
	id: serial("id").primaryKey(),
	userId: text("user_id")
		.notNull()
		.references(() => user.id, { onDelete: "cascade" })
		.unique(),
	settingsJson: jsonb("settings_json").notNull().default({}),
	hostOverridesJson: jsonb("host_overrides_json").notNull().default({}),
});
```

**Step 2: Generate migration**

Run: `bun run db:generate`
Expected: A new migration file in `packages/db/drizzle/` reflecting the schema change.

**Step 3: Apply migration**

Run: `bun run db:push`
Expected: Database schema updated successfully.

**Step 4: Commit**

```bash
git add packages/db/
git commit -m "feat: migrate terminal_settings schema to JSONB columns"
```

---

### Task 2: Rewrite API Router

**Files:**
- Modify: `packages/api/src/routers/terminal-settings.ts`

**Step 1: Rewrite the router**

The router needs `get` and `upsert` procedures working with the new JSONB schema. Import `DEFAULT_TERMINAL_SETTINGS` type shape for merging defaults.

```typescript
import { db } from "@Caterm/db";
import { terminalSettings } from "@Caterm/db/schema/terminal-settings";
import { eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";

const DEFAULT_GLOBAL = {
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

const terminalSettingsInput = z.object({
	bellStyle: z.enum(["none", "sound", "visual", "both"]).optional(),
	cursorBlink: z.boolean().optional(),
	cursorInactiveStyle: z
		.enum(["outline", "block", "bar", "underline", "none"])
		.optional(),
	cursorStyle: z.enum(["block", "underline", "bar"]).optional(),
	fontFamily: z.string().optional(),
	fontSize: z.number().int().min(8).max(72).optional(),
	letterSpacing: z.number().min(-5).max(10).optional(),
	lineHeight: z.number().min(1.0).max(2.0).optional(),
	scrollback: z.number().int().min(100).max(100_000).optional(),
	themeName: z.string().optional(),
	themeOverrides: z.record(z.string(), z.string().optional()).optional(),
});

export const terminalSettingsRouter = {
	get: protectedProcedure.handler(async ({ context }) => {
		const rows = await db
			.select()
			.from(terminalSettings)
			.where(eq(terminalSettings.userId, context.session.user.id));
		if (rows.length === 0) {
			return { global: DEFAULT_GLOBAL, hostOverrides: {} };
		}
		const row = rows[0];
		return {
			global: { ...DEFAULT_GLOBAL, ...(row.settingsJson as Record<string, unknown>) },
			hostOverrides: (row.hostOverridesJson ?? {}) as Record<string, Record<string, unknown>>,
		};
	}),

	upsert: protectedProcedure
		.input(
			z.object({
				global: terminalSettingsInput.optional(),
				hostOverrides: z
					.record(z.string(), terminalSettingsInput)
					.optional(),
			})
		)
		.handler(async ({ input, context }) => {
			const userId = context.session.user.id;

			const existing = await db
				.select()
				.from(terminalSettings)
				.where(eq(terminalSettings.userId, userId));

			const currentGlobal =
				existing.length > 0
					? (existing[0].settingsJson as Record<string, unknown>)
					: {};
			const currentOverrides =
				existing.length > 0
					? (existing[0].hostOverridesJson as Record<string, unknown>)
					: {};

			const mergedGlobal = input.global
				? { ...currentGlobal, ...input.global }
				: currentGlobal;
			const mergedOverrides = input.hostOverrides
				? { ...currentOverrides, ...input.hostOverrides }
				: currentOverrides;

			await db
				.insert(terminalSettings)
				.values({
					userId,
					settingsJson: mergedGlobal,
					hostOverridesJson: mergedOverrides,
				})
				.onConflictDoUpdate({
					target: terminalSettings.userId,
					set: {
						settingsJson: mergedGlobal,
						hostOverridesJson: mergedOverrides,
					},
				});

			return { success: true };
		}),
};
```

**Step 2: Verify types compile**

Run: `bun run check-types`
Expected: No type errors in `packages/api/`.

**Step 3: Commit**

```bash
git add packages/api/src/routers/terminal-settings.ts
git commit -m "feat: rewrite terminal settings API router for JSONB schema"
```

---

### Task 3: Add localStorage Helper

**Files:**
- Create: `apps/web/src/lib/terminal-settings-cache.ts`

**Step 1: Create the cache helper**

```typescript
import { DEFAULT_TERMINAL_SETTINGS } from "@/lib/terminal-themes";
import type { TerminalSettings } from "@/types/ssh";

const CACHE_KEY = "caterm-terminal-settings";

interface CachedData {
	global: TerminalSettings;
	hostOverrides: Record<string, Partial<TerminalSettings>>;
}

export function readSettingsCache(): CachedData | undefined {
	try {
		const raw = localStorage.getItem(CACHE_KEY);
		if (!raw) return undefined;
		const parsed = JSON.parse(raw) as CachedData;
		return {
			global: { ...DEFAULT_TERMINAL_SETTINGS, ...parsed.global },
			hostOverrides: parsed.hostOverrides ?? {},
		};
	} catch {
		return undefined;
	}
}

export function writeSettingsCache(data: CachedData): void {
	try {
		localStorage.setItem(CACHE_KEY, JSON.stringify(data));
	} catch {
		// localStorage full or unavailable — silently ignore
	}
}
```

**Step 2: Commit**

```bash
git add apps/web/src/lib/terminal-settings-cache.ts
git commit -m "feat: add localStorage cache helpers for terminal settings"
```

---

### Task 4: Rewrite TerminalSettingsProvider with React Query

**Files:**
- Modify: `apps/web/src/components/terminal/terminal-settings-provider.tsx`

**Step 1: Rewrite the provider**

Replace useReducer with useQuery + useMutation. Key points:
- `useQuery` fetches from API, uses `placeholderData` from localStorage cache
- `useMutation` calls API upsert, then invalidates query
- On query success, write to localStorage
- Convert `Record` ↔ `Map` for hostOverrides internally

```typescript
import { useMutation, useQuery } from "@tanstack/react-query";
import { type ReactNode, createContext, useCallback, useContext } from "react";
import {
	DEFAULT_TERMINAL_SETTINGS,
	resolveSettings,
} from "@/lib/terminal-themes";
import {
	readSettingsCache,
	writeSettingsCache,
} from "@/lib/terminal-settings-cache";
import { client, orpc, queryClient } from "@/lib/orpc";
import type {
	HostTerminalOverrides,
	TerminalSettings,
	TerminalSettingsState,
} from "@/types/ssh";

interface TerminalSettingsContextValue {
	clearHostOverrides: (hostId: string) => void;
	getSettingsForHost: (hostId: string) => TerminalSettings;
	isLoading: boolean;
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

interface ApiData {
	global: TerminalSettings;
	hostOverrides: Record<string, Partial<TerminalSettings>>;
}

export function TerminalSettingsProvider({
	children,
}: {
	children: ReactNode;
}) {
	const { data, isLoading } = useQuery({
		...orpc.terminalSettings.get.queryOptions(),
		placeholderData: () => readSettingsCache(),
		select: (raw: ApiData): ApiData => {
			const result = {
				global: { ...DEFAULT_TERMINAL_SETTINGS, ...raw.global },
				hostOverrides: raw.hostOverrides ?? {},
			};
			writeSettingsCache(result);
			return result;
		},
	});

	const upsertMutation = useMutation({
		mutationFn: (input: {
			global?: Partial<TerminalSettings>;
			hostOverrides?: Record<string, Partial<TerminalSettings>>;
		}) => client.terminalSettings.upsert(input),
		onSuccess: () => {
			queryClient.invalidateQueries({
				queryKey: orpc.terminalSettings.get.queryOptions().queryKey,
			});
		},
	});

	const globalSettings = data?.global ?? DEFAULT_TERMINAL_SETTINGS;
	const hostOverridesRecord = data?.hostOverrides ?? {};

	const state: TerminalSettingsState = {
		global: globalSettings,
		hostOverrides: new Map(Object.entries(hostOverridesRecord)),
	};

	const getSettingsForHost = useCallback(
		(hostId: string): TerminalSettings => resolveSettings(state, hostId),
		[state]
	);

	const updateGlobal = useCallback(
		(partial: Partial<TerminalSettings>) => {
			const newGlobal = { ...globalSettings, ...partial };
			// Optimistically update cache
			writeSettingsCache({ global: newGlobal, hostOverrides: hostOverridesRecord });
			queryClient.setQueryData(
				orpc.terminalSettings.get.queryOptions().queryKey,
				{ global: newGlobal, hostOverrides: hostOverridesRecord }
			);
			upsertMutation.mutate({ global: partial });
		},
		[globalSettings, hostOverridesRecord, upsertMutation]
	);

	const updateHostOverrides = useCallback(
		(hostId: string, partial: Partial<TerminalSettings>) => {
			const existing = hostOverridesRecord[hostId] ?? {};
			const newOverrides = {
				...hostOverridesRecord,
				[hostId]: { ...existing, ...partial },
			};
			writeSettingsCache({ global: globalSettings, hostOverrides: newOverrides });
			queryClient.setQueryData(
				orpc.terminalSettings.get.queryOptions().queryKey,
				{ global: globalSettings, hostOverrides: newOverrides }
			);
			upsertMutation.mutate({ hostOverrides: { [hostId]: { ...existing, ...partial } } });
		},
		[globalSettings, hostOverridesRecord, upsertMutation]
	);

	const clearHostOverrides = useCallback(
		(hostId: string) => {
			const { [hostId]: _, ...rest } = hostOverridesRecord;
			writeSettingsCache({ global: globalSettings, hostOverrides: rest });
			queryClient.setQueryData(
				orpc.terminalSettings.get.queryOptions().queryKey,
				{ global: globalSettings, hostOverrides: rest }
			);
			upsertMutation.mutate({ hostOverrides: rest });
		},
		[globalSettings, hostOverridesRecord, upsertMutation]
	);

	return (
		<TerminalSettingsContext.Provider
			value={{
				settings: globalSettings,
				isLoading,
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

**Step 2: Verify types compile**

Run: `bun run check-types`
Expected: No type errors.

**Step 3: Commit**

```bash
git add apps/web/src/components/terminal/terminal-settings-provider.tsx
git commit -m "feat: rewrite TerminalSettingsProvider with React Query and localStorage cache"
```

---

### Task 5: Wire Up Loading State in Settings Form

**Files:**
- Modify: `apps/web/src/components/settings/terminal-settings-form.tsx`

**Step 1: Add loading state handling**

Add `isLoading` from context. When loading and no cached data, show a skeleton/spinner. Disable save button during loading.

```typescript
// At top of TerminalSettingsForm:
const { settings, updateGlobal, isLoading } = useTerminalSettings();

// Before the form return, add early return for loading:
if (isLoading) {
	return (
		<div className="flex max-w-lg flex-col gap-6">
			<p className="text-muted-foreground">Loading settings...</p>
		</div>
	);
}
```

**Step 2: Verify types compile**

Run: `bun run check-types`
Expected: No type errors.

**Step 3: Commit**

```bash
git add apps/web/src/components/settings/terminal-settings-form.tsx
git commit -m "feat: add loading state to terminal settings form"
```

---

### Task 6: Verify End-to-End and Clean Up

**Step 1: Run full type check**

Run: `bun run check-types`
Expected: No type errors across all packages.

**Step 2: Run linter**

Run: `bun x ultracite check`
Expected: No lint errors (or only pre-existing ones).

**Step 3: Manual verification checklist**

- [ ] `bun run dev` starts without errors
- [ ] Navigate to `/ssh/settings`, form loads with defaults (or cached data)
- [ ] Change a setting, click Save → data persists across page refresh
- [ ] Open a terminal → settings from context apply correctly
- [ ] Clear localStorage → reload → shows loading state, then loads from server

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address review feedback for terminal settings persistence"
```
