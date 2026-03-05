# SFTP File Manager Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add SFTP file management to Caterm with a sidebar file tree in the SSH terminal and a dual-pane file manager on `/sftp`.

**Architecture:** Rust `russh-sftp` backend providing SFTP operations via Tauri IPC commands, consumed by a React `SftpProvider` context that feeds two UIs: a lightweight sidebar tree and a full FileZilla-style dual-pane manager. Transfer queue with progress tracking lives in Rust, events pushed to frontend.

**Tech Stack:** Rust (russh 0.46, russh-sftp 2.1, tokio), React 19, TanStack Router/Query, Tauri 2, shadcn/ui, Drizzle ORM, oRPC

---

## Task 1: Add russh-sftp dependency and SFTP module skeleton

**Files:**
- Modify: `apps/web/src-tauri/Cargo.toml:26` (add dependency)
- Create: `apps/web/src-tauri/src/sftp/mod.rs`
- Create: `apps/web/src-tauri/src/sftp/session.rs`
- Create: `apps/web/src-tauri/src/sftp/manager.rs`
- Create: `apps/web/src-tauri/src/sftp/transfer.rs`
- Modify: `apps/web/src-tauri/src/lib.rs:1-2` (add sftp module)

**Step 1: Add russh-sftp to Cargo.toml**

Add after line 26 (`russh = "0.46"`):

```toml
russh-sftp = "2.1"
```

**Step 2: Create sftp module files**

`sftp/mod.rs`:
```rust
pub mod manager;
pub mod session;
pub mod transfer;
```

`sftp/session.rs` — empty struct placeholder:
```rust
use std::sync::Arc;

use russh::client::{self, Handle, Msg};
use russh::Channel;
use russh_sftp::client::SftpSession;
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex;

use crate::ssh::handler::SshClientHandler;
use crate::ssh::session::AuthMethod;

/// Stores connection parameters for standalone SFTP sessions.
#[derive(Clone)]
pub(crate) struct SftpConnectConfig {
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
}

/// Represents an active SFTP session.
pub struct SftpSessionEntry {
    /// Unique SFTP session ID.
    pub id: String,
    /// The host ID this session is connected to.
    pub host_id: String,
    /// If reusing an SSH terminal session, its ID.
    pub ssh_session_id: Option<String>,
    /// The russh-sftp session for file operations.
    sftp: SftpSession,
    /// The SSH handle (kept alive for standalone sessions).
    _handle: Handle<SshClientHandler>,
    /// Tauri app handle for emitting events.
    app_handle: AppHandle,
}

impl SftpSessionEntry {
    /// Open SFTP on a new standalone SSH connection.
    pub async fn open_standalone(
        id: String,
        host_id: String,
        config: &SftpConnectConfig,
        app_handle: AppHandle,
    ) -> Result<Self, String> {
        let ssh_config = Arc::new(client::Config::default());
        let addr = format!("{}:{}", config.hostname, config.port);

        let mut handle = client::connect(ssh_config, &addr, SshClientHandler)
            .await
            .map_err(|e| format!("SFTP SSH connection failed: {e}"))?;

        let auth_ok = match &config.auth {
            AuthMethod::Password(password) => handle
                .authenticate_password(&config.username, password)
                .await
                .map_err(|e| format!("SFTP SSH auth failed: {e}"))?,
            AuthMethod::PrivateKey { key, passphrase } => {
                let key_pair = russh_keys::decode_secret_key(key, passphrase.as_deref())
                    .map_err(|e| format!("Failed to decode private key: {e}"))?;
                handle
                    .authenticate_publickey(&config.username, Arc::new(key_pair))
                    .await
                    .map_err(|e| format!("SFTP SSH key auth failed: {e}"))?
            }
        };

        if !auth_ok {
            return Err("SFTP SSH authentication rejected".to_string());
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Failed to open SFTP channel: {e}"))?;

        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| format!("Failed to request SFTP subsystem: {e}"))?;

        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(|e| format!("Failed to initialize SFTP session: {e}"))?;

        Ok(Self {
            id,
            host_id,
            ssh_session_id: None,
            sftp,
            _handle: handle,
            app_handle,
        })
    }

    /// Get a reference to the SFTP session for file operations.
    pub fn sftp(&self) -> &SftpSession {
        &self.sftp
    }

    /// Get the app handle for emitting events.
    pub fn app_handle(&self) -> &AppHandle {
        &self.app_handle
    }
}
```

`sftp/manager.rs`:
```rust
use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;

use super::session::SftpSessionEntry;
use super::transfer::TransferQueue;

/// Manages all active SFTP sessions. Thread-safe via Arc<Mutex<...>>.
pub struct SftpSessionManager {
    sessions: Arc<Mutex<HashMap<String, SftpSessionEntry>>>,
    pub transfer_queue: TransferQueue,
}

impl SftpSessionManager {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            transfer_queue: TransferQueue::new(3),
        }
    }

    pub async fn add_session(&self, session: SftpSessionEntry) {
        let id = session.id.clone();
        self.sessions.lock().await.insert(id, session);
    }

    pub async fn remove_session(&self, session_id: &str) -> Option<SftpSessionEntry> {
        self.sessions.lock().await.remove(session_id)
    }

    /// Execute a closure with a reference to a session.
    /// The closure receives &SftpSessionEntry and returns a future.
    /// The lock is held for the duration of the closure.
    pub async fn with_session<F, Fut, T>(&self, session_id: &str, f: F) -> Result<T, String>
    where
        F: FnOnce(&SftpSessionEntry) -> Fut,
        Fut: std::future::Future<Output = Result<T, String>>,
    {
        let sessions = self.sessions.lock().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| format!("SFTP session not found: {session_id}"))?;
        f(session).await
    }

    pub async fn close(&self, session_id: &str) -> Result<(), String> {
        let session = self.remove_session(session_id).await;
        if let Some(session) = session {
            let _ = session.sftp().close().await;
        }
        Ok(())
    }

    pub async fn close_all(&self) {
        let drained: Vec<SftpSessionEntry> = {
            let mut sessions = self.sessions.lock().await;
            sessions.drain().map(|(_, s)| s).collect()
        };
        for session in drained {
            let _ = session.sftp().close().await;
        }
    }

    /// Close all SFTP sessions associated with a given SSH session ID.
    /// Called when an SSH terminal session disconnects.
    pub async fn close_by_ssh_session(&self, ssh_session_id: &str) {
        let to_close: Vec<String> = {
            let sessions = self.sessions.lock().await;
            sessions
                .values()
                .filter(|s| s.ssh_session_id.as_deref() == Some(ssh_session_id))
                .map(|s| s.id.clone())
                .collect()
        };
        for id in to_close {
            let _ = self.close(&id).await;
        }
    }
}

impl Default for SftpSessionManager {
    fn default() -> Self {
        Self::new()
    }
}
```

