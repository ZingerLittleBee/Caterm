# Cross-Device Restore Internal Beta Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make synced SSH hosts and global terminal settings hydrate reliably on `/ssh` and `/sftp`, with explicit degraded-state UI and immediate server reconciliation for the internal beta.

**Architecture:** Keep `beforeLoad` focused on auth gating. Use route `loader` to prefetch the sync-critical queries into TanStack Query, suppress global query toasts for these domains, and let `HostList` and `TerminalSettingsProvider` render inline degraded states from query state instead of inventing a second hydration store.

**Tech Stack:** Bun, React 19, TanStack Router, TanStack Query, oRPC, Better Auth, Sonner, Biome/Ultracite

---

## File Structure

### Existing files to modify

- `apps/web/src/lib/orpc.ts`
  Add a query-meta escape hatch so sync hydration failures do not show global toasts.

- `apps/web/src/main.tsx`
  Pass `queryClient` into TanStack Router context.

- `apps/web/src/routes/__root.tsx`
  Type the router context to include `queryClient`.

- `apps/web/src/routes/ssh/route.tsx`
  Keep auth gating in `beforeLoad`, add data prefetch in `loader`, and wire route-level session verification failure UI.

- `apps/web/src/routes/sftp/route.tsx`
  Mirror the `/ssh` route pattern, but only prefetch synced hosts.

- `apps/web/src/components/hosts/host-list.tsx`
  Render loading/error/empty/list states explicitly for synced host hydration.

- `apps/web/src/components/terminal/terminal-settings-provider.tsx`
  Change terminal settings hydration to `placeholderData + staleTime: 0`, expose retry/error/read-only fallback state, and prevent writes while running on fallback data.

- `apps/web/src/components/settings/terminal-settings-form.tsx`
  Respect provider read-only fallback state and stop saving from cached/default fallback data.

- `apps/web/src/routes/ssh/index.tsx`
  Show a terminal settings sync banner in the main SSH workspace.

- `apps/web/src/routes/ssh/settings.tsx`
  Show the same sync banner above the settings form.

- `biome.json`
  Exclude `.claude/worktrees/**` so `bun run check` works from the repository root.

### New files to create

- `apps/web/src/lib/sync-query-options.ts`
  Centralize the exact query options for synced hosts and terminal settings so route loaders and UI hooks stay in lockstep.

- `apps/web/src/lib/sync-prefetch.ts`
  Provide reusable prefetch helpers for `/ssh` and `/sftp` loaders.

- `apps/web/src/lib/sync-prefetch.test.ts`
  Unit-test the settled-result prefetch orchestration.

- `apps/web/src/lib/route-auth.ts`
  Wrap `authClient.getSession()` and distinguish redirect vs transport/server verification failure.

- `apps/web/src/lib/route-auth.test.ts`
  Unit-test session gate outcome derivation.

- `apps/web/src/components/auth/session-route-error.tsx`
  Blocking route-level retry UI for session verification failures.

- `apps/web/src/lib/sync-status.ts`
  Pure UI-state helpers for host list and terminal settings fallback states.

- `apps/web/src/lib/sync-status.test.ts`
  Unit-tests for host and terminal sync presentation rules.

- `apps/web/src/components/sync/sync-status-banner.tsx`
  Reusable inline error banner for host/settings sync failures.

- `apps/web/src/components/terminal/terminal-settings-sync-banner.tsx`
  Thin wrapper over the shared banner for SSH surfaces.

- `docs/internal-beta-checklist.md`
  Manual verification checklist and explicit beta limitations.

## Task 1: Router Context, Sync Query Options, and Prefetch Helpers

**Files:**
- Create: `apps/web/src/lib/sync-query-options.ts`
- Create: `apps/web/src/lib/sync-prefetch.ts`
- Test: `apps/web/src/lib/sync-prefetch.test.ts`
- Modify: `apps/web/src/lib/orpc.ts`
- Modify: `apps/web/src/main.tsx`
- Modify: `apps/web/src/routes/__root.tsx`

- [ ] **Step 1: Write the failing prefetch test**

```ts
// apps/web/src/lib/sync-prefetch.test.ts
import { expect, test } from 'bun:test';

import { runPrefetchBundle } from './sync-prefetch';

test('runPrefetchBundle returns settled results without short-circuiting when one request fails', async () => {
  const result = await runPrefetchBundle({
    hosts: async () => 'hosts-ok',
    settings: async () => {
      throw new Error('settings-down');
    },
  });

  expect(result.hosts.status).toBe('fulfilled');
  expect(result.settings?.status).toBe('rejected');
});

test('runPrefetchBundle omits settings result for routes that only need hosts', async () => {
  const result = await runPrefetchBundle({
    hosts: async () => 'hosts-ok',
  });

  expect(result.hosts.status).toBe('fulfilled');
  expect(result.settings).toBeUndefined();
});

test('runPrefetchBundle starts hosts and settings prefetchers in the same turn', async () => {
  const calls: string[] = [];

  await runPrefetchBundle({
    hosts: async () => {
      calls.push('hosts');
      return 'hosts-ok';
    },
    settings: async () => {
      calls.push('settings');
      return 'settings-ok';
    },
  });

  expect(calls).toEqual(['hosts', 'settings']);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bun test apps/web/src/lib/sync-prefetch.test.ts
```

Expected:

- FAIL with `Cannot find module './sync-prefetch'` or `runPrefetchBundle is not exported`

- [ ] **Step 3: Write the minimal implementation and router plumbing**

```ts
// apps/web/src/lib/sync-query-options.ts
import { orpc } from '@/lib/orpc';

export function getSshHostsSyncQueryOptions() {
  return {
    ...orpc.sshHost.list.queryOptions(),
    meta: {
      suppressGlobalErrorToast: true,
    } as const,
  };
}

export function getTerminalSettingsSyncQueryOptions() {
  return {
    ...orpc.terminalSettings.get.queryOptions(),
    staleTime: 0,
    meta: {
      suppressGlobalErrorToast: true,
    } as const,
  };
}
```

