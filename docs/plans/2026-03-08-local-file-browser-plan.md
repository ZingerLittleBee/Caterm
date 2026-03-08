# Local File Browser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a local file browser panel symmetric to the remote SFTP panel, with shared types/trait, `tokio::fs` backend, extracted common UI components, and bidirectional file transfer.

**Architecture:** Extract shared `fs_common` module (types + async trait) in Rust. Implement `local_fs` using `tokio::fs`. Refactor SFTP commands to use shared types. On the frontend, extract a generic `FilePanel` from `SftpFilePanel`, create a `FileOperations` interface with local/sftp adapters, and wire up drag-and-drop + button transfers.

**Tech Stack:** Rust (tokio::fs, async-trait, serde), TypeScript/React 19, Tauri IPC, xterm.js terminal (unchanged)

---

## Task 1: Create `fs_common` module with shared types

**Files:**
- Create: `apps/web/src-tauri/src/fs_common/mod.rs`
- Create: `apps/web/src-tauri/src/fs_common/types.rs`
- Modify: `apps/web/src-tauri/src/lib.rs:1` (add `mod fs_common`)

**Step 1: Create `fs_common/types.rs`**

Move `FileEntry`, `FileStat`, `format_permissions`, and `join_path` from `sftp_commands.rs` into this shared module.

```rust
// apps/web/src-tauri/src/fs_common/types.rs
use serde::Serialize;

/// A file entry returned by directory listing operations.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub permissions: u32,
    pub permissions_str: String,
    pub modified_at: Option<i64>,
    pub link_target: Option<String>,
}

/// File stat information.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileStat {
    pub size: u64,
    pub permissions: u32,
    pub permissions_str: String,
    pub modified_at: Option<i64>,
    pub accessed_at: Option<i64>,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
}

/// Format a unix permission mode into a human-readable string like `-rwxr-xr-x`.
pub fn format_permissions(mode: u32, is_dir: bool) -> String {
    let mut s = String::with_capacity(10);
    s.push(if is_dir { 'd' } else { '-' });
    s.push(if mode & 0o400 != 0 { 'r' } else { '-' });
    s.push(if mode & 0o200 != 0 { 'w' } else { '-' });
    s.push(if mode & 0o100 != 0 { 'x' } else { '-' });
    s.push(if mode & 0o040 != 0 { 'r' } else { '-' });
    s.push(if mode & 0o020 != 0 { 'w' } else { '-' });
    s.push(if mode & 0o010 != 0 { 'x' } else { '-' });
    s.push(if mode & 0o004 != 0 { 'r' } else { '-' });
    s.push(if mode & 0o002 != 0 { 'w' } else { '-' });
    s.push(if mode & 0o001 != 0 { 'x' } else { '-' });
    s
}

/// Normalize a path by joining parent and name.
pub fn join_path(parent: &str, name: &str) -> String {
    if parent.ends_with('/') {
        format!("{parent}{name}")
    } else {
        format!("{parent}/{name}")
    }
}

/// Sort entries: directories first, then alphabetically by name (case-insensitive).
pub fn sort_entries(entries: &mut Vec<FileEntry>) {
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
}
```

**Step 2: Create `fs_common/mod.rs`**

```rust
// apps/web/src-tauri/src/fs_common/mod.rs
pub mod types;
```

**Step 3: Register module in `lib.rs`**

Add `mod fs_common;` after the existing module declarations (line 1-3 of `lib.rs`).

```rust
mod commands;
mod fs_common;
mod sftp;
mod ssh;
```

**Step 4: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles successfully (fs_common is declared but types not yet used)

**Step 5: Commit**

```bash
git add apps/web/src-tauri/src/fs_common/
git add apps/web/src-tauri/src/lib.rs
git commit -m "feat: add fs_common module with shared FileEntry/FileStat types"
```

---

## Task 2: Refactor `sftp_commands.rs` to use shared types

**Files:**
- Modify: `apps/web/src-tauri/src/commands/sftp_commands.rs` (remove local FileEntry/FileStat/helpers, import from fs_common)

**Step 1: Update imports in `sftp_commands.rs`**

Replace the local `FileEntry`, `FileStat`, `format_permissions`, `join_path` definitions (lines 1-62) with imports from `fs_common`. Keep only the `use` statements and command functions.

The file should start with:

```rust
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::fs_common::types::{format_permissions, join_path, sort_entries, FileEntry, FileStat};
use crate::sftp::manager::SftpSessionManager;
use crate::sftp::session::{SftpConnectConfig, SftpSessionEntry};
use crate::sftp::transfer::TransferTaskInfo;
use crate::ssh::session::AuthMethod;
```

Remove lines 9-62 (the struct definitions and helper functions). Keep everything from line 64 (`// Session management commands`) onward.

Update `sftp_list_dir` (currently lines 129-177): replace the inline sort block at the end with `sort_entries(&mut entries);`.