`sftp/transfer.rs` — transfer queue skeleton:
```rust
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

use serde::Serialize;
use tokio::sync::Mutex;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferKind {
    Upload,
    Download,
}

#[derive(Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum TransferStatus {
    Pending,
    Active,
    Paused,
    Completed,
    Failed,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferTaskInfo {
    pub id: String,
    pub sftp_session_id: String,
    pub kind: TransferKind,
    pub local_path: String,
    pub remote_path: String,
    pub file_name: String,
    pub size: Option<u64>,
    pub transferred: u64,
    pub status: TransferStatus,
    pub error: Option<String>,
}

pub(crate) struct TransferTask {
    pub id: String,
    pub sftp_session_id: String,
    pub kind: TransferKind,
    pub local_path: PathBuf,
    pub remote_path: String,
    pub file_name: String,
    pub size: Option<u64>,
    pub transferred: Arc<AtomicU64>,
    pub status: Arc<Mutex<TransferStatus>>,
    pub error: Arc<Mutex<Option<String>>>,
}

impl TransferTask {
    pub fn to_info(&self) -> TransferTaskInfo {
        TransferTaskInfo {
            id: self.id.clone(),
            sftp_session_id: self.sftp_session_id.clone(),
            kind: self.kind.clone(),
            local_path: self.local_path.to_string_lossy().to_string(),
            remote_path: self.remote_path.clone(),
            file_name: self.file_name.clone(),
            size: self.size,
            transferred: self.transferred.load(Ordering::Relaxed),
            status: self.status.try_lock().map(|s| s.clone()).unwrap_or(TransferStatus::Pending),
            error: self.error.try_lock().map(|e| e.clone()).unwrap_or(None),
        }
    }
}

pub struct TransferQueue {
    tasks: Arc<Mutex<VecDeque<TransferTask>>>,
    active_count: Arc<AtomicUsize>,
    max_concurrent: usize,
}

impl TransferQueue {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            tasks: Arc::new(Mutex::new(VecDeque::new())),
            active_count: Arc::new(AtomicUsize::new(0)),
            max_concurrent,
        }
    }

    pub async fn list(&self) -> Vec<TransferTaskInfo> {
        let tasks = self.tasks.lock().await;
        tasks.iter().map(|t| t.to_info()).collect()
    }

    pub async fn cancel(&self, task_id: &str) -> Result<(), String> {
        let mut tasks = self.tasks.lock().await;
        if let Some(task) = tasks.iter().find(|t| t.id == task_id) {
            let mut status = task.status.lock().await;
            *status = TransferStatus::Failed;
            *task.error.lock().await = Some("Cancelled".to_string());
        }
        // Remove completed/failed tasks
        tasks.retain(|t| {
            let status = t.status.try_lock().map(|s| s.clone()).unwrap_or(TransferStatus::Pending);
            status != TransferStatus::Completed && status != TransferStatus::Failed
        });
        Ok(())
    }
}
```

**Step 3: Register sftp module in lib.rs**

Modify `lib.rs` to add the module declaration:

```rust
mod commands;
mod sftp;
mod ssh;
```

**Step 4: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles successfully (warnings OK, no errors)

**Step 5: Commit**

```bash
git add apps/web/src-tauri/
git commit -m "feat(sftp): add russh-sftp dependency and module skeleton"
```

---

## Task 2: Implement SFTP Tauri IPC commands (file operations)

**Files:**
- Create: `apps/web/src-tauri/src/commands/sftp_commands.rs`
- Modify: `apps/web/src-tauri/src/commands/mod.rs:1` (add module)
- Modify: `apps/web/src-tauri/src/lib.rs` (register commands + manager state)

**Step 1: Create sftp_commands.rs with core file operations**