```ts
// apps/web/src/lib/sync-prefetch.ts
import type { QueryClient } from '@tanstack/react-query';

import { getSshHostsSyncQueryOptions, getTerminalSettingsSyncQueryOptions } from '@/lib/sync-query-options';

type Prefetcher = () => Promise<unknown>;

export interface RoutePrefetchResult {
  hosts: PromiseSettledResult<unknown>;
  settings?: PromiseSettledResult<unknown>;
}

function settle(prefetcher: Prefetcher): Promise<PromiseSettledResult<unknown>> {
  return Promise.resolve(prefetcher()).then(
    (value) => ({ status: 'fulfilled', value } as const),
    (reason) => ({ status: 'rejected', reason } as const)
  );
}

export async function runPrefetchBundle(prefetchers: {
  hosts: Prefetcher;
  settings?: Prefetcher;
}): Promise<RoutePrefetchResult> {
  if (!prefetchers.settings) {
    const hosts = await settle(prefetchers.hosts);
    return { hosts };
  }

  const [hosts, settings] = await Promise.all([
    settle(prefetchers.hosts),
    settle(prefetchers.settings),
  ]);

  return { hosts, settings };
}

export function prefetchSshRouteData(queryClient: QueryClient) {
  return runPrefetchBundle({
    hosts: () => queryClient.fetchQuery(getSshHostsSyncQueryOptions()),
    settings: () => queryClient.fetchQuery(getTerminalSettingsSyncQueryOptions()),
  });
}

export function prefetchSftpRouteData(queryClient: QueryClient) {
  return runPrefetchBundle({
    hosts: () => queryClient.fetchQuery(getSshHostsSyncQueryOptions()),
  });
}
```

```ts
// apps/web/src/lib/orpc.ts
import type { AppRouter } from '@Caterm/api/routers/index';
import { createORPCClient } from '@orpc/client';
import { RPCLink } from '@orpc/client/fetch';
import type { RouterClient } from '@orpc/server';
import { createTanstackQueryUtils } from '@orpc/tanstack-query';
import { QueryCache, QueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';

const serverUrl = import.meta.env.VITE_SERVER_URL || 'http://localhost:3002';

export const queryClient = new QueryClient({
  queryCache: new QueryCache({
    onError: (error, query) => {
      if (query.meta?.suppressGlobalErrorToast === true) {
        return;
      }

      toast.error(`Error: ${error.message}`, {
        action: {
          label: 'retry',
          onClick: query.invalidate,
        },
      });
    },
  }),
});

const link = new RPCLink({
  url: `${serverUrl}/api/rpc`,
  fetch(url, options) {
    return fetch(url, {
      ...options,
      credentials: 'include',
    });
  },
});

export const client: RouterClient<AppRouter> = createORPCClient(link);

export const orpc = createTanstackQueryUtils(client);
```

```ts
// apps/web/src/routes/__root.tsx
import { QueryClientProvider } from '@tanstack/react-query';
import { createRootRouteWithContext, HeadContent, Outlet } from '@tanstack/react-router';
import { TanStackRouterDevtools } from '@tanstack/react-router-devtools';
import { ThemeProvider } from '@/components/theme-provider';
import { Toaster } from '@/components/ui/sonner';
import { queryClient } from '@/lib/orpc';

import '../index.css';

export interface RouterAppContext {
  queryClient: typeof queryClient;
}

export const Route = createRootRouteWithContext<RouterAppContext>()({
  component: RootComponent,
  head: () => ({
    meta: [
      {
        title: 'Caterm',
      },
      {
        name: 'description',
        content: 'Caterm is a web application',
      },
    ],
    links: [
      {
        rel: 'icon',
        href: '/favicon.ico',
      },
    ],
  }),
});

function RootComponent() {
  return (
    <>
      <HeadContent />
      <ThemeProvider attribute="class" defaultTheme="dark" disableTransitionOnChange storageKey="vite-ui-theme">
        <QueryClientProvider client={queryClient}>
          <div className="grid h-svh grid-rows-[auto_1fr] overflow-hidden">
            <Outlet />
          </div>
          <Toaster richColors />
        </QueryClientProvider>
      </ThemeProvider>
      <TanStackRouterDevtools position="bottom-left" />
    </>
  );
}
```

```ts
// apps/web/src/main.tsx
import { createRouter, RouterProvider } from '@tanstack/react-router';
import ReactDOM from 'react-dom/client';

import Loader from './components/loader';
import { queryClient } from './lib/orpc';
import { routeTree } from './routeTree.gen';

const router = createRouter({
  routeTree,
  defaultPreload: 'intent',
  defaultPendingComponent: () => <Loader />,
  context: {
    queryClient,
  },
});

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}

const rootElement = document.getElementById('app');

if (!rootElement) {
  throw new Error('Root element not found');
}

if (!rootElement.innerHTML) {
  const root = ReactDOM.createRoot(rootElement);
  root.render(<RouterProvider router={router} />);
}
```

- [ ] **Step 4: Run the unit test and confirm it passes**

Run:

```bash
bun test apps/web/src/lib/sync-prefetch.test.ts
```

Expected:

- PASS for all three `runPrefetchBundle` tests

- [ ] **Step 5: Run the type check**

Run:

```bash
bun run check-types
```

Expected:

- PASS for all workspaces

- [ ] **Step 6: Commit**

```bash
git add apps/web/src/lib/orpc.ts apps/web/src/lib/sync-query-options.ts apps/web/src/lib/sync-prefetch.ts apps/web/src/lib/sync-prefetch.test.ts apps/web/src/main.tsx apps/web/src/routes/__root.tsx
git commit -m "feat: add sync prefetch plumbing"
```

## Task 2: Session Gate Helper, Blocking Session Error UI, and Route Loaders

**Files:**
- Create: `apps/web/src/lib/route-auth.ts`
- Create: `apps/web/src/lib/route-auth.test.ts`
- Create: `apps/web/src/components/auth/session-route-error.tsx`
- Modify: `apps/web/src/routes/ssh/route.tsx`
- Modify: `apps/web/src/routes/sftp/route.tsx`

