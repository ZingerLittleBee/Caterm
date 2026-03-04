# Caterm

A cloud-synced SSH terminal manager built with Tauri and the Better-T-Stack.

## Features

- **SSH Terminal** - Multi-tab terminal sessions powered by xterm.js and Rust SSH (russh)
- **Cloud Sync** - SSH hosts, credentials, and terminal settings stored in PostgreSQL with server-side AES-256-GCM encryption
- **User Authentication** - Email/password auth via better-auth
- **Tauri Desktop App** - Native desktop experience with Rust-powered SSH connections
- **TypeScript** - Full type safety across the stack
- **TanStack Router** - File-based routing with type-safe navigation
- **oRPC** - Type-safe API layer with auto-generated OpenAPI docs
- **TailwindCSS + shadcn/ui** - Modern, accessible UI components

## Architecture

```
Caterm/
├── apps/
│   ├── web/              # Tauri desktop app (React + xterm.js + Rust SSH backend)
│   └── server/           # Full-stack web server (TanStack Start + oRPC)
├── packages/
│   ├── api/              # oRPC routers (sshHost, terminalSettings, todo)
│   ├── auth/             # better-auth configuration
│   ├── db/               # Drizzle ORM schemas (PostgreSQL)
│   ├── env/              # Type-safe environment variables
│   └── config/           # Shared config (Biome, TypeScript)
```

## Getting Started

### Prerequisites

- [Bun](https://bun.sh/) (package manager)
- [Rust](https://rustup.rs/) (for Tauri)
- PostgreSQL database
- System dependencies for Tauri (see [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/))

### Setup

1. Install dependencies:

```bash
bun install
```

2. Configure environment variables:

```bash
cp apps/server/.env.example apps/server/.env
```

Required variables in `apps/server/.env`:

```
DATABASE_URL=postgresql://user:pass@localhost:5432/caterm
BETTER_AUTH_SECRET=<min 32 chars>
BETTER_AUTH_URL=http://localhost:3001
CORS_ORIGIN=https://tauri.localhost
ENCRYPTION_KEY=<64 char hex string, generate with: node -e "console.log(require('crypto').randomBytes(32).toString('hex'))">
```

3. Start the database and push schema:

```bash
bun run db:start
bun run db:push
```

4. Run development:

```bash
# Start the server
bun run dev:server

# In another terminal, start the Tauri desktop app
bun run tauri:dev
```

## Available Scripts

- `bun run dev` - Start all applications in development mode
- `bun run dev:server` - Start only the server
- `bun run dev:web` - Start only the web frontend
- `bun run tauri:dev` - Start the Tauri desktop app
- `bun run tauri:build` - Build the Tauri desktop app
- `bun run build` - Build all applications
- `bun run check-types` - Check TypeScript types across all apps
- `bun run check` - Run Biome formatting and linting
- `bun run fix` - Auto-fix formatting and linting issues
- `bun run db:push` - Push database schema changes
- `bun run db:generate` - Generate database migrations
- `bun run db:studio` - Open Drizzle Studio
