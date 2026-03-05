# SFTP File Manager Design

## Overview

Add SFTP (SSH File Transfer Protocol) support to Caterm, providing two complementary UIs: a lightweight sidebar file tree integrated into the SSH terminal view, and a full-featured dual-pane file manager on a dedicated page.

## Decisions

| Decision | Choice |
|---|---|
| Protocol | SFTP over SSH (via `russh-sftp`) |
| UI | Dual-pane file manager + terminal sidebar file tree |
| Connection mode | Reuse SSH terminal connection + standalone connection |
| Feature scope | Full: batch ops, transfer queue, resume, preview/edit, chmod, symlinks, search, bookmarks |
| Local file access | Tauri fs plugin with scoped permissions |
| Routing | Sidebar file tree in `/ssh`, dual-pane manager at `/sftp` |
| Architecture | Unified SFTP core (Rust) + single SftpProvider + two UI views |

## Part 1: Rust SFTP Backend

### Module Structure

```
src-tauri/src/
├── ssh/          (existing)
├── sftp/         (new)
│   ├── mod.rs
│   ├── manager.rs    — SftpSessionManager
│   ├── session.rs    — SftpSession (wraps russh-sftp)
│   └── transfer.rs   — TransferQueue (upload/download queue + progress)
└── commands/
    ├── ssh_commands.rs  (existing)
    └── sftp_commands.rs (new, ~20 Tauri commands)
```

### SftpSession

```rust
pub struct SftpSession {
    pub id: String,                     // UUID
    pub host_id: String,
    ssh_session_id: Option<String>,     // Non-null when reusing SSH terminal session
    sftp: SftpChannel,                  // russh-sftp SftpSession
    app_handle: AppHandle,
}
```

Two creation modes:
- `open_from_ssh(ssh_session_id)` — open SFTP subchannel on existing SSH session
- `open_standalone(host, credentials)` — create new SSH connection then open SFTP

### TransferQueue

```rust
pub struct TransferQueue {
    tasks: Arc<Mutex<VecDeque<TransferTask>>>,
    active: Arc<AtomicUsize>,       // concurrent transfer count
    max_concurrent: usize,          // default 3
}

pub struct TransferTask {
    pub id: String,
    pub sftp_session_id: String,
    pub kind: TransferKind,         // Upload / Download
    pub local_path: PathBuf,
    pub remote_path: String,
    pub size: Option<u64>,
    pub transferred: AtomicU64,
    pub status: TransferStatus,     // Pending / Active / Paused / Completed / Failed
}
```

- Progress via Tauri event `sftp-transfer-progress-{taskId}` (every 100ms or 64KB)
- Pause/resume via SFTP seek (resumable transfers)
- Batch operations split into individual TransferTasks

### Tauri IPC Commands (~20)

| Command | Description |
|---|---|
| `sftp_open` | Open SFTP via standalone connection |
| `sftp_open_from_ssh` | Open SFTP reusing SSH terminal connection |
| `sftp_close` | Close SFTP session |
| `sftp_list_dir` | List directory (returns name, size, permissions, mtime, type) |
| `sftp_stat` | Get file/directory info |
| `sftp_mkdir` | Create directory |
| `sftp_rmdir` | Remove directory |
| `sftp_remove` | Remove file |
| `sftp_rename` | Rename/move |
| `sftp_chmod` | Change permissions |
| `sftp_read_file` | Read small file content (for preview/edit) |
| `sftp_write_file` | Write small file content (edit save) |
| `sftp_upload` | Enqueue upload |
| `sftp_download` | Enqueue download |
| `sftp_transfer_pause` | Pause transfer |
| `sftp_transfer_resume` | Resume transfer |
| `sftp_transfer_cancel` | Cancel transfer |
| `sftp_transfer_list` | Query queue status |
| `sftp_search` | Recursive filename search |
| `sftp_readlink` | Read symlink target |

### Dependency Change (Cargo.toml)