- [ ] **Step 1: Write the failing auth gate test**

```ts
// apps/web/src/lib/route-auth.test.ts
import { expect, test } from 'bun:test';

import { getSessionGateOutcome } from './route-auth';

test('getSessionGateOutcome returns redirect when there is no session data', () => {
  expect(getSessionGateOutcome({ data: null, error: null })).toBe('redirect');
});

test('getSessionGateOutcome returns error when verification fails', () => {
  expect(getSessionGateOutcome({ data: null, error: { message: 'network-down' } })).toBe('error');
});

test('getSessionGateOutcome returns authenticated when session data exists', () => {
  expect(getSessionGateOutcome({ data: { user: { id: 'u_1' } }, error: null })).toBe('authenticated');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bun test apps/web/src/lib/route-auth.test.ts
```

Expected:

- FAIL with `Cannot find module './route-auth'` or missing export

- [ ] **Step 3: Write the minimal auth gate and route loader implementation**

```ts
// apps/web/src/lib/route-auth.ts
import { redirect } from '@tanstack/react-router';

import { authClient } from '@/lib/auth-client';

export interface SessionGatePayload {
  data: unknown | null;
  error?: { message?: string } | null;
}

export class SessionVerificationError extends Error {
  constructor(message = 'Failed to verify your session. Retry to continue.') {
    super(message);
    this.name = 'SessionVerificationError';
  }
}

export function getSessionGateOutcome(payload: SessionGatePayload): 'authenticated' | 'redirect' | 'error' {
  if (payload.error) {
    return 'error';
  }

  if (!payload.data) {
    return 'redirect';
  }

  return 'authenticated';
}

export async function requireAuthenticatedSession() {
  const result = await authClient.getSession();
  const outcome = getSessionGateOutcome(result);

  if (outcome === 'error') {
    throw new SessionVerificationError(result.error?.message ?? undefined);
  }

  if (outcome === 'redirect') {
    throw redirect({ to: '/login' });
  }

  return result.data;
}
```

```tsx
// apps/web/src/components/auth/session-route-error.tsx
import { Button } from '@/components/ui/button';
import { SessionVerificationError } from '@/lib/route-auth';

export function SessionRouteError({ error }: { error: unknown }) {
  if (!(error instanceof SessionVerificationError)) {
    throw error;
  }

  return (
    <div className="flex h-svh items-center justify-center p-6">
      <div className="flex max-w-md flex-col gap-4 rounded-xl border bg-background p-6 shadow-sm">
        <div>
          <h1 className="font-semibold text-lg">Session verification failed</h1>
          <p className="mt-2 text-muted-foreground text-sm">
            {error.message}
          </p>
        </div>

        <Button onClick={() => window.location.reload()} type="button">
          Retry
        </Button>
      </div>
    </div>
  );
}
```

```tsx
// apps/web/src/routes/ssh/route.tsx
import { createFileRoute, Outlet } from '@tanstack/react-router';
import { SessionRouteError } from '@/components/auth/session-route-error';
import { SftpProvider } from '@/components/sftp/sftp-provider';
import { SshSessionProvider } from '@/components/ssh/ssh-session-provider';
import { TerminalSettingsProvider } from '@/components/terminal/terminal-settings-provider';
import { requireAuthenticatedSession } from '@/lib/route-auth';
import { prefetchSshRouteData } from '@/lib/sync-prefetch';

export const Route = createFileRoute('/ssh')({
  beforeLoad: async () => {
    await requireAuthenticatedSession();
  },
  loader: ({ context }) => prefetchSshRouteData(context.queryClient),
  errorComponent: ({ error }) => <SessionRouteError error={error} />,
  component: SshRouteLayout
});

function SshRouteLayout() {
  return (
    <TerminalSettingsProvider>
      <SshSessionProvider>
        <SftpProvider>
          <Outlet />
        </SftpProvider>
      </SshSessionProvider>
    </TerminalSettingsProvider>
  );
}
```

```tsx
// apps/web/src/routes/sftp/route.tsx
import { createFileRoute, Outlet } from '@tanstack/react-router';
import { SessionRouteError } from '@/components/auth/session-route-error';
import { SftpProvider } from '@/components/sftp/sftp-provider';
import { requireAuthenticatedSession } from '@/lib/route-auth';
import { prefetchSftpRouteData } from '@/lib/sync-prefetch';

export const Route = createFileRoute('/sftp')({
  beforeLoad: async () => {
    await requireAuthenticatedSession();
  },
  loader: ({ context }) => prefetchSftpRouteData(context.queryClient),
  errorComponent: ({ error }) => <SessionRouteError error={error} />,
  component: SftpRouteLayout
});

function SftpRouteLayout() {
  return (
    <SftpProvider>
      <Outlet />
    </SftpProvider>
  );
}
```

- [ ] **Step 4: Run the auth gate unit test**

Run:

```bash
bun test apps/web/src/lib/route-auth.test.ts
```

Expected:

- PASS for all three session gate cases

- [ ] **Step 5: Run the type check**

Run:

```bash
bun run check-types
```

Expected:

- PASS for all workspaces

- [ ] **Step 6: Commit**

```bash
git add apps/web/src/lib/route-auth.ts apps/web/src/lib/route-auth.test.ts apps/web/src/components/auth/session-route-error.tsx apps/web/src/routes/ssh/route.tsx apps/web/src/routes/sftp/route.tsx
git commit -m "feat: add session gate and sync route loaders"
```

## Task 3: Host List Degraded State and Shared Sync Banner

**Files:**
- Create: `apps/web/src/lib/sync-status.ts`
- Test: `apps/web/src/lib/sync-status.test.ts`
- Create: `apps/web/src/components/sync/sync-status-banner.tsx`
- Modify: `apps/web/src/components/hosts/host-list.tsx`

- [ ] **Step 1: Write the failing host status test**