Update `sftp_search` (currently lines 346-417): replace the inline sort block at the end with `sort_entries(&mut results);`.

**Step 2: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles successfully with no warnings about unused imports

**Step 3: Commit**

```bash
git add apps/web/src-tauri/src/commands/sftp_commands.rs
git commit -m "refactor: use shared fs_common types in sftp_commands"
```

---

## Task 3: Create `local_fs` module with Tauri commands

**Files:**
- Create: `apps/web/src-tauri/src/local_fs/mod.rs`
- Create: `apps/web/src-tauri/src/local_fs/ops.rs`
- Create: `apps/web/src-tauri/src/commands/local_fs_commands.rs`
- Modify: `apps/web/src-tauri/src/commands/mod.rs` (add `pub mod local_fs_commands`)
- Modify: `apps/web/src-tauri/src/lib.rs` (add `mod local_fs`, register commands)

**Step 1: Create `local_fs/ops.rs`**

All file operations using `tokio::fs`. Each function returns `Result<T, String>`.

```rust
// apps/web/src-tauri/src/local_fs/ops.rs
use std::path::Path;
use tokio::fs;

use crate::fs_common::types::{format_permissions, join_path, sort_entries, FileEntry, FileStat};

/// List directory contents, sorted with directories first.
pub async fn list_dir(path: &str) -> Result<Vec<FileEntry>, String> {
    let mut entries = Vec::new();
    let mut read_dir = fs::read_dir(path)
        .await
        .map_err(|e| format!("Failed to list directory: {e}"))?;

    while let Some(dir_entry) = read_dir
        .next_entry()
        .await
        .map_err(|e| format!("Failed to read entry: {e}"))?
    {
        let name = dir_entry
            .file_name()
            .to_string_lossy()
            .into_owned();

        let metadata = dir_entry
            .metadata()
            .await
            .map_err(|e| format!("Failed to get metadata for {name}: {e}"))?;

        let is_dir = metadata.is_dir();
        let is_symlink = metadata.file_type().is_symlink();
        let size = metadata.len();
        let modified_at = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64);

        #[cfg(unix)]
        let permissions = {
            use std::os::unix::fs::PermissionsExt;
            metadata.permissions().mode() & 0o7777
        };
        #[cfg(not(unix))]
        let permissions = if metadata.permissions().readonly() {
            0o444
        } else {
            0o644
        };

        let entry_path = join_path(path, &name);

        entries.push(FileEntry {
            name,
            path: entry_path,
            is_dir,
            is_symlink,
            size,
            permissions,
            permissions_str: format_permissions(permissions, is_dir),
            modified_at,
            link_target: None,
        });
    }

    sort_entries(&mut entries);
    Ok(entries)
}

/// Get file/directory metadata.
pub async fn stat(path: &str) -> Result<FileStat, String> {
    let metadata = fs::metadata(path)
        .await
        .map_err(|e| format!("Failed to stat: {e}"))?;

    let is_dir = metadata.is_dir();
    let is_symlink = metadata.file_type().is_symlink();
    let size = metadata.len();
    let modified_at = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);
    let accessed_at = metadata
        .accessed()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);

    #[cfg(unix)]
    let (permissions, uid, gid) = {
        use std::os::unix::fs::MetadataExt;
        (
            metadata.mode() & 0o7777,
            Some(metadata.uid()),
            Some(metadata.gid()),
        )
    };
    #[cfg(not(unix))]
    let (permissions, uid, gid) = {
        let p = if metadata.permissions().readonly() {
            0o444
        } else {
            0o644
        };
        (p, None, None)
    };

    Ok(FileStat {
        size,
        permissions,
        permissions_str: format_permissions(permissions, is_dir),
        modified_at,
        accessed_at,
        is_dir,
        is_symlink,
        uid,
        gid,
    })
}

/// Create a directory.
pub async fn mkdir(path: &str) -> Result<(), String> {
    fs::create_dir(path)
        .await
        .map_err(|e| format!("Failed to create directory: {e}"))
}

/// Rename a file or directory.
pub async fn rename(old_path: &str, new_path: &str) -> Result<(), String> {
    fs::rename(old_path, new_path)
        .await
        .map_err(|e| format!("Failed to rename: {e}"))
}

/// Remove a file or empty directory.
pub async fn remove(path: &str) -> Result<(), String> {
    let metadata = fs::metadata(path)
        .await
        .map_err(|e| format!("Failed to stat: {e}"))?;

    if metadata.is_dir() {
        fs::remove_dir_all(path)
            .await
            .map_err(|e| format!("Failed to remove directory: {e}"))
    } else {
        fs::remove_file(path)
            .await
            .map_err(|e| format!("Failed to remove file: {e}"))
    }
}

/// Change permissions (Unix only).
#[cfg(unix)]
pub async fn chmod(path: &str, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let perms = std::fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perms)
        .await
        .map_err(|e| format!("Failed to chmod: {e}"))
}

#[cfg(not(unix))]
pub async fn chmod(_path: &str, _mode: u32) -> Result<(), String> {
    Err("chmod is not supported on this platform".to_string())
}

/// Read a file as UTF-8 text. Default max 1 MB.
pub async fn read_file(path: &str, max_size: Option<usize>) -> Result<String, String> {
    let max_size = max_size.unwrap_or(1_048_576);

    let metadata = fs::metadata(path)
        .await
        .map_err(|e| format!("Failed to stat file: {e}"))?;

    if (metadata.len() as usize) > max_size {
        return Err(format!(
            "File too large: {} bytes (max {} bytes)",
            metadata.len(),
            max_size
        ));
    }

    let data = fs::read(path)
        .await
        .map_err(|e| format!("Failed to read file: {e}"))?;

    String::from_utf8(data).map_err(|_| "File is not valid UTF-8".to_string())
}

/// Write UTF-8 text to a file.
pub async fn write_file(path: &str, content: &str) -> Result<(), String> {
    fs::write(path, content.as_bytes())
        .await
        .map_err(|e| format!("Failed to write file: {e}"))
}

/// Recursively search for files matching a pattern. Max 500 results, max depth 10.
pub async fn search(base_path: &str, pattern: &str) -> Result<Vec<FileEntry>, String> {
    const MAX_RESULTS: usize = 500;
    const MAX_DEPTH: usize = 10;

    let pattern_lower = pattern.to_lowercase();
    let mut results: Vec<FileEntry> = Vec::new();
    let mut dirs_to_visit: Vec<(String, usize)> = vec![(base_path.to_string(), 0)];

    while let Some((current_dir, depth)) = dirs_to_visit.pop() {
        if results.len() >= MAX_RESULTS {
            break;
        }

        let mut read_dir = match fs::read_dir(&current_dir).await {
            Ok(rd) => rd,
            Err(_) => continue,
        };

        while let Ok(Some(dir_entry)) = read_dir.next_entry().await {
            if results.len() >= MAX_RESULTS {
                break;
            }

            let name = dir_entry.file_name().to_string_lossy().into_owned();

            let metadata = match dir_entry.metadata().await {
                Ok(m) => m,
                Err(_) => continue,
            };

            let is_dir = metadata.is_dir();
            let is_symlink = metadata.file_type().is_symlink();
            let entry_path = join_path(&current_dir, &name);

            if is_dir && depth < MAX_DEPTH {
                dirs_to_visit.push((entry_path.clone(), depth + 1));
            }

            if name.to_lowercase().contains(&pattern_lower) {
                let size = metadata.len();
                let modified_at = metadata
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64);

                #[cfg(unix)]
                let permissions = {
                    use std::os::unix::fs::PermissionsExt;
                    metadata.permissions().mode() & 0o7777
                };
                #[cfg(not(unix))]
                let permissions = if metadata.permissions().readonly() {
                    0o444
                } else {
                    0o644
                };

                results.push(FileEntry {
                    name,
                    path: entry_path,
                    is_dir,
                    is_symlink,
                    size,
                    permissions,
                    permissions_str: format_permissions(permissions, is_dir),
                    modified_at,
                    link_target: None,
                });
            }
        }
    }

    sort_entries(&mut results);
    Ok(results)
}

/// Get the user's home directory.
pub fn get_home_dir() -> Result<String, String> {
    dirs::home_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .ok_or_else(|| "Could not determine home directory".to_string())
}

/// Open a file or directory in the system's default application.
pub fn open_in_system(path: &str) -> Result<(), String> {
    open::that(path).map_err(|e| format!("Failed to open: {e}"))
}
```