```rust
use serde::Serialize;
use tauri::{AppHandle, State};

use crate::sftp::manager::SftpSessionManager;
use crate::sftp::session::{SftpConnectConfig, SftpSessionEntry};
use crate::ssh::session::AuthMethod;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub permissions: u32,
    pub permissions_str: String,
    pub modified_at: String,
    pub link_target: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileStat {
    pub size: u64,
    pub permissions: u32,
    pub permissions_str: String,
    pub modified_at: String,
    pub accessed_at: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub uid: u32,
    pub gid: u32,
}

/// Format Unix permission bits to string like "-rwxr-xr-x".
fn format_permissions(mode: u32, is_dir: bool) -> String {
    let mut s = String::with_capacity(10);
    s.push(if is_dir { 'd' } else { '-' });
    for shift in [6, 3, 0] {
        let bits = (mode >> shift) & 7;
        s.push(if bits & 4 != 0 { 'r' } else { '-' });
        s.push(if bits & 2 != 0 { 'w' } else { '-' });
        s.push(if bits & 1 != 0 { 'x' } else { '-' });
    }
    s
}

/// Open a standalone SFTP session (new SSH connection).
#[tauri::command]
pub async fn sftp_open(
    app: AppHandle,
    manager: State<'_, SftpSessionManager>,
    host_id: String,
    hostname: String,
    port: Option<u16>,
    username: String,
    auth_type: String,
    password: Option<String>,
    private_key: Option<String>,
    key_passphrase: Option<String>,
) -> Result<String, String> {
    let session_id = uuid::Uuid::new_v4().to_string();
    let port = port.unwrap_or(22);

    let auth = match auth_type.as_str() {
        "password" => {
            let pw = password.ok_or("Password required for password auth")?;
            AuthMethod::Password(pw)
        }
        "key" => {
            let key = private_key.ok_or("Private key required for key auth")?;
            AuthMethod::PrivateKey {
                key,
                passphrase: key_passphrase,
            }
        }
        _ => return Err(format!("Unsupported auth type: {auth_type}")),
    };

    let config = SftpConnectConfig {
        hostname,
        port,
        username,
        auth,
    };

    let session =
        SftpSessionEntry::open_standalone(session_id.clone(), host_id, &config, app).await?;

    manager.add_session(session).await;
    Ok(session_id)
}

/// Close an SFTP session.
#[tauri::command]
pub async fn sftp_close(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
) -> Result<(), String> {
    manager.close(&session_id).await
}

/// List directory contents.
#[tauri::command]
pub async fn sftp_list_dir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<Vec<FileEntry>, String> {
    manager
        .with_session(&session_id, |session| async move {
            let dir = session
                .sftp()
                .read_dir(&path)
                .await
                .map_err(|e| format!("Failed to list {path}: {e}"))?;

            let mut entries = Vec::new();
            for entry in dir {
                let name = entry.file_name();
                if name == "." || name == ".." {
                    continue;
                }
                let attrs = entry.metadata();
                let is_dir = attrs.is_dir();
                let is_symlink = attrs.file_type().is_symlink();
                let size = attrs.len().unwrap_or(0);
                let permissions = attrs.permissions().map(|p| p.as_raw()).unwrap_or(0);
                let modified_at = attrs
                    .modified()
                    .map(|t| {
                        chrono::DateTime::from_timestamp(t.as_secs() as i64, 0)
                            .map(|dt| dt.to_rfc3339())
                            .unwrap_or_default()
                    })
                    .unwrap_or_default();

                let full_path = if path.ends_with('/') {
                    format!("{path}{name}")
                } else {
                    format!("{path}/{name}")
                };

                entries.push(FileEntry {
                    name,
                    path: full_path,
                    is_dir,
                    is_symlink,
                    size,
                    permissions,
                    permissions_str: format_permissions(permissions, is_dir),
                    modified_at,
                    link_target: None, // Populated separately if needed
                });
            }

            entries.sort_by(|a, b| {
                b.is_dir.cmp(&a.is_dir).then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            });

            Ok(entries)
        })
        .await
}

/// Get file/directory stat.
#[tauri::command]
pub async fn sftp_stat(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<FileStat, String> {
    manager
        .with_session(&session_id, |session| async move {
            let attrs = session
                .sftp()
                .metadata(&path)
                .await
                .map_err(|e| format!("Failed to stat {path}: {e}"))?;

            let is_dir = attrs.is_dir();
            let is_symlink = attrs.file_type().is_symlink();
            let size = attrs.len().unwrap_or(0);
            let permissions = attrs.permissions().map(|p| p.as_raw()).unwrap_or(0);
            let modified_at = attrs
                .modified()
                .map(|t| {
                    chrono::DateTime::from_timestamp(t.as_secs() as i64, 0)
                        .map(|dt| dt.to_rfc3339())
                        .unwrap_or_default()
                })
                .unwrap_or_default();
            let accessed_at = attrs
                .accessed()
                .map(|t| {
                    chrono::DateTime::from_timestamp(t.as_secs() as i64, 0)
                        .map(|dt| dt.to_rfc3339())
                        .unwrap_or_default()
                })
                .unwrap_or_default();

            Ok(FileStat {
                size,
                permissions,
                permissions_str: format_permissions(permissions, is_dir),
                modified_at,
                accessed_at,
                is_dir,
                is_symlink,
                uid: attrs.uid().unwrap_or(0),
                gid: attrs.gid().unwrap_or(0),
            })
        })
        .await
}

/// Create a directory.
#[tauri::command]
pub async fn sftp_mkdir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    manager
        .with_session(&session_id, |session| async move {
            session
                .sftp()
                .create_dir(&path)
                .await
                .map_err(|e| format!("Failed to mkdir {path}: {e}"))
        })
        .await
}

/// Remove a directory.
#[tauri::command]
pub async fn sftp_rmdir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    manager
        .with_session(&session_id, |session| async move {
            session
                .sftp()
                .remove_dir(&path)
                .await
                .map_err(|e| format!("Failed to rmdir {path}: {e}"))
        })
        .await
}

/// Remove a file.
#[tauri::command]
pub async fn sftp_remove(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    manager
        .with_session(&session_id, |session| async move {
            session
                .sftp()
                .remove_file(&path)
                .await
                .map_err(|e| format!("Failed to remove {path}: {e}"))
        })
        .await
}

/// Rename/move a file or directory.
#[tauri::command]
pub async fn sftp_rename(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    from: String,
    to: String,
) -> Result<(), String> {
    manager
        .with_session(&session_id, |session| async move {
            session
                .sftp()
                .rename(&from, &to)
                .await
                .map_err(|e| format!("Failed to rename {from} -> {to}: {e}"))
        })
        .await
}

/// Change file permissions.
#[tauri::command]
pub async fn sftp_chmod(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    mode: u32,
) -> Result<(), String> {
    manager
        .with_session(&session_id, |session| async move {
            session
                .sftp()
                .set_permissions(&path, mode.into())
                .await
                .map_err(|e| format!("Failed to chmod {path}: {e}"))
        })
        .await
}

/// Read a small file's content as UTF-8 string (for preview/edit, max 1MB).
#[tauri::command]
pub async fn sftp_read_file(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<String, String> {
    manager
        .with_session(&session_id, |session| async move {
            let data = session
                .sftp()
                .read(&path)
                .await
                .map_err(|e| format!("Failed to read {path}: {e}"))?;

            if data.len() > 1_048_576 {
                return Err("File too large for preview (max 1MB)".to_string());
            }

            String::from_utf8(data).map_err(|_| "File is not valid UTF-8".to_string())
        })
        .await
}

/// Write content to a file (for edit save).
#[tauri::command]
pub async fn sftp_write_file(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    content: String,
) -> Result<(), String> {
    manager
        .with_session(&session_id, |session| async move {
            session
                .sftp()
                .write(&path, content.as_bytes())
                .await
                .map_err(|e| format!("Failed to write {path}: {e}"))
        })
        .await
}

/// Read a symlink target.
#[tauri::command]
pub async fn sftp_readlink(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<String, String> {
    manager
        .with_session(&session_id, |session| async move {
            let target = session
                .sftp()
                .read_link(&path)
                .await
                .map_err(|e| format!("Failed to readlink {path}: {e}"))?;
            Ok(target.to_string_lossy().to_string())
        })
        .await
}

/// Recursively search for files matching a pattern.
#[tauri::command]
pub async fn sftp_search(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    pattern: String,
) -> Result<Vec<FileEntry>, String> {
    manager
        .with_session(&session_id, |session| async move {
            let pattern_lower = pattern.to_lowercase();
            let mut results = Vec::new();
            let mut stack = vec![path];

            while let Some(dir) = stack.pop() {
                let entries = match session.sftp().read_dir(&dir).await {
                    Ok(e) => e,
                    Err(_) => continue, // Skip unreadable directories
                };

                for entry in entries {
                    let name = entry.file_name();
                    if name == "." || name == ".." {
                        continue;
                    }
                    let attrs = entry.metadata();
                    let is_dir = attrs.is_dir();
                    let full_path = if dir.ends_with('/') {
                        format!("{dir}{name}")
                    } else {
                        format!("{dir}/{name}")
                    };

                    if name.to_lowercase().contains(&pattern_lower) {
                        let size = attrs.len().unwrap_or(0);
                        let permissions = attrs.permissions().map(|p| p.as_raw()).unwrap_or(0);
                        let modified_at = attrs
                            .modified()
                            .map(|t| {
                                chrono::DateTime::from_timestamp(t.as_secs() as i64, 0)
                                    .map(|dt| dt.to_rfc3339())
                                    .unwrap_or_default()
                            })
                            .unwrap_or_default();

                        results.push(FileEntry {
                            name: name.clone(),
                            path: full_path.clone(),
                            is_dir,
                            is_symlink: attrs.file_type().is_symlink(),
                            size,
                            permissions,
                            permissions_str: format_permissions(permissions, is_dir),
                            modified_at,
                            link_target: None,
                        });
                    }

                    if is_dir && results.len() < 500 {
                        stack.push(full_path);
                    }
                }
            }

            Ok(results)
        })
        .await
}

/// Get the transfer queue status.
#[tauri::command]
pub async fn sftp_transfer_list(
    manager: State<'_, SftpSessionManager>,
) -> Result<Vec<crate::sftp::transfer::TransferTaskInfo>, String> {
    Ok(manager.transfer_queue.list().await)
}

/// Cancel a transfer.
#[tauri::command]
pub async fn sftp_transfer_cancel(
    manager: State<'_, SftpSessionManager>,
    task_id: String,
) -> Result<(), String> {
    manager.transfer_queue.cancel(&task_id).await
}
```

**Step 2: Update commands/mod.rs**

```rust
pub mod sftp_commands;
pub mod ssh_commands;
```

**Step 3: Register SFTP commands and manager in lib.rs**

```rust
mod commands;
mod sftp;
mod ssh;

use commands::sftp_commands;
use commands::ssh_commands;
use sftp::manager::SftpSessionManager;
use ssh::manager::SshSessionManager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(SshSessionManager::new())
        .manage(SftpSessionManager::new())
        .plugin(tauri_plugin_log::Builder::default().build())
        .invoke_handler(tauri::generate_handler![
            ssh_commands::ssh_connect,
            ssh_commands::ssh_write,
            ssh_commands::ssh_resize,
            ssh_commands::ssh_disconnect,
            ssh_commands::ssh_retry,
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
            sftp_commands::sftp_transfer_list,
            sftp_commands::sftp_transfer_cancel,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

**Step 4: Make AuthMethod public for sftp module**

Modify `apps/web/src-tauri/src/ssh/session.rs` — change `pub(crate)` to `pub` for `AuthMethod`:

```rust
#[derive(Clone)]
pub enum AuthMethod {
    Password(String),
    PrivateKey {
        key: String,
        passphrase: Option<String>,
    },
}
```

**Step 5: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles (may have warnings about unused items, that's OK)

> **Note:** The exact `russh-sftp` API (method names like `read_dir`, `metadata`, `read`, `write`, etc.) needs to be verified against the crate docs. The `SftpSession::new()` constructor takes a channel stream. If the API differs, adapt method calls accordingly. Use `cargo doc --open -p russh-sftp` to check.

**Step 6: Commit**

```bash
git add apps/web/src-tauri/
git commit -m "feat(sftp): implement SFTP Tauri IPC commands for file operations"
```

---

## Task 3: Implement SFTP upload/download with progress events

**Files:**
- Modify: `apps/web/src-tauri/src/sftp/transfer.rs` (add enqueue + execute logic)
- Modify: `apps/web/src-tauri/src/commands/sftp_commands.rs` (add upload/download commands)

**Step 1: Add upload/download execution to TransferQueue**

Add to `transfer.rs`:

```rust
use tauri::{AppHandle, Emitter};
use crate::sftp::manager::SftpSessionManager;