```ts
// apps/web/src/lib/sync-status.test.ts
import { expect, test } from 'bun:test';

import { getHostSyncPresentation } from './sync-status';

test('host fetch failure disables actions and hides the empty state', () => {
  expect(
    getHostSyncPresentation({
      hostCount: 0,
      isError: true,
      isPending: false,
    })
  ).toEqual({
    banner: {
      title: 'SSH hosts unavailable',
      description: 'Failed to sync your saved SSH hosts. Retry to restore them.',
    },
    disableActions: true,
    showEmptyState: false,
    showLoadingState: false,
  });
});

test('host initial load shows loading state instead of empty state', () => {
  expect(
    getHostSyncPresentation({
      hostCount: 0,
      isError: false,
      isPending: true,
    })
  ).toEqual({
    banner: null,
    disableActions: true,
    showEmptyState: false,
    showLoadingState: true,
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bun test apps/web/src/lib/sync-status.test.ts
```

Expected:

- FAIL with `Cannot find module './sync-status'`

- [ ] **Step 3: Implement the host status rules, banner component, and host list UI**

```ts
// apps/web/src/lib/sync-status.ts
export interface SyncBannerCopy {
  title: string;
  description: string;
}

export function getHostSyncPresentation(input: {
  hostCount: number;
  isError: boolean;
  isPending: boolean;
}) {
  if (input.isError) {
    return {
      banner: {
        title: 'SSH hosts unavailable',
        description: 'Failed to sync your saved SSH hosts. Retry to restore them.',
      } satisfies SyncBannerCopy,
      disableActions: true,
      showEmptyState: false,
      showLoadingState: false,
    };
  }

  if (input.isPending && input.hostCount === 0) {
    return {
      banner: null,
      disableActions: true,
      showEmptyState: false,
      showLoadingState: true,
    };
  }

  return {
    banner: null,
    disableActions: false,
    showEmptyState: input.hostCount === 0,
    showLoadingState: false,
  };
}

export function getTerminalSettingsPresentation(input: {
  hasCachedSettings: boolean;
  hasError: boolean;
  hasSuccessfulServerSync: boolean;
}) {
  if (input.hasError) {
    return {
      allowEditing: false,
      banner: {
        title: 'Terminal settings out of sync',
        description: input.hasCachedSettings
          ? 'Using cached terminal settings until sync succeeds.'
          : 'Using built-in terminal defaults until sync succeeds.',
      } satisfies SyncBannerCopy,
    };
  }

  return {
    allowEditing: input.hasSuccessfulServerSync,
    banner: null,
  };
}
```

```tsx
// apps/web/src/components/sync/sync-status-banner.tsx
import { Button } from '@/components/ui/button';

interface SyncStatusBannerProps {
  description: string;
  onRetry?: () => void;
  title: string;
}

export function SyncStatusBanner({ title, description, onRetry }: SyncStatusBannerProps) {
  return (
    <div className="rounded-lg border border-destructive/30 bg-destructive/5 px-3 py-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium text-sm">{title}</p>
          <p className="mt-1 text-muted-foreground text-sm">{description}</p>
        </div>
        {onRetry ? (
          <Button onClick={onRetry} size="sm" type="button" variant="outline">
            Retry
          </Button>
        ) : null}
      </div>
    </div>
  );
}
```

```tsx
// apps/web/src/components/hosts/host-list.tsx
import { useMutation, useQuery } from '@tanstack/react-query';
import { Loader2, PlusIcon } from 'lucide-react';
import { useCallback, useState } from 'react';
import { toast } from 'sonner';
import { SyncStatusBanner } from '@/components/sync/sync-status-banner';
import {
  SidebarGroup,
  SidebarGroupAction,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu
} from '@/components/ui/sidebar';
import { getHostSyncPresentation } from '@/lib/sync-status';
import { getSshHostsSyncQueryOptions } from '@/lib/sync-query-options';
import { orpc, queryClient } from '@/lib/orpc';
import type { SshHost } from '@/types/ssh';
import { HostCard } from './host-card';
import { HostDeleteDialog } from './host-delete-dialog';

interface HostListProps {
  onConnect: (host: SshHost) => void;
  onEdit: (host: SshHost) => void;
  onNewHost: () => void;
}

export function HostList({ onConnect, onEdit, onNewHost }: HostListProps) {
  const [deleteTarget, setDeleteTarget] = useState<SshHost | null>(null);

  const {
    data: hosts = [],
    error,
    isError,
    isPending,
    refetch
  } = useQuery(getSshHostsSyncQueryOptions());

  const presentation = getHostSyncPresentation({
    hostCount: hosts.length,
    isError,
    isPending
  });

  const deleteMutation = useMutation({
    ...orpc.sshHost.delete.mutationOptions(),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: orpc.sshHost.list.queryOptions().queryKey
      });
      setDeleteTarget(null);
    }
  });

  const handleDelete = useCallback(
    async (host: SshHost) => {
      try {
        await deleteMutation.mutateAsync({ id: host.id });
      } catch (caughtError) {
        const message = caughtError instanceof Error ? caughtError.message : String(caughtError);
        toast.error('Failed to delete host', { description: message });
      }
    },
    [deleteMutation]
  );

  return (
    <SidebarGroup>
      <SidebarGroupLabel>Hosts</SidebarGroupLabel>
      <SidebarGroupAction
        disabled={presentation.disableActions}
        onClick={() => {
          if (!presentation.disableActions) {
            onNewHost();
          }
        }}
      >
        <PlusIcon />
        <span className="sr-only">Add host</span>
      </SidebarGroupAction>
      <SidebarGroupContent>
        {presentation.banner ? (
          <div className="px-2 pb-2">
            <SyncStatusBanner
              description={
                error instanceof Error
                  ? `${presentation.banner.description} ${error.message}`
                  : presentation.banner.description
              }
              onRetry={() => {
                void refetch();
              }}
              title={presentation.banner.title}
            />
          </div>
        ) : null}

        <SidebarMenu>
          {presentation.showLoadingState ? (
            <div className="flex items-center justify-center px-2 py-8 text-muted-foreground text-sm">
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              Syncing hosts...
            </div>
          ) : null}

          {presentation.showEmptyState ? (
            <p className="px-2 py-8 text-center text-muted-foreground text-sm">
              No hosts configured. Click + to add one.
            </p>
          ) : null}

          {!presentation.showLoadingState && !presentation.showEmptyState && !presentation.banner
            ? hosts.map((host) => (
                <HostCard host={host} key={host.id} onConnect={onConnect} onDelete={setDeleteTarget} onEdit={onEdit} />
              ))
            : null}
        </SidebarMenu>
      </SidebarGroupContent>
      <HostDeleteDialog
        host={deleteTarget}
        onCancel={() => setDeleteTarget(null)}
        onConfirm={handleDelete}
        open={deleteTarget !== null}
      />
    </SidebarGroup>
  );
}
```