**Step 2: Add `dirs` and `open` crates to Cargo.toml**

Add to `[dependencies]` in `apps/web/src-tauri/Cargo.toml`:

```toml
dirs = "6"
open = "5"
```

**Step 3: Create `local_fs/mod.rs`**

```rust
// apps/web/src-tauri/src/local_fs/mod.rs
pub mod ops;
```

**Step 4: Create `commands/local_fs_commands.rs`**

```rust
// apps/web/src-tauri/src/commands/local_fs_commands.rs
use crate::fs_common::types::{FileEntry, FileStat};
use crate::local_fs::ops;

#[tauri::command]
pub async fn local_fs_list_dir(path: String) -> Result<Vec<FileEntry>, String> {
    ops::list_dir(&path).await
}

#[tauri::command]
pub async fn local_fs_stat(path: String) -> Result<FileStat, String> {
    ops::stat(&path).await
}

#[tauri::command]
pub async fn local_fs_mkdir(path: String) -> Result<(), String> {
    ops::mkdir(&path).await
}

#[tauri::command]
pub async fn local_fs_rename(old_path: String, new_path: String) -> Result<(), String> {
    ops::rename(&old_path, &new_path).await
}

#[tauri::command]
pub async fn local_fs_remove(path: String) -> Result<(), String> {
    ops::remove(&path).await
}

#[tauri::command]
pub async fn local_fs_chmod(path: String, mode: u32) -> Result<(), String> {
    ops::chmod(&path, mode).await
}

#[tauri::command]
pub async fn local_fs_read_file(
    path: String,
    max_size: Option<usize>,
) -> Result<String, String> {
    ops::read_file(&path, max_size).await
}

#[tauri::command]
pub async fn local_fs_write_file(path: String, content: String) -> Result<(), String> {
    ops::write_file(&path, &content).await
}

#[tauri::command]
pub async fn local_fs_search(path: String, pattern: String) -> Result<Vec<FileEntry>, String> {
    ops::search(&path, &pattern).await
}

#[tauri::command]
pub fn local_fs_get_home_dir() -> Result<String, String> {
    ops::get_home_dir()
}

#[tauri::command]
pub fn local_fs_open_in_system(path: String) -> Result<(), String> {
    ops::open_in_system(&path)
}
```