impl TransferQueue {
    /// Enqueue an upload task and start processing if capacity allows.
    pub async fn enqueue_upload(
        &self,
        sftp_session_id: String,
        local_path: PathBuf,
        remote_path: String,
        app_handle: AppHandle,
        manager: Arc<SftpSessionManager>,
    ) -> String {
        let file_name = local_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let size = tokio::fs::metadata(&local_path).await.ok().map(|m| m.len());

        let task_id = uuid::Uuid::new_v4().to_string();
        let task = TransferTask {
            id: task_id.clone(),
            sftp_session_id: sftp_session_id.clone(),
            kind: TransferKind::Upload,
            local_path: local_path.clone(),
            remote_path: remote_path.clone(),
            file_name,
            size,
            transferred: Arc::new(AtomicU64::new(0)),
            status: Arc::new(Mutex::new(TransferStatus::Pending)),
            error: Arc::new(Mutex::new(None)),
        };

        self.tasks.lock().await.push_back(task);
        self.try_start_next(app_handle, manager).await;
        task_id
    }

    /// Enqueue a download task.
    pub async fn enqueue_download(
        &self,
        sftp_session_id: String,
        remote_path: String,
        local_path: PathBuf,
        app_handle: AppHandle,
        manager: Arc<SftpSessionManager>,
    ) -> String {
        let file_name = remote_path
            .rsplit('/')
            .next()
            .unwrap_or(&remote_path)
            .to_string();

        let task_id = uuid::Uuid::new_v4().to_string();
        let task = TransferTask {
            id: task_id.clone(),
            sftp_session_id,
            kind: TransferKind::Download,
            local_path,
            remote_path,
            file_name,
            size: None, // Will be determined when transfer starts
            transferred: Arc::new(AtomicU64::new(0)),
            status: Arc::new(Mutex::new(TransferStatus::Pending)),
            error: Arc::new(Mutex::new(None)),
        };

        self.tasks.lock().await.push_back(task);
        self.try_start_next(app_handle, manager).await;
        task_id
    }

    async fn try_start_next(&self, app_handle: AppHandle, manager: Arc<SftpSessionManager>) {
        if self.active_count.load(Ordering::Relaxed) >= self.max_concurrent {
            return;
        }

        let task_info = {
            let tasks = self.tasks.lock().await;
            tasks.iter().find(|t| {
                t.status.try_lock().map(|s| *s == TransferStatus::Pending).unwrap_or(false)
            }).map(|t| {
                (
                    t.id.clone(),
                    t.sftp_session_id.clone(),
                    t.kind.clone(),
                    t.local_path.clone(),
                    t.remote_path.clone(),
                    t.transferred.clone(),
                    t.status.clone(),
                    t.error.clone(),
                )
            })
        };

        if let Some((task_id, session_id, kind, local_path, remote_path, transferred, status, error)) = task_info {
            self.active_count.fetch_add(1, Ordering::Relaxed);
            *status.lock().await = TransferStatus::Active;

            let active_count = self.active_count.clone();
            let tasks = self.tasks.clone();
            let app = app_handle.clone();
            let mgr = manager.clone();
            let queue_self_tasks = self.tasks.clone();
            let queue_self_active = self.active_count.clone();
            let queue_self_max = self.max_concurrent;

            tokio::spawn(async move {
                let result = match kind {
                    TransferKind::Upload => {
                        Self::execute_upload(&session_id, &local_path, &remote_path, &transferred, &app, &mgr).await
                    }
                    TransferKind::Download => {
                        Self::execute_download(&session_id, &remote_path, &local_path, &transferred, &app, &mgr).await
                    }
                };

                match result {
                    Ok(()) => {
                        *status.lock().await = TransferStatus::Completed;
                    }
                    Err(e) => {
                        *status.lock().await = TransferStatus::Failed;
                        *error.lock().await = Some(e);
                    }
                }

                active_count.fetch_sub(1, Ordering::Relaxed);

                // Emit final progress
                let _ = app.emit(
                    &format!("sftp-transfer-progress-{task_id}"),
                    serde_json::json!({
                        "transferred": transferred.load(Ordering::Relaxed),
                        "status": if status.lock().await.clone() == TransferStatus::Completed { "completed" } else { "failed" },
                    }),
                );
            });
        }
    }

    async fn execute_upload(
        session_id: &str,
        local_path: &PathBuf,
        remote_path: &str,
        transferred: &Arc<AtomicU64>,
        app: &AppHandle,
        manager: &Arc<SftpSessionManager>,
    ) -> Result<(), String> {
        let data = tokio::fs::read(local_path)
            .await
            .map_err(|e| format!("Failed to read local file: {e}"))?;

        let total = data.len() as u64;
        // Write in chunks for progress reporting
        let chunk_size = 65536;

        manager.with_session(session_id, |session| async move {
            let mut file = session.sftp()
                .create(remote_path)
                .await
                .map_err(|e| format!("Failed to create remote file: {e}"))?;

            for chunk in data.chunks(chunk_size) {
                file.write_all(chunk)
                    .await
                    .map_err(|e| format!("Failed to write chunk: {e}"))?;
                let new_transferred = transferred.fetch_add(chunk.len() as u64, Ordering::Relaxed) + chunk.len() as u64;
                // Emit progress periodically
                if new_transferred % (chunk_size as u64 * 4) == 0 || new_transferred >= total {
                    let _ = app.emit(
                        &format!("sftp-transfer-progress-{session_id}"),
                        serde_json::json!({
                            "transferred": new_transferred,
                            "total": total,
                            "status": "active",
                        }),
                    );
                }
            }

            file.shutdown()
                .await
                .map_err(|e| format!("Failed to finalize upload: {e}"))?;

            Ok(())
        }).await
    }

    async fn execute_download(
        session_id: &str,
        remote_path: &str,
        local_path: &PathBuf,
        transferred: &Arc<AtomicU64>,
        app: &AppHandle,
        manager: &Arc<SftpSessionManager>,
    ) -> Result<(), String> {
        let data = manager.with_session(session_id, |session| async move {
            session.sftp()
                .read(remote_path)
                .await
                .map_err(|e| format!("Failed to read remote file: {e}"))
        }).await?;

        transferred.store(data.len() as u64, Ordering::Relaxed);

        tokio::fs::write(local_path, &data)
            .await
            .map_err(|e| format!("Failed to write local file: {e}"))?;

        Ok(())
    }
}
```

**Step 2: Add upload/download Tauri commands to sftp_commands.rs**

```rust
/// Enqueue a file upload.
#[tauri::command]
pub async fn sftp_upload(
    app: AppHandle,
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    local_path: String,
    remote_path: String,
) -> Result<String, String> {
    let task_id = manager
        .transfer_queue
        .enqueue_upload(
            session_id,
            std::path::PathBuf::from(local_path),
            remote_path,
            app,
            Arc::new(manager.inner().clone()), // Note: may need Arc wrapping at manager level
        )
        .await;
    Ok(task_id)
}

/// Enqueue a file download.
#[tauri::command]
pub async fn sftp_download(
    app: AppHandle,
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    remote_path: String,
    local_path: String,
) -> Result<String, String> {
    let task_id = manager
        .transfer_queue
        .enqueue_download(
            session_id,
            remote_path,
            std::path::PathBuf::from(local_path),
            app,
            Arc::new(manager.inner().clone()),
        )
        .await;
    Ok(task_id)
}
```

> **Note:** The transfer queue's `enqueue_*` methods need `Arc<SftpSessionManager>` for the spawned tasks. This may require wrapping the manager in an Arc at the Tauri state level, or restructuring to pass session references differently. Adapt as needed during implementation.

**Step 3: Register upload/download commands in lib.rs**

Add to the `generate_handler![]` macro:
```rust
sftp_commands::sftp_upload,
sftp_commands::sftp_download,
```

**Step 4: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check`

