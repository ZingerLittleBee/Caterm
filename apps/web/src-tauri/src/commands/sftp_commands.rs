use serde::Serialize;
use tauri::{AppHandle, State};

use crate::sftp::manager::SftpSessionManager;
use crate::sftp::session::{SftpConnectConfig, SftpSessionEntry};
use crate::sftp::transfer::TransferTaskInfo;
use crate::ssh::session::AuthMethod;

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

/// File stat information returned by the stat command.
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
fn format_permissions(mode: u32, is_dir: bool) -> String {
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

/// Normalize a remote path by joining parent and name.
fn join_path(parent: &str, name: &str) -> String {
    if parent.ends_with('/') {
        format!("{parent}{name}")
    } else {
        format!("{parent}/{name}")
    }
}

// ---------------------------------------------------------------------------
// Session management commands
// ---------------------------------------------------------------------------

/// Open a standalone SFTP connection. Returns the session ID.
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
            let password = password.ok_or("Password is required for password authentication")?;
            AuthMethod::Password(password)
        }
        "key" => {
            let key = private_key.ok_or("Private key is required for key authentication")?;
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

/// Close an SFTP session by ID.
#[tauri::command]
pub async fn sftp_close(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
) -> Result<(), String> {
    manager.close(&session_id).await
}

// ---------------------------------------------------------------------------
// File operation commands
// ---------------------------------------------------------------------------

/// List directory contents. Returns entries sorted with directories first, then by name.
#[tauri::command]
pub async fn sftp_list_dir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<Vec<FileEntry>, String> {
    let sftp = manager.get_sftp(&session_id).await?;

    let read_dir = sftp
        .read_dir(&path)
        .await
        .map_err(|e| format!("Failed to list directory: {e}"))?;

    let mut entries: Vec<FileEntry> = Vec::new();

    for dir_entry in read_dir {
        let name = dir_entry.file_name();
        if name == "." || name == ".." {
            continue;
        }
        let metadata = dir_entry.metadata();
        let is_dir = metadata.is_dir();
        let is_symlink = metadata.is_symlink();
        let size = metadata.size.unwrap_or(0);
        let perms = metadata.permissions.unwrap_or(0);
        let mtime = metadata.mtime.map(|t| t as i64);
        let entry_path = join_path(&path, &name);

        entries.push(FileEntry {
            name,
            path: entry_path,
            is_dir,
            is_symlink,
            size,
            permissions: perms & 0o7777,
            permissions_str: format_permissions(perms, is_dir),
            modified_at: mtime,
            link_target: None,
        });
    }

    // Sort: directories first, then alphabetically by name (case-insensitive).
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(entries)
}

/// Get file/directory metadata.
#[tauri::command]
pub async fn sftp_stat(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<FileStat, String> {
    let sftp = manager.get_sftp(&session_id).await?;

    let metadata = sftp
        .metadata(&path)
        .await
        .map_err(|e| format!("Failed to stat: {e}"))?;

    let is_dir = metadata.is_dir();
    let perms = metadata.permissions.unwrap_or(0);

    Ok(FileStat {
        size: metadata.size.unwrap_or(0),
        permissions: perms & 0o7777,
        permissions_str: format_permissions(perms, is_dir),
        modified_at: metadata.mtime.map(|t| t as i64),
        accessed_at: metadata.atime.map(|t| t as i64),
        is_dir,
        is_symlink: metadata.is_symlink(),
        uid: metadata.uid,
        gid: metadata.gid,
    })
}

/// Create a remote directory.
#[tauri::command]
pub async fn sftp_mkdir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    let sftp = manager.get_sftp(&session_id).await?;
    sftp.create_dir(&path)
        .await
        .map_err(|e| format!("Failed to create directory: {e}"))
}

/// Remove a remote directory.
#[tauri::command]
pub async fn sftp_rmdir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    let sftp = manager.get_sftp(&session_id).await?;
    sftp.remove_dir(&path)
        .await
        .map_err(|e| format!("Failed to remove directory: {e}"))
}

/// Remove a remote file.
#[tauri::command]
pub async fn sftp_remove(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    let sftp = manager.get_sftp(&session_id).await?;
    sftp.remove_file(&path)
        .await
        .map_err(|e| format!("Failed to remove file: {e}"))
}

/// Rename a remote file or directory.
#[tauri::command]
pub async fn sftp_rename(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    from: String,
    to: String,
) -> Result<(), String> {
    let sftp = manager.get_sftp(&session_id).await?;
    sftp.rename(&from, &to)
        .await
        .map_err(|e| format!("Failed to rename: {e}"))
}