**Step 5: Update `commands/mod.rs`**

```rust
pub mod local_fs_commands;
pub mod sftp_commands;
pub mod ssh_commands;
```

**Step 6: Update `lib.rs` — add module and register commands**

```rust
mod commands;
mod fs_common;
mod local_fs;
mod sftp;
mod ssh;

use commands::{local_fs_commands, sftp_commands, ssh_commands};
use sftp::manager::SftpSessionManager;
use ssh::manager::SshSessionManager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(SshSessionManager::new())
        .manage(SftpSessionManager::new())
        .plugin(tauri_plugin_log::Builder::default().build())
        .invoke_handler(tauri::generate_handler![
            // SSH commands
            ssh_commands::ssh_connect,
            ssh_commands::ssh_write,
            ssh_commands::ssh_resize,
            ssh_commands::ssh_disconnect,
            ssh_commands::ssh_retry,
            // SFTP commands
            sftp_commands::sftp_open,
            sftp_commands::sftp_close,
            sftp_commands::sftp_list_dir,
            sftp_commands::sftp_stat,
            sftp_commands::sftp_mkdir,
            sftp_commands::sftp_rmdir,
            sftp_commands::sftp_remove,
            sftp_commands::sftp_rename,
            sftp_commands::sftp_chmod,
            sftp_commands::sftp_read_file,
            sftp_commands::sftp_write_file,
            sftp_commands::sftp_readlink,
            sftp_commands::sftp_search,
            sftp_commands::sftp_upload,
            sftp_commands::sftp_download,
            sftp_commands::sftp_transfer_list,
            sftp_commands::sftp_transfer_cancel,
            // Local FS commands
            local_fs_commands::local_fs_list_dir,
            local_fs_commands::local_fs_stat,
            local_fs_commands::local_fs_mkdir,
            local_fs_commands::local_fs_rename,
            local_fs_commands::local_fs_remove,
            local_fs_commands::local_fs_chmod,
            local_fs_commands::local_fs_read_file,
            local_fs_commands::local_fs_write_file,
            local_fs_commands::local_fs_search,
            local_fs_commands::local_fs_get_home_dir,
            local_fs_commands::local_fs_open_in_system,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

**Step 7: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles successfully

**Step 8: Commit**

```bash
git add apps/web/src-tauri/src/local_fs/
git add apps/web/src-tauri/src/commands/local_fs_commands.rs
git add apps/web/src-tauri/src/commands/mod.rs
git add apps/web/src-tauri/src/lib.rs
git add apps/web/src-tauri/Cargo.toml
git commit -m "feat: add local_fs backend with tokio::fs operations"
```

---

## Task 4: Create frontend `FileOperations` interface and adapters

**Files:**
- Modify: `apps/web/src/types/sftp.ts` — move `FileEntry` and `FileStat` to new shared file
- Create: `apps/web/src/types/fs.ts` — shared file system types
- Create: `apps/web/src/lib/file-operations.ts` — `FileOperations` interface + local/sftp implementations

**Step 1: Create `types/fs.ts` with shared types**

Move `FileEntry` and `FileStat` from `types/sftp.ts` to `types/fs.ts`:

```typescript
// apps/web/src/types/fs.ts

export interface FileEntry {
  isDir: boolean
  isSymlink: boolean
  linkTarget: string | null
  modifiedAt: number | null
  name: string
  path: string
  permissions: number
  permissionsStr: string
  size: number
}

export interface FileStat {
  accessedAt: number | null
  gid: number | null
  isDir: boolean
  isSymlink: boolean
  modifiedAt: number | null
  permissions: number
  permissionsStr: string
  size: number
  uid: number | null
}
```

**Step 2: Update `types/sftp.ts`**

Remove the `FileEntry` and `FileStat` interfaces. Re-export from `fs.ts`:

```typescript
// apps/web/src/types/sftp.ts

// Re-export shared file system types for backward compatibility.
export type { FileEntry, FileStat } from './fs'