**Step 5: Commit**

```bash
git add apps/web/src-tauri/
git commit -m "feat(sftp): add upload/download transfer queue with progress events"
```

---

## Task 4: Add SFTP frontend types

**Files:**
- Create: `apps/web/src/types/sftp.ts`

**Step 1: Create the type definitions file**

```typescript
export type SftpSessionStatus =
	| "connecting"
	| "connected"
	| "disconnected"
	| "error";

export interface SftpSessionInfo {
	hostId: string;
	hostName: string;
	id: string;
	sshSessionId: string | null;
	status: SftpSessionStatus;
}

export interface FileEntry {
	isDir: boolean;
	isSymlink: boolean;
	linkTarget?: string;
	modifiedAt: string;
	name: string;
	path: string;
	permissions: number;
	permissionsStr: string;
	size: number;
}

export interface FileStat {
	accessedAt: string;
	gid: number;
	isDir: boolean;
	isSymlink: boolean;
	modifiedAt: string;
	permissions: number;
	permissionsStr: string;
	size: number;
	uid: number;
}

export type TransferKind = "upload" | "download";

export type TransferStatus =
	| "pending"
	| "active"
	| "paused"
	| "completed"
	| "failed";

export interface TransferTask {
	error?: string;
	fileName: string;
	id: string;
	kind: TransferKind;
	localPath: string;
	remotePath: string;
	sftpSessionId: string;
	size: number | null;
	status: TransferStatus;
	transferred: number;
}

export interface SftpBookmark {
	hostId: string;
	id: string;
	label: string;
	remotePath: string;
}
```

**Step 2: Verify types**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/types/sftp.ts
git commit -m "feat(sftp): add frontend SFTP type definitions"
```

---

## Task 5: Create SftpProvider React context

**Files:**
- Create: `apps/web/src/components/sftp/sftp-provider.tsx`

**Step 1: Implement the provider**

```typescript
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { ReactNode } from "react";
import {
	createContext,
	useCallback,
	useContext,
	useEffect,
	useRef,
	useState,
} from "react";
import { toast } from "sonner";
import type {
	FileEntry,
	FileStat,
	SftpSessionInfo,
	SftpSessionStatus,
	TransferTask,
} from "@/types/sftp";

interface SftpContextValue {
	// Sessions
	activeSftpSessionId: string | null;
	close: (sessionId: string) => Promise<void>;
	openStandalone: (
		hostId: string,
		hostName: string,
		hostname: string,
		port: number,
		username: string,
		authType: "password" | "key",
		password?: string,
		privateKey?: string,
		keyPassphrase?: string,
	) => Promise<string>;
	sessions: Map<string, SftpSessionInfo>;
	setActiveSftpSession: (sessionId: string | null) => void;

	// File operations
	chmod: (sessionId: string, path: string, mode: number) => Promise<void>;
	listDir: (sessionId: string, path: string) => Promise<FileEntry[]>;
	mkdir: (sessionId: string, path: string) => Promise<void>;
	readFile: (sessionId: string, path: string) => Promise<string>;
	readlink: (sessionId: string, path: string) => Promise<string>;
	remove: (sessionId: string, path: string) => Promise<void>;
	rename: (
		sessionId: string,
		from: string,
		to: string,
	) => Promise<void>;
	rmdir: (sessionId: string, path: string) => Promise<void>;
	search: (
		sessionId: string,
		path: string,
		pattern: string,
	) => Promise<FileEntry[]>;
	stat: (sessionId: string, path: string) => Promise<FileStat>;
	writeFile: (
		sessionId: string,
		path: string,
		content: string,
	) => Promise<void>;

	// Transfers
	cancelTransfer: (taskId: string) => Promise<void>;
	download: (
		sessionId: string,
		remotePath: string,
		localPath: string,
	) => Promise<string>;
	transfers: TransferTask[];
	upload: (
		sessionId: string,
		localPath: string,
		remotePath: string,
	) => Promise<string>;
}

const SftpContext = createContext<SftpContextValue | null>(null);

export function useSftp(): SftpContextValue {
	const context = useContext(SftpContext);
	if (!context) {
		throw new Error("useSftp must be used within an SftpProvider");
	}
	return context;
}

export function SftpProvider({ children }: { children: ReactNode }) {
	const [sessions, setSessions] = useState<Map<string, SftpSessionInfo>>(
		() => new Map(),
	);
	const [activeSftpSessionId, setActiveSftpSessionId] = useState<
		string | null
	>(null);
	const [transfers, setTransfers] = useState<TransferTask[]>([]);
	const sessionsRef = useRef(sessions);
	sessionsRef.current = sessions;

	const openStandalone = useCallback(
		async (
			hostId: string,
			hostName: string,
			hostname: string,
			port: number,
			username: string,
			authType: "password" | "key",
			password?: string,
			privateKey?: string,
			keyPassphrase?: string,
		): Promise<string> => {
			const sessionId = await invoke<string>("sftp_open", {
				hostId,
				hostname,
				port,
				username,
				authType,
				password,
				privateKey,
				keyPassphrase,
			});

			const info: SftpSessionInfo = {
				id: sessionId,
				hostId,
				hostName,
				sshSessionId: null,
				status: "connected",
			};

			setSessions((prev) => {
				const next = new Map(prev);
				next.set(sessionId, info);
				return next;
			});
			setActiveSftpSessionId(sessionId);
			return sessionId;
		},
		[],
	);

	const close = useCallback(async (sessionId: string) => {
		try {
			await invoke("sftp_close", { sessionId });
		} catch {
			// May already be closed
		}
		setSessions((prev) => {
			const next = new Map(prev);
			next.delete(sessionId);
			return next;
		});
		setActiveSftpSessionId((current) =>
			current === sessionId ? null : current,
		);
	}, []);

	const setActiveSftpSession = useCallback(
		(sessionId: string | null) => {
			setActiveSftpSessionId(sessionId);
		},
		[],
	);

	// File operations — thin wrappers around Tauri invoke
	const listDir = useCallback(
		(sessionId: string, path: string) =>
			invoke<FileEntry[]>("sftp_list_dir", { sessionId, path }),
		[],
	);

	const stat = useCallback(
		(sessionId: string, path: string) =>
			invoke<FileStat>("sftp_stat", { sessionId, path }),
		[],
	);

	const mkdir = useCallback(
		(sessionId: string, path: string) =>
			invoke<void>("sftp_mkdir", { sessionId, path }),
		[],
	);

	const rmdir = useCallback(
		(sessionId: string, path: string) =>
			invoke<void>("sftp_rmdir", { sessionId, path }),
		[],
	);

	const remove = useCallback(
		(sessionId: string, path: string) =>
			invoke<void>("sftp_remove", { sessionId, path }),
		[],
	);

	const rename = useCallback(
		(sessionId: string, from: string, to: string) =>
			invoke<void>("sftp_rename", { sessionId, from, to }),
		[],
	);

	const chmod = useCallback(
		(sessionId: string, path: string, mode: number) =>
			invoke<void>("sftp_chmod", { sessionId, path, mode }),
		[],
	);

	const readFile = useCallback(
		(sessionId: string, path: string) =>
			invoke<string>("sftp_read_file", { sessionId, path }),
		[],
	);

	const writeFile = useCallback(
		(sessionId: string, path: string, content: string) =>
			invoke<void>("sftp_write_file", { sessionId, path, content }),
		[],
	);

	const readlink = useCallback(
		(sessionId: string, path: string) =>
			invoke<string>("sftp_readlink", { sessionId, path }),
		[],
	);

	const search = useCallback(
		(sessionId: string, path: string, pattern: string) =>
			invoke<FileEntry[]>("sftp_search", { sessionId, path, pattern }),
		[],
	);

	// Transfer operations
	const upload = useCallback(
		(sessionId: string, localPath: string, remotePath: string) =>
			invoke<string>("sftp_upload", { sessionId, localPath, remotePath }),
		[],
	);

	const download = useCallback(
		(sessionId: string, remotePath: string, localPath: string) =>
			invoke<string>("sftp_download", {
				sessionId,
				remotePath,
				localPath,
			}),
		[],
	);

	const cancelTransfer = useCallback(
		(taskId: string) => invoke<void>("sftp_transfer_cancel", { taskId }),
		[],
	);

	// Cleanup on unmount
	useEffect(() => {
		return () => {
			for (const sid of sessionsRef.current.keys()) {
				invoke("sftp_close", { sessionId: sid }).catch(() => {});
			}
		};
	}, []);

	return (
		<SftpContext.Provider
			value={{
				sessions,
				activeSftpSessionId,
				openStandalone,
				close,
				setActiveSftpSession,
				listDir,
				stat,
				mkdir,
				rmdir,
				remove,
				rename,
				chmod,
				readFile,
				writeFile,
				readlink,
				search,
				transfers,
				upload,
				download,
				cancelTransfer,
			}}
		>
			{children}
		</SftpContext.Provider>
	);
}
```

**Step 2: Verify types**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/components/sftp/sftp-provider.tsx
git commit -m "feat(sftp): create SftpProvider React context"
```