```toml
russh-sftp = "2.1"  # new, compatible with existing russh 0.46
```

## Part 2: Frontend State Management

### SftpProvider (React Context)

Placed at `/ssh` route level (alongside SshSessionProvider) and `/sftp` route.

```typescript
interface SftpContextValue {
  // Session management
  sessions: Map<string, SftpSessionInfo>
  openFromSsh(sshSessionId: string): Promise<string>
  openStandalone(hostId: string): Promise<string>
  close(sftpSessionId: string): Promise<void>

  // File operations
  listDir(sessionId: string, path: string): Promise<FileEntry[]>
  stat(sessionId: string, path: string): Promise<FileStat>
  mkdir(sessionId: string, path: string): Promise<void>
  remove(sessionId: string, path: string): Promise<void>
  rmdir(sessionId: string, path: string): Promise<void>
  rename(sessionId: string, from: string, to: string): Promise<void>
  chmod(sessionId: string, path: string, mode: number): Promise<void>
  readFile(sessionId: string, path: string): Promise<string>
  writeFile(sessionId: string, path: string, content: string): Promise<void>
  readlink(sessionId: string, path: string): Promise<string>
  search(sessionId: string, path: string, pattern: string): Promise<FileEntry[]>

  // Transfer queue
  transfers: TransferTask[]
  upload(sessionId: string, localPath: string, remotePath: string): Promise<string>
  download(sessionId: string, remotePath: string, localPath: string): Promise<string>
  pauseTransfer(taskId: string): Promise<void>
  resumeTransfer(taskId: string): Promise<void>
  cancelTransfer(taskId: string): Promise<void>
}
```

### Type Definitions (types/sftp.ts)

```typescript
interface SftpSessionInfo {
  id: string
  hostId: string
  hostName: string
  sshSessionId: string | null
  status: "connecting" | "connected" | "disconnected" | "error"
}

interface FileEntry {
  name: string
  path: string
  isDir: boolean
  isSymlink: boolean
  size: number
  permissions: number
  permissionsStr: string     // "-rwxr-xr-x"
  modifiedAt: string         // ISO 8601
  linkTarget?: string
}

interface FileStat {
  size: number
  permissions: number
  permissionsStr: string
  modifiedAt: string
  accessedAt: string
  isDir: boolean
  isSymlink: boolean
  uid: number
  gid: number
}

interface TransferTask {
  id: string
  sftpSessionId: string
  kind: "upload" | "download"
  localPath: string
  remotePath: string
  fileName: string
  size: number | null
  transferred: number
  status: "pending" | "active" | "paused" | "completed" | "failed"
  error?: string
}

interface SftpBookmark {
  id: string
  hostId: string
  remotePath: string
  label: string
}
```

### Route Structure

```
routes/
├── ssh/
│   ├── route.tsx       # Add SftpProvider wrapper
│   ├── index.tsx       # Existing terminal + sidebar file tree
│   └── settings.tsx
└── sftp/
    ├── route.tsx       # SftpProvider wrapper (independent instance)
    └── index.tsx       # Dual-pane file manager
```

## Part 3: UI Components

### Component Tree

```
components/sftp/
├── sftp-provider.tsx              # Context Provider
├── sftp-sidebar-tree.tsx          # Terminal sidebar file tree (embedded in /ssh)
├── sftp-file-manager.tsx          # Dual-pane file manager (main /sftp component)
├── sftp-file-panel.tsx            # Single file panel (local or remote)
├── sftp-file-table.tsx            # File list table (name, size, permissions, date)
├── sftp-breadcrumb.tsx            # Path navigation bar
├── sftp-transfer-queue.tsx        # Transfer queue panel (progress, pause/resume/cancel)
├── sftp-toolbar.tsx               # Action toolbar (upload, download, new, delete, search)
├── sftp-context-menu.tsx          # Right-click menu (open, edit, download, rename, chmod, delete)
├── sftp-chmod-dialog.tsx          # Permission editor (checkboxes + octal input)
├── sftp-search-dialog.tsx         # File search dialog
├── sftp-preview-dialog.tsx        # File preview (text, images, code highlighting)
├── sftp-editor-dialog.tsx         # Simple text editor (read -> edit -> save)
├── sftp-bookmark-list.tsx         # Bookmark/favorites list
└── sftp-connect-dialog.tsx        # Standalone connection dialog (host selection)
```