// ... keep SftpSessionStatus, SftpSessionInfo, TransferKind, TransferStatus,
// TransferTaskInfo, SftpBookmark unchanged ...
```

**Step 3: Create `lib/file-operations.ts`**

```typescript
// apps/web/src/lib/file-operations.ts
import { invoke } from '@tauri-apps/api/core'
import type { FileEntry, FileStat } from '@/types/fs'

export interface FileOperations {
  chmod(path: string, mode: number): Promise<void>
  listDir(path: string): Promise<FileEntry[]>
  mkdir(path: string): Promise<void>
  readFile(path: string, maxSize?: number): Promise<string>
  remove(path: string): Promise<void>
  rename(oldPath: string, newPath: string): Promise<void>
  search(path: string, pattern: string): Promise<FileEntry[]>
  stat(path: string): Promise<FileStat>
  writeFile(path: string, content: string): Promise<void>
}

export function createLocalFileOps(): FileOperations {
  return {
    chmod: (path, mode) => invoke('local_fs_chmod', { path, mode }),
    listDir: (path) => invoke<FileEntry[]>('local_fs_list_dir', { path }),
    mkdir: (path) => invoke('local_fs_mkdir', { path }),
    readFile: (path, maxSize) =>
      invoke<string>('local_fs_read_file', { path, maxSize: maxSize ?? null }),
    remove: (path) => invoke('local_fs_remove', { path }),
    rename: (oldPath, newPath) => invoke('local_fs_rename', { oldPath, newPath }),
    search: (path, pattern) => invoke<FileEntry[]>('local_fs_search', { path, pattern }),
    stat: (path) => invoke<FileStat>('local_fs_stat', { path }),
    writeFile: (path, content) => invoke('local_fs_write_file', { path, content }),
  }
}

export function createSftpFileOps(sessionId: string, sftpOps: {
  chmod: (sessionId: string, path: string, mode: number) => Promise<void>
  listDir: (sessionId: string, path: string) => Promise<FileEntry[]>
  mkdir: (sessionId: string, path: string) => Promise<void>
  readFile: (sessionId: string, path: string, maxSize?: number) => Promise<string>
  remove: (sessionId: string, path: string) => Promise<void>
  rename: (sessionId: string, oldPath: string, newPath: string) => Promise<void>
  rmdir: (sessionId: string, path: string) => Promise<void>
  search: (sessionId: string, path: string, pattern: string) => Promise<FileEntry[]>
  stat: (sessionId: string, path: string) => Promise<FileStat>
  writeFile: (sessionId: string, path: string, content: string) => Promise<void>
}): FileOperations {
  return {
    chmod: (path, mode) => sftpOps.chmod(sessionId, path, mode),
    listDir: (path) => sftpOps.listDir(sessionId, path),
    mkdir: (path) => sftpOps.mkdir(sessionId, path),
    readFile: (path, maxSize) => sftpOps.readFile(sessionId, path, maxSize),
    remove: async (path) => {
      const s = await sftpOps.stat(sessionId, path)
      if (s.isDir) {
        await sftpOps.rmdir(sessionId, path)
      } else {
        await sftpOps.remove(sessionId, path)
      }
    },
    rename: (oldPath, newPath) => sftpOps.rename(sessionId, oldPath, newPath),
    search: (path, pattern) => sftpOps.search(sessionId, path, pattern),
    stat: (path) => sftpOps.stat(sessionId, path),
    writeFile: (path, content) => sftpOps.writeFile(sessionId, path, content),
  }
}

export async function getHomeDir(): Promise<string> {
  return invoke<string>('local_fs_get_home_dir')
}