---

## Task 6: Add SftpProvider to routes and create /sftp page skeleton

**Files:**
- Modify: `apps/web/src/routes/ssh/route.tsx` (wrap with SftpProvider)
- Create: `apps/web/src/routes/sftp/route.tsx`
- Create: `apps/web/src/routes/sftp/index.tsx`

**Step 1: Add SftpProvider to SSH route**

Modify `apps/web/src/routes/ssh/route.tsx`:

```typescript
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { SftpProvider } from "@/components/sftp/sftp-provider";
import { SshSessionProvider } from "@/components/ssh/ssh-session-provider";
import { TerminalSettingsProvider } from "@/components/terminal/terminal-settings-provider";
import { authClient } from "@/lib/auth-client";

export const Route = createFileRoute("/ssh")({
	beforeLoad: async () => {
		const session = await authClient.getSession();
		if (!session.data) {
			throw redirect({ to: "/login" });
		}
	},
	component: SshRouteLayout,
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

**Step 2: Create /sftp route layout**

`apps/web/src/routes/sftp/route.tsx`:

```typescript
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { SftpProvider } from "@/components/sftp/sftp-provider";
import { authClient } from "@/lib/auth-client";

export const Route = createFileRoute("/sftp")({
	beforeLoad: async () => {
		const session = await authClient.getSession();
		if (!session.data) {
			throw redirect({ to: "/login" });
		}
	},
	component: SftpRouteLayout,
});

function SftpRouteLayout() {
	return (
		<SftpProvider>
			<Outlet />
		</SftpProvider>
	);
}
```

**Step 3: Create /sftp index page placeholder**

`apps/web/src/routes/sftp/index.tsx`:

```typescript
import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/sftp/")({
	component: SftpIndexPage,
});

function SftpIndexPage() {
	return (
		<div className="flex h-screen items-center justify-center text-muted-foreground">
			<p>SFTP File Manager — coming soon</p>
		</div>
	);
}
```

**Step 4: Verify types and routes generate correctly**

Run: `bun run check-types`

**Step 5: Commit**

```bash
git add apps/web/src/routes/
git commit -m "feat(sftp): add SftpProvider to routes and /sftp page skeleton"
```

---

## Task 7: Add SFTP bookmark database schema and API route

**Files:**
- Create: `packages/db/src/schema/sftp-bookmark.ts`
- Modify: `packages/db/src/schema/index.ts` (add export)
- Create: `packages/api/src/routers/sftp-bookmark.ts`
- Modify: `packages/api/src/routers/index.ts` (add to appRouter)

**Step 1: Create bookmark schema**

`packages/db/src/schema/sftp-bookmark.ts`:

```typescript
import { index, pgTable, text, timestamp } from "drizzle-orm/pg-core";
import { sshHost } from "./ssh-host";
import { user } from "./auth";

export const sftpBookmark = pgTable(
	"sftp_bookmark",
	{
		id: text("id").primaryKey(),
		userId: text("user_id")
			.notNull()
			.references(() => user.id, { onDelete: "cascade" }),
		hostId: text("host_id")
			.notNull()
			.references(() => sshHost.id, { onDelete: "cascade" }),
		remotePath: text("remote_path").notNull(),
		label: text("label").notNull(),
		createdAt: timestamp("created_at").defaultNow().notNull(),
	},
	(table) => [index("sftp_bookmark_userId_idx").on(table.userId)],
);
```

**Step 2: Export from schema index**

Add to `packages/db/src/schema/index.ts`:

```typescript
export * from "./sftp-bookmark";
```

**Step 3: Create bookmark API router**

`packages/api/src/routers/sftp-bookmark.ts`:

```typescript
import { db } from "@Caterm/db";
import { sftpBookmark } from "@Caterm/db/schema/sftp-bookmark";
import { ORPCError } from "@orpc/server";
import { and, eq } from "drizzle-orm";
import z from "zod";

import { protectedProcedure } from "../index";

export const sftpBookmarkRouter = {
	list: protectedProcedure
		.input(z.object({ hostId: z.string().optional() }).optional())
		.handler(async ({ input, context }) => {
			const conditions = [eq(sftpBookmark.userId, context.session.user.id)];
			if (input?.hostId) {
				conditions.push(eq(sftpBookmark.hostId, input.hostId));
			}
			return db
				.select()
				.from(sftpBookmark)
				.where(and(...conditions))
				.orderBy(sftpBookmark.label);
		}),

	create: protectedProcedure
		.input(
			z.object({
				hostId: z.string(),
				remotePath: z.string().min(1),
				label: z.string().min(1),
			}),
		)
		.handler(async ({ input, context }) => {
			const id = crypto.randomUUID();
			await db.insert(sftpBookmark).values({
				id,
				userId: context.session.user.id,
				hostId: input.hostId,
				remotePath: input.remotePath,
				label: input.label,
			});
			return { id };
		}),

	update: protectedProcedure
		.input(
			z.object({
				id: z.string(),
				label: z.string().min(1).optional(),
				remotePath: z.string().min(1).optional(),
			}),
		)
		.handler(async ({ input, context }) => {
			const { id, ...rest } = input;
			const result = await db
				.update(sftpBookmark)
				.set(rest)
				.where(
					and(
						eq(sftpBookmark.id, id),
						eq(sftpBookmark.userId, context.session.user.id),
					),
				)
				.returning({ id: sftpBookmark.id });
			if (result.length === 0) {
				throw new ORPCError("NOT_FOUND", { message: "Bookmark not found" });
			}
			return { id };
		}),

	delete: protectedProcedure
		.input(z.object({ id: z.string() }))
		.handler(async ({ input, context }) => {
			const result = await db
				.delete(sftpBookmark)
				.where(
					and(
						eq(sftpBookmark.id, input.id),
						eq(sftpBookmark.userId, context.session.user.id),
					),
				)
				.returning({ id: sftpBookmark.id });
			if (result.length === 0) {
				throw new ORPCError("NOT_FOUND", { message: "Bookmark not found" });
			}
			return { success: true };
		}),
};
```

**Step 4: Add to appRouter**

Modify `packages/api/src/routers/index.ts`:

```typescript
import type { RouterClient } from "@orpc/server";

