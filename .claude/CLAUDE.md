# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Caterm is a cloud-synced SSH terminal manager. Monorepo with a Tauri desktop app (React + Rust SSH backend) and a full-stack web server.

## Commands

```bash
# Development
bun run dev              # Start all apps
bun run dev:server       # Server only (port 3001)
bun run tauri:dev        # Tauri desktop app

# Database (PostgreSQL via Docker)
bun run db:start         # Start PostgreSQL container
bun run db:stop          # Stop PostgreSQL container
bun run db:push          # Apply schema changes to DB
bun run db:generate      # Generate Drizzle migrations
bun run db:studio        # Open Drizzle Studio

# Code quality
bun run check-types      # TypeScript type check across all packages
bun x ultracite check    # Lint + format check (Biome)
bun x ultracite fix      # Auto-fix lint + format issues

# Build
bun run build            # Build all apps
bun run tauri:build      # Build Tauri desktop app
```

## Architecture

### Monorepo Structure

- `apps/web/` — Tauri desktop app: React 19 + Vite + xterm.js frontend, Rust SSH backend (`src-tauri/`)
- `apps/server/` — Full-stack web server: TanStack Start + oRPC API endpoints
- `packages/api/` — oRPC router definitions (shared between web and server)
- `packages/db/` — Drizzle ORM schemas and migrations (PostgreSQL)
- `packages/auth/` — better-auth configuration
- `packages/env/` — Type-safe environment variables (t3-oss/env-core + Zod)

### Key Data Flow

**oRPC API layer** (`packages/api/src/routers/`): Type-safe RPC routers consumed by both apps. Routers: `sshHost` (host CRUD with encrypted credentials), `terminalSettings` (JSONB-stored user preferences), `todo`.

**Frontend oRPC client** (`apps/web/src/lib/orpc.ts`): Exports `client` (direct calls), `orpc` (TanStack Query utils), `queryClient`. Server URL defaults to `http://localhost:3001`.

**SSH connections**: Rust backend (`apps/web/src-tauri/src/ssh/`) handles SSH via `russh`. Frontend communicates through Tauri IPC commands. Sessions managed by `SshSessionProvider` context.

**Terminal settings**: Stored as JSONB in PostgreSQL. `TerminalSettingsProvider` (root layout) uses React Query with localStorage cache as `placeholderData` for instant startup. Supports global settings + per-host overrides.

### Route Structure (TanStack Router, file-based)

```
apps/web/src/routes/
├── __root.tsx          # ThemeProvider → QueryClientProvider → TerminalSettingsProvider
├── index.tsx           # Redirects to /ssh
├── login.tsx           # Auth (sign-in / sign-up)
└── ssh/
    ├── route.tsx       # SshSessionProvider wrapper
    ├── index.tsx       # Main terminal UI (tabs, sidebar, host list)
    └── settings.tsx    # Terminal settings form (protected route)
```

### Environment Variables

Configure in `apps/server/.env` (also read by `packages/db/drizzle.config.ts`):

```
DATABASE_URL=postgresql://postgres:password@localhost:5432/caterm
BETTER_AUTH_SECRET=<min 32 chars>
BETTER_AUTH_URL=http://localhost:3001
CORS_ORIGIN=http://localhost:1420
ENCRYPTION_KEY=<64 hex chars>
```

### Type Definitions

Terminal settings types are in `apps/web/src/types/ssh.ts`. Theme presets and defaults in `apps/web/src/lib/terminal-themes.ts`.

## Code Standards (Ultracite / Biome)

- Tabs for indentation, double quotes
- React 19: use ref as prop, not `React.forwardRef`
- Prefer `for...of` over `.forEach()`, `const` by default, `async/await` over promise chains
- Run `bun x ultracite fix` before committing