- [ ] **Step 4: Run the host status unit test**

Run:

```bash
bun test apps/web/src/lib/sync-status.test.ts
```

Expected:

- PASS for the two host-list presentation tests

- [ ] **Step 5: Run the type check**

Run:

```bash
bun run check-types
```

Expected:

- PASS for all workspaces

- [ ] **Step 6: Commit**

```bash
git add apps/web/src/lib/sync-status.ts apps/web/src/lib/sync-status.test.ts apps/web/src/components/sync/sync-status-banner.tsx apps/web/src/components/hosts/host-list.tsx
git commit -m "feat: add host sync degraded states"
```

## Task 4: Terminal Settings Immediate Reconcile, Read-Only Fallback, and SSH Sync Banner

**Files:**
- Modify: `apps/web/src/lib/sync-status.test.ts`
- Create: `apps/web/src/components/terminal/terminal-settings-sync-banner.tsx`
- Modify: `apps/web/src/components/terminal/terminal-settings-provider.tsx`
- Modify: `apps/web/src/components/settings/terminal-settings-form.tsx`
- Modify: `apps/web/src/routes/ssh/index.tsx`
- Modify: `apps/web/src/routes/ssh/settings.tsx`

- [ ] **Step 1: Extend the failing sync-status test for terminal settings fallback**

```ts
// append to apps/web/src/lib/sync-status.test.ts
import { getTerminalSettingsPresentation } from './sync-status';

test('terminal settings error keeps rendering on fallback but disables editing', () => {
  expect(
    getTerminalSettingsPresentation({
      hasCachedSettings: true,
      hasError: true,
      hasSuccessfulServerSync: false,
    })
  ).toEqual({
    allowEditing: false,
    banner: {
      title: 'Terminal settings out of sync',
      description: 'Using cached terminal settings until sync succeeds.',
    },
  });
});

test('terminal settings allow editing only after a successful server sync', () => {
  expect(
    getTerminalSettingsPresentation({
      hasCachedSettings: false,
      hasError: false,
      hasSuccessfulServerSync: true,
    })
  ).toEqual({
    allowEditing: true,
    banner: null,
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bun test apps/web/src/lib/sync-status.test.ts
```

Expected:

- FAIL because `getTerminalSettingsPresentation` is missing or returns the wrong shape

- [ ] **Step 3: Implement provider fallback state, banner component, and form gating**

```tsx
// apps/web/src/components/terminal/terminal-settings-sync-banner.tsx
import { SyncStatusBanner } from '@/components/sync/sync-status-banner';
import { useTerminalSettings } from '@/components/terminal/terminal-settings-provider';

export function TerminalSettingsSyncBanner() {
  const { isReadOnlyFallback, retrySync, syncBanner } = useTerminalSettings();

  if (!(isReadOnlyFallback && syncBanner)) {
    return null;
  }

  return (
    <SyncStatusBanner
      description={syncBanner.description}
      onRetry={() => {
        void retrySync();
      }}
      title={syncBanner.title}
    />
  );
}
```