export async function openInSystem(path: string): Promise<void> {
  await invoke('local_fs_open_in_system', { path })
}
```

**Step 4: Verify TypeScript**

Run: `bun run check-types`
Expected: No type errors

**Step 5: Commit**

```bash
git add apps/web/src/types/fs.ts
git add apps/web/src/types/sftp.ts
git add apps/web/src/lib/file-operations.ts
git commit -m "feat: add FileOperations interface with local/sftp adapters"
```

---

## Task 5: Extract generic file panel components from SFTP

**Files:**
- Create: `apps/web/src/components/file-panel/file-panel.tsx`
- Create: `apps/web/src/components/file-panel/file-table.tsx`
- Create: `apps/web/src/components/file-panel/file-breadcrumb.tsx`
- Create: `apps/web/src/components/file-panel/file-toolbar.tsx`
- Create: `apps/web/src/components/file-panel/file-context-menu.tsx`
- Create: `apps/web/src/components/file-panel/dialogs/preview-dialog.tsx`
- Create: `apps/web/src/components/file-panel/dialogs/editor-dialog.tsx`
- Create: `apps/web/src/components/file-panel/dialogs/chmod-dialog.tsx`
- Create: `apps/web/src/components/file-panel/dialogs/search-dialog.tsx`
- Create: `apps/web/src/components/file-panel/dialogs/bookmark-dialog.tsx`
- Create: `apps/web/src/components/file-panel/index.ts`

This is the largest task. The approach: copy each SFTP component into `file-panel/`, replace `useSftp()` hook calls with a `FileOperations` prop passed down. The key changes per component:

### Step 1: Create `file-panel/file-table.tsx`

Copy from `sftp-file-table.tsx`. Change:
- Import `FileEntry` from `@/types/fs` instead of `@/types/sftp`
- No other changes needed — this component is already generic

```typescript
// Identical to sftp-file-table.tsx except:
// - import type { FileEntry } from '@/types/fs'
// - export as FileTable instead of SftpFileTable
```

### Step 2: Create `file-panel/file-breadcrumb.tsx`

Copy from `sftp-breadcrumb.tsx`. Rename export to `FileBreadcrumb`. No logic changes needed — it's already generic.

### Step 3: Create `file-panel/file-toolbar.tsx`

Copy from `sftp-toolbar.tsx`. Rename export to `FileToolbar`. Add optional `onOpenInSystem` prop for local panel. Add `ExternalLink` icon from lucide-react.

```typescript
interface FileToolbarProps {
  onBookmarks?: () => void
  onDelete?: () => void
  onDownload?: () => void
  onNewFolder?: () => void
  onOpenInSystem?: () => void  // NEW: local only
  onRefresh?: () => void
  onSearch?: () => void
  onUpload?: () => void
}
```

Add "Open in System" button after the separator, before Bookmarks:

```tsx
{onOpenInSystem && (
  <ToolbarButton
    icon={<ExternalLink className="h-4 w-4" />}
    label="Open in System"
    onClick={onOpenInSystem}
  />
)}
```

### Step 4: Create `file-panel/file-context-menu.tsx`

Copy from `sftp-context-menu.tsx`. Rename export to `FileContextMenu`. Add optional `onOpenInSystem` prop.

```typescript
interface FileContextMenuProps {
  // ... same as SftpContextMenuProps
  onOpenInSystem?: (entry: FileEntry) => void  // NEW
}
```

Add menu item between "Download" and separator:

```tsx
{onOpenInSystem && !entry.isDir && (
  <MenuItem
    icon={<ExternalLink className="h-4 w-4" />}
    label="Open in System App"
    onClick={() => handleAction(onOpenInSystem)}
  />
)}
```

### Step 5: Create dialog components

Each dialog needs to accept `FileOperations` instead of using `useSftp()`:

**`dialogs/preview-dialog.tsx`** — based on `sftp-preview-dialog.tsx`:
- Replace `useSftp()` with prop `readFile: (path: string, maxSize?: number) => Promise<string>`

**`dialogs/editor-dialog.tsx`** — based on `sftp-editor-dialog.tsx`:
- Replace `useSftp()` with props `readFile` and `writeFile`

**`dialogs/chmod-dialog.tsx`** — based on `sftp-chmod-dialog.tsx`:
- Replace `useSftp()` with prop `chmod: (path: string, mode: number) => Promise<void>`

**`dialogs/search-dialog.tsx`** — based on `sftp-search-dialog.tsx`:
- Replace `useSftp()` with prop `search: (path: string, pattern: string) => Promise<FileEntry[]>`

**`dialogs/bookmark-dialog.tsx`** — based on `sftp-bookmark-list.tsx`:
- For remote: keep oRPC-based bookmarks (server-stored)
- For local: use localStorage-based bookmarks
- Accept `source: 'local' | 'remote'` prop to switch behavior

### Step 6: Create `file-panel/file-panel.tsx`

This is the core component. Based on `sftp-file-panel.tsx` but parameterized with `FileOperations`.

```typescript
import type { FileOperations } from '@/lib/file-operations'
import type { FileEntry } from '@/types/fs'

