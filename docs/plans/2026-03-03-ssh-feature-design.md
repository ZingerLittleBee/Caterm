# SSH Feature Design

## Overview

Caterm SSH feature: a full-featured SSH terminal client built into the Tauri desktop app, supporting password and key-based authentication, multi-tab sessions, and encrypted credential storage.

## Tech Stack

- **Frontend**: React 19 + TanStack Router + xterm.js + shadcn/ui + TanStack Form + Zod
- **Backend**: Rust + russh + tauri-plugin-sql (SQLite) + tauri-plugin-stronghold
- **Data transfer**: Tauri Events (emit/listen)
- **Rendering**: xterm.js with WebGL addon, Canvas fallback

## Architecture: Session Manager Singleton

```
xterm.js (React) <--Tauri Events--> SshSessionManager (Rust) <--russh--> Remote SSH Server
```

Rust backend uses a global `SshSessionManager` holding an `Arc<Mutex<HashMap<session_id, SshSession>>>`. Each session runs a tokio background task that reads SSH output and emits Tauri events to the frontend.

### Data Flow

```
User input → xterm.onData → invoke("ssh_write", {session_id, data})
  → SshSessionManager.write(session_id, data)
  → russh Channel.data(data)
  → Remote server responds
  → tokio::spawn read loop
  → app_handle.emit("ssh-output-{session_id}", data)
  → listen("ssh-output-{session_id}") → xterm.write(data)
```

## Data Model

### SQLite (non-sensitive data)

```sql
CREATE TABLE ssh_hosts (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    hostname    TEXT NOT NULL,
    port        INTEGER DEFAULT 22,
    username    TEXT NOT NULL,
    auth_type   TEXT NOT NULL,     -- 'password' | 'key'
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE terminal_settings (
    id           TEXT PRIMARY KEY DEFAULT 'default',
    font_family  TEXT DEFAULT 'monospace',
    font_size    INTEGER DEFAULT 14,
    cursor_style TEXT DEFAULT 'block',
    cursor_blink INTEGER DEFAULT 1,
    scrollback   INTEGER DEFAULT 1000,
    theme        TEXT DEFAULT 'default'
);
```

### Stronghold (sensitive data)

All credentials stored encrypted via tauri-plugin-stronghold:

- `ssh-password-{host_id}` - Password
- `ssh-private-key-{host_id}` - Full private key content (not file path)
- `ssh-key-passphrase-{host_id}` - Key passphrase (if applicable)

Master password set by user, stored in system keychain. On app launch, auto-retrieve from keychain; if unavailable, prompt user.

### Multi-device Sync

V1: Export/import encrypted config files via Stronghold. Future: iCloud/cloud service integration.

## Rust Backend Structure

```
src-tauri/src/
├── lib.rs
├── main.rs
├── ssh/
│   ├── mod.rs
│   ├── manager.rs         -- SshSessionManager singleton
│   ├── session.rs         -- Individual SshSession
│   └── handler.rs         -- russh Client Handler
├── db/
│   ├── mod.rs
│   └── migrations.rs
├── commands/
│   ├── mod.rs
│   ├── ssh_commands.rs    -- connect, write, resize, disconnect
│   └── host_commands.rs   -- CRUD for hosts
└── crypto/
    ├── mod.rs
    └── stronghold.rs      -- Encryption/decryption wrapper
```

### Tauri Commands

**Host CRUD:**
- `create_host`, `update_host`, `delete_host`, `list_hosts`, `get_host`

**SSH Sessions:**
- `ssh_connect(host_id) -> session_id`
- `ssh_write(session_id, data)`
- `ssh_resize(session_id, cols, rows)`
- `ssh_disconnect(session_id)`

**Credentials:**
- `save_credential(host_id, auth_type, data)`
- `init_stronghold(master_password)`
- `unlock_stronghold(master_password)`

**Config Sync:**
- `export_config(password) -> encrypted_file`
- `import_config(file_path, password)`

**Terminal Settings:**
- `get_terminal_settings()`
- `save_terminal_settings(settings)`

## Frontend Architecture

### Routes (TanStack Router)

```
routes/
├── __root.tsx
├── index.tsx               -- Dashboard
├── ssh/
│   ├── route.tsx           -- SSH layout (Sidebar + Tabs + Terminal)
│   └── settings.tsx        -- Terminal settings page
└── hosts/
    ├── route.tsx
    ├── index.tsx           -- Host list
    └── $hostId.edit.tsx    -- Edit host
```

### Components

```
components/
├── ssh/
│   ├── ssh-terminal.tsx          -- xterm.js wrapper
│   ├── ssh-tab-bar.tsx           -- Tab bar (draggable)
│   ├── ssh-session-provider.tsx  -- Session state Context
│   └── ssh-status-bar.tsx        -- Connection status
├── hosts/
│   ├── host-form.tsx             -- Create/edit form (TanStack Form + Zod)
│   ├── host-list.tsx
│   ├── host-card.tsx
│   └── host-delete-dialog.tsx
└── settings/
    └── terminal-settings-form.tsx
```

### UI Layout (Tab-based)

```
┌────────────────────────────────────────┐
│ [Sidebar]  [Tab: Server1] [Tab: Server2] [+] │
├──────────┬─────────────────────────────┤
│ Hosts    │                              │
│ ┌─────┐ │   Terminal (xterm.js)          │
│ │Srv1 │ │   $ whoami                     │
│ │Srv2 │ │   root                         │
│ │Srv3 │ │   $ _                          │
│ └─────┘ │                              │
│ [+Add]   │                              │
└──────────┴─────────────────────────────┘
```

### Session Management (React Context)

```typescript
interface SshSession {
  id: string
  hostId: string
  hostName: string
  status: 'connecting' | 'connected' | 'disconnected' | 'error'
}

interface SshSessionContext {
  sessions: Map<string, SshSession>
  activeSessionId: string | null
  connect: (hostId: string) => Promise<string>
  disconnect: (sessionId: string) => void
  setActive: (sessionId: string) => void
}
```

Inactive tabs use `display: none` to preserve DOM and terminal state. FitAddon re-fits on tab activation.

### Form Validation (Zod)

```typescript
const hostSchema = z.object({
  name: z.string().min(1),
  hostname: z.string().min(1),
  port: z.number().int().min(1).max(65535).default(22),
  username: z.string().min(1),
  authType: z.enum(['password', 'key']),
  password: z.string().optional(),
  privateKey: z.string().optional(),
  keyPassphrase: z.string().optional(),
})
```

### Terminal Settings

Basic configuration: font family, font size, cursor style, cursor blink, scrollback buffer size, theme.

## Performance

| Concern | Strategy |
|---------|----------|
| Memory leaks | `terminal.dispose()` on tab close; Rust `Drop` trait for SshSession cleanup |
| SSH output flow control | Watermark backpressure: pause at 100KB, resume at 10KB |
| Rendering | WebGL renderer preferred, Canvas fallback |
| Resize | Debounce `fitAddon.fit()` via `requestAnimationFrame` |
| Serialization | Base64 encode SSH output to avoid UTF-8 boundary issues |
| Session cleanup | Rust `Drop` implementation ensures SSH channel close |

## Error Handling

| Scenario | Handling |
|----------|----------|
| Connection failure | Toast with error message, session status set to `error` |
| Connection dropped | Emit disconnect event, show "Disconnected" with reconnect button |
| Stronghold locked | Prompt master password dialog; auto-retrieve from system keychain |
| Auth failure | Return SSH error details to frontend for display |
| Single session failure | Only affects that tab; other sessions remain active |