```ts
// apps/web/src/components/terminal/terminal-settings-provider.tsx
import { useMutation, useQuery } from '@tanstack/react-query';
import { createContext, type ReactNode, useCallback, useContext, useEffect, useMemo } from 'react';
import { toast } from 'sonner';
import { queryClient } from '@/lib/orpc';
import { readSettingsCache, writeSettingsCache } from '@/lib/terminal-settings-cache';
import { getTerminalSettingsSyncQueryOptions } from '@/lib/sync-query-options';
import { getTerminalSettingsPresentation, type SyncBannerCopy } from '@/lib/sync-status';
import { DEFAULT_TERMINAL_SETTINGS, resolveSettings } from '@/lib/terminal-themes';
import type { TerminalSettings, TerminalSettingsState } from '@/types/ssh';

interface TerminalSettingsContextValue {
  clearHostOverrides: (hostId: string) => void;
  getSettingsForHost: (hostId: string) => TerminalSettings;
  isLoading: boolean;
  isReadOnlyFallback: boolean;
  retrySync: () => Promise<unknown>;
  settings: TerminalSettings;
  syncBanner: SyncBannerCopy | null;
  updateGlobal: (partial: Partial<TerminalSettings>) => void;
  updateHostOverrides: (hostId: string, partial: Partial<TerminalSettings>) => void;
}

const TerminalSettingsContext = createContext<TerminalSettingsContextValue | null>(null);

export function useTerminalSettings(): TerminalSettingsContextValue {
  const context = useContext(TerminalSettingsContext);

  if (!context) {
    throw new Error('useTerminalSettings must be used within a TerminalSettingsProvider');
  }

  return context;
}

function normalizeApiData(raw: unknown): {
  global: TerminalSettings;
  hostOverrides: Record<string, Partial<TerminalSettings>>;
} {
  if (!raw || typeof raw !== 'object') {
    return { global: DEFAULT_TERMINAL_SETTINGS, hostOverrides: {} };
  }

  const rawData = raw as {
    global?: Record<string, unknown>;
    hostOverrides?: Record<string, Partial<TerminalSettings>>;
  };

  return {
    global: {
      ...DEFAULT_TERMINAL_SETTINGS,
      ...rawData.global,
    } as TerminalSettings,
    hostOverrides: (rawData.hostOverrides ?? {}) as Record<string, Partial<TerminalSettings>>,
  };
}

type SettingsData = ReturnType<typeof normalizeApiData>;

export function TerminalSettingsProvider({ children }: { children: ReactNode }) {
  const bootCache = useMemo(() => readSettingsCache(), []);

  const {
    data,
    isError,
    isPending,
    isPlaceholderData,
    refetch,
  } = useQuery({
    ...getTerminalSettingsSyncQueryOptions(),
    placeholderData: () => {
      return bootCache ? normalizeApiData(bootCache) : undefined;
    },
    select: (raw) => normalizeApiData(raw),
  });

  useEffect(() => {
    if (data && !isPlaceholderData) {
      writeSettingsCache(data);
    }
  }, [data, isPlaceholderData]);

  const presentation = getTerminalSettingsPresentation({
    hasCachedSettings: bootCache !== undefined,
    hasError: isError,
    hasSuccessfulServerSync: Boolean(data) && !isPlaceholderData && !isError,
  });

  const isReadOnlyFallback = !presentation.allowEditing;

  const upsertMutation = useMutation({
    mutationFn: async (input: {
      global?: Partial<TerminalSettings>;
      hostOverrides?: Record<string, Partial<TerminalSettings>>;
    }) => {
      const { client } = await import('@/lib/orpc');
      return client.terminalSettings.upsert(input);
    },
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: getTerminalSettingsSyncQueryOptions().queryKey });
      const previous = queryClient.getQueryData<SettingsData>(getTerminalSettingsSyncQueryOptions().queryKey);

      queryClient.setQueryData<SettingsData>(getTerminalSettingsSyncQueryOptions().queryKey, (old) => {
        if (!old) {
          return old;
        }

        const nextGlobal = input.global ? { ...old.global, ...input.global } : old.global;
        const nextOverrides = { ...old.hostOverrides };

        if (input.hostOverrides) {
          for (const [hostId, overrideValues] of Object.entries(input.hostOverrides)) {
            nextOverrides[hostId] = {
              ...(nextOverrides[hostId] ?? {}),
              ...overrideValues,
            };
          }
        }

        return {
          global: nextGlobal as TerminalSettings,
          hostOverrides: nextOverrides,
        };
      });

      return { previous };
    },
    onError: (_error, _input, context) => {
      if (context?.previous) {
        queryClient.setQueryData(getTerminalSettingsSyncQueryOptions().queryKey, context.previous);
      }

      toast.error('Failed to save settings');
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: getTerminalSettingsSyncQueryOptions().queryKey });
    },
  });

  const deleteHostOverrideMutation = useMutation({
    mutationFn: async (input: { hostId: string }) => {
      const { client } = await import('@/lib/orpc');
      return client.terminalSettings.deleteHostOverride(input);
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: getTerminalSettingsSyncQueryOptions().queryKey });
    },
  });

  const globalSettings = data?.global ?? DEFAULT_TERMINAL_SETTINGS;
  const hostOverridesRecord = data?.hostOverrides ?? {};

  const state: TerminalSettingsState = useMemo(
    () => ({
      global: globalSettings,
      hostOverrides: new Map(Object.entries(hostOverridesRecord)),
    }),
    [globalSettings, hostOverridesRecord]
  );

  const getSettingsForHost = useCallback((hostId: string): TerminalSettings => resolveSettings(state, hostId), [state]);

  const updateGlobal = useCallback(
    (partial: Partial<TerminalSettings>) => {
      if (isReadOnlyFallback) {
        return;
      }

      upsertMutation.mutate({ global: partial });
    },
    [isReadOnlyFallback, upsertMutation]
  );

  const updateHostOverrides = useCallback(
    (hostId: string, partial: Partial<TerminalSettings>) => {
      if (isReadOnlyFallback) {
        return;
      }

      upsertMutation.mutate({
        hostOverrides: { [hostId]: partial },
      });
    },
    [isReadOnlyFallback, upsertMutation]
  );

  const clearHostOverrides = useCallback(
    (hostId: string) => {
      if (isReadOnlyFallback) {
        return;
      }

      deleteHostOverrideMutation.mutate({ hostId });
    },
    [deleteHostOverrideMutation, isReadOnlyFallback]
  );

  const retrySync = useCallback(() => refetch(), [refetch]);

  return (
    <TerminalSettingsContext.Provider
      value={{
        clearHostOverrides,
        getSettingsForHost,
        isLoading: isPending && !data,
        isReadOnlyFallback,
        retrySync,
        settings: globalSettings,
        syncBanner: presentation.banner,
        updateGlobal,
        updateHostOverrides,
      }}
    >
      {children}
    </TerminalSettingsContext.Provider>
  );
}
```