### Terminal Sidebar File Tree

Collapsible right panel embedded in `/ssh/index.tsx`:

- Auto-opens SFTP via `openFromSsh()` when SSH terminal connects
- Lazy-loads directories (fetches children on expand)
- Double-click to open/preview, right-click for context menu
- Drag local files onto tree to upload
- Bottom quick buttons: upload, download, refresh

### Dual-Pane File Manager

FileZilla-style layout on `/sftp` page:

- Left panel: local files via Tauri fs plugin, directory selected via dialog plugin
- Right panel: remote files via SFTP commands
- Both panels use same `SftpFilePanel` component with `source: "local" | "remote"` prop
- Transfer buttons / cross-panel drag-and-drop to enqueue transfers
- Collapsible bottom transfer queue with real-time progress
- Multi-select (Ctrl/Shift + click) for batch operations
- Keyboard shortcuts: Delete, F2 rename, F5 refresh, Ctrl+F search

### File Preview/Edit

- Preview: text (code highlighting), images (inline), other formats show file info
- Edit: simple textarea or lightweight editor, `readFile` -> edit -> `writeFile`
- Size limit: preview/edit only for files < 1MB, larger files prompt download

### shadcn/ui Reuse

Dialog, Sheet, Table, ContextMenu, Progress, Breadcrumb, Tooltip, Button, Input.

## Part 4: Database & API

### New Table

```typescript
// packages/db/src/schema/sftp-bookmark.ts
sftpBookmark:
  - id         (text, PK)
  - userId     (text, FK -> user.id, CASCADE DELETE)
  - hostId     (text, FK -> sshHost.id, CASCADE DELETE)
  - remotePath (text, required)
  - label      (text, required)
  - createdAt  (timestamp)
  Index: sftp_bookmark_userId_idx
```

No additional credential storage needed — reuses `sshHost` table's encrypted SSH credentials.

### oRPC Route

```typescript
// packages/api/src/routers/sftp-bookmark.ts
sftpBookmarkRouter = {
  list(hostId?: string): SftpBookmark[]
  create(hostId, remotePath, label): { id }
  update(id, label?, remotePath?): void
  delete(id): void
}
// All endpoints use protectedProcedure
```

All SFTP file operations go through Tauri IPC directly (not oRPC), since the desktop app connects to remote servers without the web server as intermediary.

## Part 5: Error Handling & Security

### Error Handling

- Rust: SFTP operations return `Result<T, String>` with context (operation type + path)
- Disconnection notified via `sftp-disconnect-{sessionId}` event
- Failed transfers marked as `failed`, kept in queue for retry
- Frontend: Sonner toast for operation failures
- Batch operations: individual failures don't block others; summary report on completion

### Security

| Risk | Mitigation |
|---|---|
| Local file access scope | Tauri fs plugin scope, user authorizes directories via dialog |
| Remote path traversal | Rust validates paths; SFTP server also enforces |
| Large file DoS | Preview/edit capped at 1MB; max 3 concurrent transfers |
| Credential security | Reuses existing encrypted SSH credentials; no plaintext in frontend |
| Session leaks | Provider unmount closes all SFTP; SSH disconnect auto-closes linked SFTP |

### Connection Lifecycle

Reuse mode:
- SSH terminal disconnects -> SFTP auto-closes, frontend notified
- User closes SFTP manually -> only SFTP subchannel closes, SSH terminal unaffected
- User closes terminal tab -> SSH disconnects -> SFTP follows

Standalone mode:
- SFTP close also closes its dedicated SSH connection