interface FilePanelProps {
  extraContextMenuItems?: {
    onOpenInSystem?: (entry: FileEntry) => void
  }
  hostId?: string  // for remote bookmarks
  initialPath: string
  onDownload?: (entries: FileEntry[]) => void
  onUpload?: () => void
  operations: FileOperations
  source: 'local' | 'remote'
}
```

Key differences from `SftpFilePanel`:
- Uses `operations.listDir(path)` instead of `listDir(sftpSessionId, path)`
- Uses `operations.mkdir(path)` instead of `mkdir(sftpSessionId, path)`
- Uses `operations.remove(path)` for both files and dirs (the adapter handles it)
- Uses `operations.rename(old, new)` instead of `rename(sftpSessionId, old, new)`
- Passes `operations.readFile`/`operations.writeFile`/`operations.chmod`/`operations.search` to dialog components
- No `sftpSessionId` dependency — operations are pre-bound

### Step 7: Create `file-panel/index.ts`

```typescript
export { FilePanel } from './file-panel'
export { FileTable } from './file-table'
export { FileBreadcrumb } from './file-breadcrumb'
export { FileToolbar } from './file-toolbar'
export { FileContextMenu } from './file-context-menu'
```

### Step 8: Verify TypeScript

Run: `bun run check-types`
Expected: No type errors

### Step 9: Commit

```bash
git add apps/web/src/components/file-panel/
git commit -m "feat: extract generic file-panel components from SFTP"
```

---

## Task 6: Update `SftpFilePanel` to use generic `FilePanel`

**Files:**
- Modify: `apps/web/src/components/sftp/sftp-file-panel.tsx`

**Step 1: Rewrite `SftpFilePanel` as thin wrapper**

Replace the entire file with a thin wrapper that delegates to `FilePanel`:

```typescript
import { invoke } from '@tauri-apps/api/core'
import { useMemo } from 'react'
import { FilePanel } from '@/components/file-panel'
import { createLocalFileOps, createSftpFileOps, getHomeDir, openInSystem } from '@/lib/file-operations'
import type { FileEntry } from '@/types/fs'
import { useSftp } from './sftp-provider'

interface SftpFilePanelProps {
  onDownload?: (entries: FileEntry[]) => void
  onUpload?: () => void
  sftpSessionId?: string
  source: 'local' | 'remote'
}

export function SftpFilePanel({ source, sftpSessionId, onUpload, onDownload }: SftpFilePanelProps) {
  const sftp = useSftp()
  const session = sftpSessionId ? (sftp.sessions.get(sftpSessionId) ?? null) : null

  const operations = useMemo(() => {
    if (source === 'local') {
      return createLocalFileOps()
    }
    if (sftpSessionId) {
      return createSftpFileOps(sftpSessionId, sftp)
    }
    return null
  }, [source, sftpSessionId, sftp])

  const [initialPath, setInitialPath] = useState('/')
  const [ready, setReady] = useState(source === 'remote')

  useEffect(() => {
    if (source === 'local') {
      // Try to restore last path from localStorage, fallback to home dir
      const saved = localStorage.getItem('caterm:local-file-panel:lastPath')
      if (saved) {
        setInitialPath(saved)
        setReady(true)
      } else {
        getHomeDir().then((home) => {
          setInitialPath(home)
          setReady(true)
        }).catch(() => {
          setInitialPath('/')
          setReady(true)
        })
      }
    }
  }, [source])

  if (!operations || !ready) {
    return (
      <div className="flex h-full items-center justify-center">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    )
  }

  return (
    <FilePanel
      extraContextMenuItems={
        source === 'local'
          ? { onOpenInSystem: (entry) => openInSystem(entry.path) }
          : undefined
      }
      hostId={session?.hostId}
      initialPath={initialPath}
      onDownload={onDownload}
      onPathChange={
        source === 'local'
          ? (path) => localStorage.setItem('caterm:local-file-panel:lastPath', path)
          : undefined
      }
      onUpload={onUpload}
      operations={operations}
      source={source}
    />
  )
}
```

Note: Add missing imports (`useState`, `useEffect`, `Loader2`) and add `onPathChange` prop to `FilePanel` for localStorage persistence.

**Step 2: Verify TypeScript**

Run: `bun run check-types`

**Step 3: Run lint**

Run: `bun x ultracite fix`

**Step 4: Commit**

```bash
git add apps/web/src/components/sftp/sftp-file-panel.tsx
git commit -m "refactor: SftpFilePanel now delegates to generic FilePanel"
```

---

## Task 7: Add local bookmarks (localStorage)

**Files:**
- Modify: `apps/web/src/components/file-panel/dialogs/bookmark-dialog.tsx`

**Step 1: Implement local bookmarks using localStorage**

For `source === 'local'`, store bookmarks in localStorage under key `caterm:local-bookmarks`:

```typescript
interface LocalBookmark {
  id: string
  label: string
  path: string
}

function getLocalBookmarks(): LocalBookmark[] {
  const raw = localStorage.getItem('caterm:local-bookmarks')
  return raw ? JSON.parse(raw) : []
}

function saveLocalBookmarks(bookmarks: LocalBookmark[]) {
  localStorage.setItem('caterm:local-bookmarks', JSON.stringify(bookmarks))
}
```

Add preset bookmarks for the local panel:
- Home directory (from `getHomeDir()`)
- Desktop (`$HOME/Desktop`)
- Downloads (`$HOME/Downloads`)
- Documents (`$HOME/Documents`)

**Step 2: Commit**

```bash
git add apps/web/src/components/file-panel/dialogs/bookmark-dialog.tsx
git commit -m "feat: add localStorage-based bookmarks for local file panel"
```

---

## Task 8: Add drag-and-drop transfer between panels

**Files:**
- Modify: `apps/web/src/components/file-panel/file-table.tsx` — add `draggable` + drag data
- Modify: `apps/web/src/components/file-panel/file-panel.tsx` — add drop zone handling
- Modify: `apps/web/src/components/sftp/sftp-file-manager.tsx` — wire up transfer callbacks

**Step 1: Add drag support to `file-table.tsx`**

Add `source` prop to `FileTable`. On each row:

```tsx
<TableRow
  draggable
  onDragStart={(e) => {
    const dragData = JSON.stringify({
      source,
      entries: selectedPaths.has(entry.path)
        ? entries.filter((e) => selectedPaths.has(e.path))
        : [entry]
    })
    e.dataTransfer.setData('application/x-caterm-files', dragData)
    e.dataTransfer.effectAllowed = 'copy'
  }}
  // ... existing props