```tsx
// apps/web/src/components/settings/terminal-settings-form.tsx
import { useCallback, useEffect, useState } from 'react';
import { useTerminalSettings } from '@/components/terminal/terminal-settings-provider';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { BUILTIN_THEMES } from '@/lib/terminal-themes';
import type { BellStyle, CursorInactiveStyle, CursorStyle, TerminalSettings } from '@/types/ssh';

export function TerminalSettingsForm() {
  const { settings, updateGlobal, isLoading, isReadOnlyFallback } = useTerminalSettings();
  const [draft, setDraft] = useState<TerminalSettings>(settings);

  useEffect(() => {
    setDraft(settings);
  }, [settings]);

  const handleSave = useCallback(() => {
    updateGlobal(draft);
  }, [draft, updateGlobal]);

  if (isLoading) {
    return (
      <div className="flex max-w-lg flex-col gap-6">
        <p className="text-muted-foreground">Loading settings...</p>
      </div>
    );
  }

  return (
    <div className="flex max-w-lg flex-col gap-6">
      {isReadOnlyFallback ? (
        <p className="rounded-lg border border-border bg-muted/40 px-3 py-2 text-muted-foreground text-sm">
          Settings are temporarily read-only until server sync succeeds.
        </p>
      ) : null}

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-font-family">Font Family</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-font-family"
          onChange={(event) => setDraft((prev) => ({ ...prev, fontFamily: event.target.value }))}
          placeholder="monospace"
          value={draft.fontFamily}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-font-size">Font Size</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-font-size"
          max={32}
          min={8}
          onChange={(event) =>
            setDraft((prev) => ({
              ...prev,
              fontSize: Number.parseInt(event.target.value, 10) || 14,
            }))
          }
          type="number"
          value={String(draft.fontSize)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-line-height">Line Height</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-line-height"
          max={2}
          min={1}
          onChange={(event) =>
            setDraft((prev) => ({
              ...prev,
              lineHeight: Number.parseFloat(event.target.value) || 1,
            }))
          }
          step={0.1}
          type="number"
          value={String(draft.lineHeight)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-letter-spacing">Letter Spacing</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-letter-spacing"
          max={10}
          min={-5}
          onChange={(event) =>
            setDraft((prev) => ({
              ...prev,
              letterSpacing: Number.parseFloat(event.target.value) || 0,
            }))
          }
          type="number"
          value={String(draft.letterSpacing)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label>Cursor Style</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              cursorStyle: value as CursorStyle,
            }))
          }
          value={draft.cursorStyle}
        >
          <SelectTrigger className="w-full">
            <SelectValue placeholder="Select cursor style" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="block">Block</SelectItem>
            <SelectItem value="underline">Underline</SelectItem>
            <SelectItem value="bar">Bar</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex items-center gap-2">
        <Checkbox
          checked={draft.cursorBlink}
          disabled={isReadOnlyFallback}
          id="settings-cursor-blink"
          onCheckedChange={(checked) =>
            setDraft((prev) => ({
              ...prev,
              cursorBlink: Boolean(checked),
            }))
          }
        />
        <Label htmlFor="settings-cursor-blink">Cursor Blink</Label>
      </div>

      <div className="flex flex-col gap-2">
        <Label>Cursor Inactive Style</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              cursorInactiveStyle: value as CursorInactiveStyle,
            }))
          }
          value={draft.cursorInactiveStyle}
        >
          <SelectTrigger className="w-full">
            <SelectValue placeholder="Select inactive cursor style" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="outline">Outline</SelectItem>
            <SelectItem value="block">Block</SelectItem>
            <SelectItem value="bar">Bar</SelectItem>
            <SelectItem value="underline">Underline</SelectItem>
            <SelectItem value="none">None</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-scrollback">Scrollback Lines</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-scrollback"
          max={100_000}
          min={100}
          onChange={(event) =>
            setDraft((prev) => ({
              ...prev,
              scrollback: Number.parseInt(event.target.value, 10) || 1000,
            }))
          }
          type="number"
          value={String(draft.scrollback)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label>Bell Style</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              bellStyle: value as BellStyle,
            }))
          }
          value={draft.bellStyle}
        >
          <SelectTrigger className="w-full">
            <SelectValue placeholder="Select bell style" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="none">None</SelectItem>
            <SelectItem value="sound">Sound</SelectItem>
            <SelectItem value="visual">Visual</SelectItem>
            <SelectItem value="both">Both</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label>Theme</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              themeName: value ?? prev.themeName,
            }))
          }
          value={draft.themeName}
        >
          <SelectTrigger className="w-full">
            <SelectValue placeholder="Select theme" />
          </SelectTrigger>
          <SelectContent>
            {Object.entries(BUILTIN_THEMES).map(([key, preset]) => (
              <SelectItem key={key} value={key}>
                {preset.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="pt-2">
        <Button disabled={isReadOnlyFallback} onClick={handleSave}>
          Save Settings
        </Button>
      </div>
    </div>
  );
}
```

```tsx
// apps/web/src/routes/ssh/settings.tsx
import { createFileRoute } from '@tanstack/react-router';
import type * as React from 'react';
import { AppSidebar } from '@/components/app-sidebar';
import { TerminalSettingsForm } from '@/components/settings/terminal-settings-form';
import { TerminalSettingsSyncBanner } from '@/components/terminal/terminal-settings-sync-banner';
import { ScrollArea } from '@/components/ui/scroll-area';
import { SidebarInset, SidebarProvider } from '@/components/ui/sidebar';

export const Route = createFileRoute('/ssh/settings')({
  component: SshSettingsPage
});

function SshSettingsPage() {
  return (
    <SidebarProvider
      style={
        {
          '--sidebar-width': 'calc(var(--spacing) * 72)',
          '--header-height': 'calc(var(--spacing) * 12)'
        } as React.CSSProperties
      }
    >
      <AppSidebar variant="inset" />
      <SidebarInset>
        <div className="flex items-center border-b px-4 py-3">
          <h1 className="font-semibold text-lg">Terminal Settings</h1>
        </div>
        <ScrollArea className="flex-1 overflow-hidden">
          <div className="space-y-4 p-6">
            <TerminalSettingsSyncBanner />
            <TerminalSettingsForm />
          </div>
        </ScrollArea>
      </SidebarInset>
    </SidebarProvider>
  );
}
```

```tsx
// modify apps/web/src/routes/ssh/index.tsx
// 1. add this import near the existing terminal imports
import { TerminalSettingsSyncBanner } from '@/components/terminal/terminal-settings-sync-banner';

// 2. render the banner directly after <SiteHeader ...>
<SiteHeader title="SSH Terminal">
  {hasConnectedSession && (
    <Button
      className="ml-auto"
      onClick={handleToggleSftpPanel}
      size="sm"
      variant={sftpPanelOpen ? 'secondary' : 'ghost'}
    >
      <FolderTree className="mr-1 h-4 w-4" />
      Files
    </Button>
  )}
</SiteHeader>

<div className="px-4 pt-4">
  <TerminalSettingsSyncBanner />
</div>
```

- [ ] **Step 4: Run the sync-status unit tests**

Run:

```bash
bun test apps/web/src/lib/sync-status.test.ts
```

Expected:

- PASS for both host-list tests and both terminal-settings tests

- [ ] **Step 5: Run the type check**

Run:

```bash
bun run check-types
```

Expected:

- PASS for all workspaces

- [ ] **Step 6: Commit**