import { protectedProcedure, publicProcedure } from "../index";
import { sftpBookmarkRouter } from "./sftp-bookmark";
import { sshHostRouter } from "./ssh-host";
import { terminalSettingsRouter } from "./terminal-settings";
import { todoRouter } from "./todo";

export const appRouter = {
	healthCheck: publicProcedure.handler(() => {
		return "OK";
	}),
	privateData: protectedProcedure.handler(({ context }) => {
		return {
			message: "This is private",
			user: context.session?.user,
		};
	}),
	todo: todoRouter,
	terminalSettings: terminalSettingsRouter,
	sshHost: sshHostRouter,
	sftpBookmark: sftpBookmarkRouter,
};
export type AppRouter = typeof appRouter;
export type AppRouterClient = RouterClient<typeof appRouter>;
```

**Step 5: Push schema to database**

Run: `bun run db:push`
Expected: Schema applied successfully

**Step 6: Verify types**

Run: `bun run check-types`

**Step 7: Commit**

```bash
git add packages/db/src/schema/ packages/api/src/routers/
git commit -m "feat(sftp): add bookmark database schema and oRPC API route"
```

---

## Task 8: Build sidebar file tree component

**Files:**
- Create: `apps/web/src/components/sftp/sftp-sidebar-tree.tsx`

**Step 1: Implement the sidebar tree**

This is a collapsible tree view showing remote directory structure. Key behaviors:
- Lazy-load directories on expand
- Show file icons (folder vs file)
- Right-click context menu for operations
- Double-click files to preview

```typescript
import { useCallback, useEffect, useState } from "react";
import { ChevronRight, File, Folder, FolderOpen, RefreshCw } from "lucide-react";
import { toast } from "sonner";
import { useSftp } from "@/components/sftp/sftp-provider";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { FileEntry } from "@/types/sftp";

interface TreeNode {
	entry: FileEntry;
	children: TreeNode[] | null; // null = not loaded yet
	expanded: boolean;
	loading: boolean;
}

interface SftpSidebarTreeProps {
	sftpSessionId: string;
}

export function SftpSidebarTree({ sftpSessionId }: SftpSidebarTreeProps) {
	const { listDir } = useSftp();
	const [rootPath] = useState("/");
	const [nodes, setNodes] = useState<TreeNode[]>([]);
	const [loading, setLoading] = useState(true);

	const loadDirectory = useCallback(
		async (path: string) => {
			return listDir(sftpSessionId, path);
		},
		[sftpSessionId, listDir],
	);

	const loadRoot = useCallback(async () => {
		setLoading(true);
		try {
			const entries = await loadDirectory(rootPath);
			setNodes(
				entries.map((entry) => ({
					entry,
					children: entry.isDir ? null : [],
					expanded: false,
					loading: false,
				})),
			);
		} catch (error) {
			const msg = error instanceof Error ? error.message : String(error);
			toast.error("Failed to load directory", { description: msg });
		} finally {
			setLoading(false);
		}
	}, [loadDirectory, rootPath]);

	useEffect(() => {
		loadRoot();
	}, [loadRoot]);

	const toggleExpand = useCallback(
		async (path: string) => {
			const updateNodes = (items: TreeNode[]): TreeNode[] =>
				items.map((node) => {
					if (node.entry.path === path) {
						if (node.expanded) {
							return { ...node, expanded: false };
						}
						if (node.children === null) {
							// Need to load
							return { ...node, loading: true, expanded: true };
						}
						return { ...node, expanded: true };
					}
					if (node.children && node.children.length > 0) {
						return { ...node, children: updateNodes(node.children) };
					}
					return node;
				});

			setNodes((prev) => updateNodes(prev));

			// Load children if needed
			const findNode = (items: TreeNode[]): TreeNode | undefined => {
				for (const node of items) {
					if (node.entry.path === path) return node;
					if (node.children) {
						const found = findNode(node.children);
						if (found) return found;
					}
				}
				return undefined;
			};

			const node = findNode(nodes);
			if (node && node.children === null) {
				try {
					const entries = await loadDirectory(path);
					const children = entries.map((entry) => ({
						entry,
						children: entry.isDir ? null : [],
						expanded: false,
						loading: false,
					}));

					const setChildren = (items: TreeNode[]): TreeNode[] =>
						items.map((n) => {
							if (n.entry.path === path) {
								return { ...n, children, loading: false };
							}
							if (n.children && n.children.length > 0) {
								return { ...n, children: setChildren(n.children) };
							}
							return n;
						});

					setNodes((prev) => setChildren(prev));
				} catch (error) {
					const msg =
						error instanceof Error ? error.message : String(error);
					toast.error("Failed to load directory", { description: msg });
				}
			}
		},
		[nodes, loadDirectory],
	);

	const renderNode = (node: TreeNode, depth: number) => (
		<div key={node.entry.path}>
			<button
				className="flex w-full items-center gap-1 rounded px-1 py-0.5 text-sm hover:bg-accent"
				onClick={() => {
					if (node.entry.isDir) {
						toggleExpand(node.entry.path);
					}
				}}
				style={{ paddingLeft: `${depth * 16 + 4}px` }}
				type="button"
			>
				{node.entry.isDir ? (
					<>
						<ChevronRight
							className={`h-3 w-3 shrink-0 transition-transform ${
								node.expanded ? "rotate-90" : ""
							}`}
						/>
						{node.expanded ? (
							<FolderOpen className="h-4 w-4 shrink-0 text-blue-400" />
						) : (
							<Folder className="h-4 w-4 shrink-0 text-blue-400" />
						)}
					</>
				) : (
					<>
						<span className="w-3" />
						<File className="h-4 w-4 shrink-0 text-muted-foreground" />
					</>
				)}
				<span className="truncate">{node.entry.name}</span>
			</button>
			{node.expanded && node.children && (
				<div>
					{node.children.map((child) => renderNode(child, depth + 1))}
				</div>
			)}
			{node.expanded && node.loading && (
				<div
					className="py-1 text-xs text-muted-foreground"
					style={{ paddingLeft: `${(depth + 1) * 16 + 4}px` }}
				>
					Loading...
				</div>
			)}
		</div>
	);

	return (
		<div className="flex h-full flex-col border-l">
			<div className="flex items-center justify-between border-b px-2 py-1">
				<span className="text-xs font-medium">Files</span>
				<Button
					onClick={loadRoot}
					size="icon"
					variant="ghost"
					className="h-6 w-6"
				>
					<RefreshCw className="h-3 w-3" />
				</Button>
			</div>
			<ScrollArea className="flex-1">
				<div className="p-1">
					{loading ? (
						<div className="py-4 text-center text-xs text-muted-foreground">
							Loading...
						</div>
					) : (
						nodes.map((node) => renderNode(node, 0))
					)}
				</div>
			</ScrollArea>
		</div>
	);
}
```

**Step 2: Verify types**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/components/sftp/sftp-sidebar-tree.tsx
git commit -m "feat(sftp): build sidebar file tree component"
```

---

## Task 9: Integrate sidebar file tree into SSH terminal page

**Files:**
- Modify: `apps/web/src/routes/ssh/index.tsx` (add resizable panel with file tree)

**Step 1: Add a collapsible right panel**

Add the sidebar tree to the terminal area, toggled by a button. Use the existing `ResizablePanelGroup` from shadcn/ui if available, or a simple toggle panel.

Key changes to `ssh/index.tsx`:
- Import `SftpSidebarTree` and `useSftp`
- Add state for `sftpPanelOpen`
- When a terminal session is active and connected, show a toggle button
- Auto-open SFTP session via `openFromSsh` (or standalone as fallback)
- Render `SftpSidebarTree` in a right panel

> **Implementation note:** The `openFromSsh` command needs to be implemented in Rust to reuse an existing SSH session's channel. For the initial integration, use `openStandalone` with the host's credentials. The `openFromSsh` path can be added as a follow-up optimization.