>
```

**Step 2: Add drop zone to `file-panel.tsx`**

Add `onDrop` prop to `FilePanel`:

```typescript
interface FilePanelProps {
  // ... existing
  onDrop?: (entries: FileEntry[], targetPath: string) => void
}
```

Wrap the panel content with drag-over/drop handlers:

```tsx
const [dragOver, setDragOver] = useState(false)

<div
  className={`flex h-full flex-col ${dragOver ? 'ring-2 ring-primary ring-inset' : ''}`}
  onDragOver={(e) => {
    if (e.dataTransfer.types.includes('application/x-caterm-files')) {
      e.preventDefault()
      setDragOver(true)
    }
  }}
  onDragLeave={() => setDragOver(false)}
  onDrop={(e) => {
    e.preventDefault()
    setDragOver(false)
    const raw = e.dataTransfer.getData('application/x-caterm-files')
    if (raw && onDrop) {
      const { entries } = JSON.parse(raw)
      onDrop(entries, currentPath)
    }
  }}
>
```

**Step 3: Wire up transfer in `sftp-file-manager.tsx`**

Handle drops on each panel:
- Drop on local panel → download from remote
- Drop on remote panel → upload from local

```typescript
const handleLocalDrop = useCallback(async (entries: FileEntry[], targetPath: string) => {
  if (!activeSftpSessionId) return
  for (const entry of entries) {
    if (!entry.isDir) {
      const localPath = `${targetPath}/${entry.name}`
      await download(activeSftpSessionId, entry.path, localPath)
    }
  }
}, [activeSftpSessionId, download])

const handleRemoteDrop = useCallback(async (entries: FileEntry[], targetPath: string) => {
  if (!activeSftpSessionId) return
  for (const entry of entries) {
    if (!entry.isDir) {
      const remotePath = targetPath === '/' ? `/${entry.name}` : `${targetPath}/${entry.name}`
      await upload(activeSftpSessionId, entry.path, remotePath)
    }
  }
}, [activeSftpSessionId, upload])
```

**Step 4: Verify TypeScript & lint**

Run: `bun run check-types && bun x ultracite fix`

**Step 5: Commit**

```bash
git add apps/web/src/components/file-panel/
git add apps/web/src/components/sftp/sftp-file-manager.tsx
git commit -m "feat: add drag-and-drop file transfer between local and remote panels"
```

---

## Task 9: Add button-based transfer

**Files:**
- Modify: `apps/web/src/components/sftp/sftp-file-manager.tsx`

**Step 1: Wire up upload/download button callbacks**

The `SftpToolbar` already has upload/download buttons. Pass callbacks from `sftp-file-manager.tsx` into each `SftpFilePanel`:

- Local panel's "Upload" button → upload selected local files to remote panel's current path
- Remote panel's "Download" button → download selected remote files to local panel's current path

Track each panel's current path and selected entries via callback props or refs.

**Step 2: Verify & commit**

```bash
git add apps/web/src/components/sftp/sftp-file-manager.tsx
git commit -m "feat: add button-based upload/download between panels"
```

---

## Task 10: Final verification and cleanup

**Step 1: Run full type check**

Run: `bun run check-types`
Expected: No errors

**Step 2: Run lint & format**

Run: `bun x ultracite fix`
Expected: Auto-fixed, no remaining errors

**Step 3: Run lint check**

Run: `bun x ultracite check`
Expected: All clean

**Step 4: Manual testing checklist**

- [ ] Local panel shows home directory on first load
- [ ] Navigate directories, breadcrumb works
- [ ] Create new folder in local panel
- [ ] Rename file in local panel
- [ ] Delete file in local panel
- [ ] Preview text file in local panel
- [ ] Edit and save text file in local panel
- [ ] Change permissions (chmod) in local panel
- [ ] Search files in local panel
- [ ] "Open in System App" context menu works
- [ ] Add/remove local bookmarks
- [ ] Drag file from local to remote (upload)
- [ ] Drag file from remote to local (download)
- [ ] Upload button from local toolbar
- [ ] Download button from remote toolbar
- [ ] Transfer progress shows in queue
- [ ] Path persists in localStorage between sessions

**Step 5: Final commit**

```bash
git add -A
git commit -m "chore: lint and cleanup for local file browser feature"
```