```bash
git add apps/web/src/lib/sync-status.test.ts apps/web/src/components/terminal/terminal-settings-sync-banner.tsx apps/web/src/components/terminal/terminal-settings-provider.tsx apps/web/src/components/settings/terminal-settings-form.tsx apps/web/src/routes/ssh/index.tsx apps/web/src/routes/ssh/settings.tsx
git commit -m "feat: add terminal settings fallback states"
```

## Task 5: Biome Root Check Cleanup and Internal Beta Verification Docs

**Files:**
- Modify: `biome.json`
- Create: `docs/internal-beta-checklist.md`

- [ ] **Step 1: Reproduce the failing root lint workflow**

Run:

```bash
bun run check
```

Expected:

- FAIL with a nested Biome root configuration error caused by `.claude/worktrees/**`

- [ ] **Step 2: Exclude Claude worktrees from root Biome scans**

```json
// biome.json
{
  "$schema": "./node_modules/@biomejs/biome/configuration_schema.json",
  "vcs": {
    "enabled": false,
    "clientKind": "git",
    "useIgnoreFile": false
  },
  "files": {
    "ignoreUnknown": false,
    "includes": [
      "!**/.next",
      "!**/dist",
      "!**/dev-dist",
      "!**/.zed",
      "!**/.vscode",
      "!**/.claude/worktrees",
      "!**/.claude/worktrees/**",
      "!**/routeTree.gen.ts",
      "!**/src-tauri",
      "!**/.nuxt",
      "!bts.jsonc",
      "!**/.expo",
      "!**/.wrangler",
      "!**/.alchemy",
      "!**/.svelte-kit",
      "!**/wrangler.jsonc",
      "!**/.source",
      "!**/convex/_generated"
    ]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 120
  },
  "assist": {
    "actions": {
      "source": {
        "organizeImports": "on"
      }
    }
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "a11y": {
        "noLabelWithoutControl": "off",
        "useAnchorContent": "off",
        "useSemanticElements": "off",
        "useFocusableInteractive": "off"
      },
      "correctness": {
        "useExhaustiveDependencies": "info"
      },
      "nursery": {
        "useSortedClasses": {
          "level": "warn",
          "fix": "safe",
          "options": {
            "functions": ["clsx", "cva", "cn"]
          }
        }
      },
      "performance": {
        "noNamespaceImport": "off",
        "noBarrelFile": "off"
      },
      "security": {
        "noDangerouslySetInnerHtml": "off"
      },
      "style": {
        "noParameterAssign": "error",
        "useAsConstAssertion": "error",
        "useDefaultParameterLast": "error",
        "useEnumInitializers": "error",
        "useSelfClosingElements": "error",
        "useSingleVarDeclarator": "error",
        "noUnusedTemplateLiteral": "error",
        "useNumberNamespace": "error",
        "noInferrableTypes": "error",
        "noUselessElse": "error"
      },
      "suspicious": {
        "noDocumentCookie": "off"
      }
    }
  },
  "overrides": [
    {
      "includes": ["**/$.ts"],
      "linter": {
        "rules": {
          "style": {
            "useFilenamingConvention": "off"
          }
        }
      }
    }
  ],
  "javascript": {
    "formatter": {
      "semicolons": "asNeeded",
      "quoteStyle": "single",
      "jsxQuoteStyle": "double",
      "trailingCommas": "none"
    }
  },
  "css": {
    "parser": {
      "tailwindDirectives": true
    }
  },
  "extends": ["ultracite/biome/core", "ultracite/biome/react"]
}
```

- [ ] **Step 3: Add the internal beta checklist and explicit limitations**

```md
# Internal Beta Sync Verification Checklist

## Preconditions

- Machine A and machine B point to the same Caterm server and database.
- Both machines use the same `VITE_SERVER_URL`.
- Both machines start from a signed-out state.

## Machine A

1. Sign in.
2. Create one SSH host named `Beta Host A`.
3. Edit that host and change the port from `22` to `2222`.
4. Open `/ssh/settings`.
5. Change `Font Size` to `16`.
6. Change `Theme` to `solarized-dark` or any non-default theme.
7. Save settings.

## Machine B

1. Sign in with the same account.
2. Open `/ssh`.
3. Confirm `Beta Host A` appears in the host list.
4. Confirm the host shows port `2222`.
5. Connect to the host from the synced list.
6. Confirm the SSH terminal renders with the same global terminal settings.
7. Open `/ssh/settings`.
8. Confirm the saved font size and theme are present.

## Delete Propagation

1. Return to machine A.
2. Delete `Beta Host A`.
3. On machine B, retry host sync or reload `/ssh`.
4. Confirm `Beta Host A` disappears.

## Failure-State Checks

1. Disconnect the network or stop the server on machine B.
2. Reload `/ssh`.
3. Confirm session verification failure shows a blocking retry state, or host/settings failures show inline banners instead of false empty states.
4. Restore the network or server.
5. Retry and confirm synced data becomes available again.

## Known Beta Limitations

- SSH host key verification is not implemented yet; this beta is for trusted internal usage only.
- SSH host list has no local cache fallback. If host sync fails, the app must show an inline error instead of stale hosts.
- Terminal settings can briefly render cached values before reconciling to newer server state.
- SFTP transfer queue UI exists, but transfer scheduling and cancellation are not fully authoritative yet.
```

- [ ] **Step 4: Run the root validation commands**

Run:

```bash
bun run check
```

Expected:

- PASS without nested Biome root errors

Run:

```bash
bun run check-types
```

Expected:

- PASS for all workspaces

Run:

```bash
bun run build
```

Expected:

- PASS for `web` and `server`

- [ ] **Step 5: Execute the manual checklist on two machines**

Use:

```md
docs/internal-beta-checklist.md
```

Expected:

- The cross-device create/edit/delete/settings propagation flows pass end-to-end
- Session failure and host/settings failure states match the UI contract from the design doc

- [ ] **Step 6: Commit**

```bash
git add biome.json docs/internal-beta-checklist.md
git commit -m "chore: add internal beta validation checklist"
```