/// Change permissions on a remote file or directory.
#[tauri::command]
pub async fn sftp_chmod(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    mode: u32,
) -> Result<(), String> {
    use russh_sftp::protocol::FileAttributes;

    let sftp = manager.get_sftp(&session_id).await?;

    let mut attrs = FileAttributes::empty();
    attrs.permissions = Some(mode);

    sftp.set_metadata(&path, attrs)
        .await
        .map_err(|e| format!("Failed to chmod: {e}"))
}

/// Read a remote file as UTF-8 text. Max 1 MB.
#[tauri::command]
pub async fn sftp_read_file(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<String, String> {
    const MAX_SIZE: usize = 1_048_576; // 1 MB

    let sftp = manager.get_sftp(&session_id).await?;

    let data = sftp
        .read(&path)
        .await
        .map_err(|e| format!("Failed to read file: {e}"))?;

    if data.len() > MAX_SIZE {
        return Err(format!(
            "File too large: {} bytes (max {} bytes)",
            data.len(),
            MAX_SIZE
        ));
    }

    String::from_utf8(data).map_err(|_| "File is not valid UTF-8".to_string())
}

/// Write UTF-8 text to a remote file.
#[tauri::command]
pub async fn sftp_write_file(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    content: String,
) -> Result<(), String> {
    let sftp = manager.get_sftp(&session_id).await?;
    sftp.write(&path, content.as_bytes())
        .await
        .map_err(|e| format!("Failed to write file: {e}"))
}

/// Read the target of a symbolic link.
#[tauri::command]
pub async fn sftp_readlink(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<String, String> {
    let sftp = manager.get_sftp(&session_id).await?;
    sftp.read_link(&path)
        .await
        .map_err(|e| format!("Failed to read link: {e}"))
}

/// Recursively search for files matching a pattern. Max 500 results.
#[tauri::command]
pub async fn sftp_search(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    pattern: String,
) -> Result<Vec<FileEntry>, String> {
    const MAX_RESULTS: usize = 500;

    let sftp = manager.get_sftp(&session_id).await?;
    let pattern_lower = pattern.to_lowercase();
    let mut results: Vec<FileEntry> = Vec::new();
    let mut dirs_to_visit: Vec<String> = vec![path];

    while let Some(current_dir) = dirs_to_visit.pop() {
        if results.len() >= MAX_RESULTS {
            break;
        }

        let read_dir = match sftp.read_dir(&current_dir).await {
            Ok(rd) => rd,
            Err(_) => continue, // Skip directories we can't read.
        };

        for dir_entry in read_dir {
            if results.len() >= MAX_RESULTS {
                break;
            }

            let name = dir_entry.file_name();
            if name == "." || name == ".." {
                continue;
            }
            let metadata = dir_entry.metadata();
            let is_dir = metadata.is_dir();
            let is_symlink = metadata.is_symlink();
            let entry_path = join_path(&current_dir, &name);

            if is_dir {
                dirs_to_visit.push(entry_path.clone());
            }

            if name.to_lowercase().contains(&pattern_lower) {
                let size = metadata.size.unwrap_or(0);
                let perms = metadata.permissions.unwrap_or(0);
                let mtime = metadata.mtime.map(|t| t as i64);

                results.push(FileEntry {
                    name,
                    path: entry_path,
                    is_dir,
                    is_symlink,
                    size,
                    permissions: perms & 0o7777,
                    permissions_str: format_permissions(perms, is_dir),
                    modified_at: mtime,
                    link_target: None,
                });
            }
        }
    }

    // Sort: directories first, then alphabetically by name.
    results.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(results)
}

// ---------------------------------------------------------------------------
// Transfer commands
// ---------------------------------------------------------------------------

/// List all transfer tasks.
#[tauri::command]
pub async fn sftp_transfer_list(
    manager: State<'_, SftpSessionManager>,
) -> Result<Vec<TransferTaskInfo>, String> {
    Ok(manager.transfer_queue_list().await)
}

/// Cancel a transfer task by ID.
#[tauri::command]
pub async fn sftp_transfer_cancel(
    manager: State<'_, SftpSessionManager>,
    task_id: String,
) -> Result<(), String> {
    if manager.transfer_queue_cancel(&task_id).await {
        Ok(())
    } else {
        Err(format!("Transfer task not found: {task_id}"))
    }
}
