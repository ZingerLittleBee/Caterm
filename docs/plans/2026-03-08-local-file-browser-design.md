# Local File Browser Design

## Goal

Implement a local file browser panel that mirrors the remote SFTP file panel, enabling symmetric local/remote file management with drag-and-drop and button-based transfers.

## Approach

Reuse SftpFilePanel by extracting common logic into shared components. Add a Rust `local_fs` backend module using `tokio::fs`. Refactor SFTP to share a common `FileSystemOps` trait and types.

## Rust Backend

### Shared Module: `fs_common`

```
src-tauri/src/fs_common/
├── mod.rs
├── types.rs    # FileEntry, FileStat
└── traits.rs   # FileSystemOps async trait
```

**FileSystemOps trait:**

- `list_dir(path) -> Vec<FileEntry>`
- `stat(path) -> FileStat`
- `mkdir(path)`
- `rename(old, new)`
- `remove(path)`
- `chmod(path, mode)`
- `read_file(path) -> Vec<u8>`
- `write_file(path, data)`
- `search(path, pattern) -> Vec<FileEntry>`

### Local Module: `local_fs`

```
src-tauri/src/local_fs/
├── mod.rs
└── ops.rs    # impl FileSystemOps using tokio::fs
```

### SFTP Refactor

Refactor existing SFTP session to implement `FileSystemOps` trait, sharing types from `fs_common`.

### Tauri Commands

```
local_fs_list_dir, local_fs_stat, local_fs_mkdir, local_fs_rename,
local_fs_remove, local_fs_chmod, local_fs_read_file, local_fs_write_file,
local_fs_search, local_fs_open_in_system, local_fs_get_home_dir
```

All file I/O via `tokio::fs`. Returns shared `FileEntry`/`FileStat` types.

## Frontend Components

### Extracted Common Components

```
src/components/file-panel/
├── file-panel.tsx           # Generic file panel (UI skeleton + state)
├── file-table.tsx           # File list table
├── file-breadcrumb.tsx      # Path breadcrumb navigation
├── file-context-menu.tsx    # Right-click menu (extensible)
├── dialogs/
│   ├── preview-dialog.tsx
│   ├── editor-dialog.tsx
│   ├── rename-dialog.tsx
│   ├── mkdir-dialog.tsx
│   ├── delete-dialog.tsx
│   ├── chmod-dialog.tsx
│   ├── search-dialog.tsx
│   └── bookmarks-dialog.tsx
└── hooks/
    ├── use-file-operations.ts   # Abstract file ops hook
    ├── use-file-navigation.ts   # Directory navigation, history, bookmarks
    └── use-file-selection.ts    # File selection state
```

### FileOperations Interface

```typescript
interface FileOperations {
  listDir(path: string): Promise<FileEntry[]>
  stat(path: string): Promise<FileStat>
  mkdir(path: string): Promise<void>
  rename(oldPath: string, newPath: string): Promise<void>
  remove(path: string): Promise<void>
  chmod(path: string, mode: number): Promise<void>
  readFile(path: string): Promise<string>
  writeFile(path: string, data: string): Promise<void>
  search(path: string, pattern: string): Promise<FileEntry[]>
}
```

Two implementations: `localFileOps` (invokes `local_fs_*`) and `sftpFileOps` (invokes `sftp_*`).

### Usage

```tsx
<FilePanel
  operations={source === 'local' ? localFileOps : sftpFileOps}
  initialPath={source === 'local' ? homeDir : '/'}
  extraContextMenuItems={source === 'local' ? [openInSystem] : []}
  transferProps={...}
/>
```

Local panel extra: "Open in system app" context menu item.

## File Transfer

### Drag & Drop

- File rows are `draggable`, carry `{ source, path, isDir }` data
- Opposite panel acts as drop target
- Highlight target panel on drag over
- Support multi-select drag

### Button Transfer

- Toolbar upload/download buttons appear when files are selected
- Transfers to the opposite panel's current directory

### Transfer Mechanism

- Reuse existing SFTP `TransferQueue` for progress tracking
- Upload: `local_fs_read_file` → `sftp_write_file`
- Download: `sftp_read_file` → `local_fs_write_file`
- Large files: chunked transfer with progress events
- Conflict: confirmation dialog (overwrite / skip / rename)

## Configuration

- Default start path: `$HOME`, customizable in terminal settings
- Remember last browsed path in localStorage
- Independent bookmark lists for local and remote
- Preset bookmarks: Home, Desktop, Downloads, Documents

## File Editing

- Small files: in-app editor dialog (same as remote)
- "Open in system app" option via `open` / `xdg-open`

## Out of Scope

- Local terminal shell (PTY)
- Local filesystem watching (fs watch)
- Remote-to-remote transfers