**Step 2: Verify the integration works**

Run: `bun run check-types`

**Step 3: Commit**

```bash
git add apps/web/src/routes/ssh/index.tsx
git commit -m "feat(sftp): integrate sidebar file tree into SSH terminal page"
```

---

## Task 10: Build dual-pane file manager page

**Files:**
- Create: `apps/web/src/components/sftp/sftp-file-manager.tsx`
- Create: `apps/web/src/components/sftp/sftp-file-panel.tsx`
- Create: `apps/web/src/components/sftp/sftp-file-table.tsx`
- Create: `apps/web/src/components/sftp/sftp-breadcrumb.tsx`
- Create: `apps/web/src/components/sftp/sftp-toolbar.tsx`
- Create: `apps/web/src/components/sftp/sftp-connect-dialog.tsx`
- Modify: `apps/web/src/routes/sftp/index.tsx` (use file manager component)

**Step 1: Build core components bottom-up**

Build in this order:
1. `sftp-breadcrumb.tsx` — path segments as clickable links
2. `sftp-file-table.tsx` — table of FileEntry rows with columns: name, size, permissions, modified date
3. `sftp-file-panel.tsx` — combines breadcrumb + toolbar + file table, accepts `source: "local" | "remote"` and `sftpSessionId`
4. `sftp-toolbar.tsx` — action buttons: upload, download, new folder, delete, refresh
5. `sftp-connect-dialog.tsx` — dialog to select a saved host and connect
6. `sftp-file-manager.tsx` — main layout: connect bar at top, two panels side-by-side, transfer queue at bottom

Each component should use shadcn/ui primitives (Table, Button, Breadcrumb, Dialog, etc.).

**Step 2: Wire up /sftp/index.tsx**

Replace placeholder with the file manager:

```typescript
import { createFileRoute } from "@tanstack/react-router";
import { SftpFileManager } from "@/components/sftp/sftp-file-manager";

export const Route = createFileRoute("/sftp/")({
	component: SftpIndexPage,
});

function SftpIndexPage() {
	return <SftpFileManager />;
}
```

**Step 3: Verify types**

Run: `bun run check-types`

**Step 4: Commit**

```bash
git add apps/web/src/components/sftp/ apps/web/src/routes/sftp/
git commit -m "feat(sftp): build dual-pane file manager page with core components"
```

---

## Task 11: Build transfer queue UI component

**Files:**
- Create: `apps/web/src/components/sftp/sftp-transfer-queue.tsx`

**Step 1: Implement transfer queue panel**

Collapsible bottom panel showing transfer tasks with:
- File name, direction (upload/download icon), progress bar, size, status
- Pause/resume/cancel buttons per task
- Listen to `sftp-transfer-progress-{taskId}` events for real-time updates

**Step 2: Integrate into file manager**

Add `SftpTransferQueue` to the bottom of `sftp-file-manager.tsx`.

**Step 3: Verify and commit**

```bash
git add apps/web/src/components/sftp/
git commit -m "feat(sftp): build transfer queue UI component"
```

---

## Task 12: Build context menu and advanced dialogs

**Files:**
- Create: `apps/web/src/components/sftp/sftp-context-menu.tsx`
- Create: `apps/web/src/components/sftp/sftp-chmod-dialog.tsx`
- Create: `apps/web/src/components/sftp/sftp-search-dialog.tsx`
- Create: `apps/web/src/components/sftp/sftp-preview-dialog.tsx`
- Create: `apps/web/src/components/sftp/sftp-editor-dialog.tsx`

**Step 1: Implement context menu**

Right-click on file/folder shows:
- Open / Open in editor (files only)
- Download / Upload
- Rename (F2)
- Copy path
- Permissions (chmod)
- Delete

Use shadcn/ui `ContextMenu` component.

**Step 2: Implement chmod dialog**

- Checkboxes for owner/group/others read/write/execute
- Octal input field (synced bidirectionally)
- Apply button calls `chmod()`

**Step 3: Implement search dialog**

- Input for search pattern
- Results list (reuses `FileEntry` rendering)
- Triggered by Ctrl+F or toolbar button

**Step 4: Implement preview dialog**

- Text files: display with basic code highlighting (use `<pre>` with monospace font)
- Images: inline `<img>` (read file as base64)
- Other: show file stat info
- Max 1MB check before loading

**Step 5: Implement editor dialog**

- `readFile()` -> textarea -> `writeFile()` on save
- Show file path and size in header
- Save / Cancel buttons

**Step 6: Wire context menu into file table and sidebar tree**

**Step 7: Verify and commit**

```bash
git add apps/web/src/components/sftp/
git commit -m "feat(sftp): add context menu, chmod, search, preview, and editor dialogs"
```

---

## Task 13: Build bookmark UI component

**Files:**
- Create: `apps/web/src/components/sftp/sftp-bookmark-list.tsx`

**Step 1: Implement bookmark list**

- List bookmarks from oRPC API (`sftpBookmark.list`)
- "Add bookmark" button (saves current path)
- Click bookmark navigates to that path
- Delete button per bookmark
- Shown in a popover or sidebar section

**Step 2: Integrate into file manager toolbar and sidebar tree**

- Add bookmark button to toolbar
- Show bookmark list in a popover from the toolbar

**Step 3: Verify and commit**

```bash
git add apps/web/src/components/sftp/
git commit -m "feat(sftp): build bookmark UI with oRPC integration"
```

---

## Task 14: Add SFTP navigation to app sidebar

**Files:**
- Modify: `apps/web/src/components/app-sidebar.tsx` (add SFTP link)

**Step 1: Add SFTP entry to navigation**

Add a "File Manager" link pointing to `/sftp` in the app sidebar, alongside the existing SSH Terminal link.

**Step 2: Verify and commit**

```bash
git add apps/web/src/components/app-sidebar.tsx
git commit -m "feat(sftp): add SFTP File Manager link to app sidebar"
```

---

## Task 15: Lint, type-check, and final verification

**Files:** All modified files

**Step 1: Run Ultracite lint fix**

Run: `bun x ultracite fix`

**Step 2: Run type check**

Run: `bun run check-types`
Expected: No errors

**Step 3: Verify Rust compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: No errors

**Step 4: Fix any issues found**

**Step 5: Final commit**

```bash
git add -A
git commit -m "chore: lint and type-check fixes for SFTP feature"
```

---

## Important Implementation Notes

1. **russh-sftp API verification**: The exact method names (`read_dir`, `metadata`, `create`, `read`, `write`, etc.) must be verified against `russh-sftp 2.1` docs. Run `cargo doc --open -p russh-sftp` after adding the dependency to check the actual API surface. The plan uses educated guesses based on typical SFTP client APIs.

2. **`openFromSsh` (reuse SSH connection)**: This requires exposing the SSH `Handle` from `SshSession` so that `SftpSessionEntry` can open a new channel on the same connection. The `SshSession` currently keeps `_handle` private. Task 2's `sftp_open_from_ssh` command is deferred — start with standalone connections and add reuse as a follow-up once the core works.

3. **Transfer queue Arc wrapping**: The `SftpSessionManager` may need to be stored as `Arc<SftpSessionManager>` in Tauri state for the transfer queue's spawned tasks to reference it. Test during Task 3 implementation and restructure if needed.

4. **Local file panel**: The left panel of the dual-pane manager requires Tauri's `fs` plugin. Add `tauri-plugin-fs` to Cargo.toml and configure permissions in `tauri.conf.json`. This is needed for Task 10.

5. **shadcn/ui components**: Ensure these are installed: `Table`, `ContextMenu`, `Progress`, `Breadcrumb`, `ScrollArea`. Run `bunx shadcn@latest add <component>` for any missing ones.
