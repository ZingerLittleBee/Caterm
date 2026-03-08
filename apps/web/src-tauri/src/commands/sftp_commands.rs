use std::sync::Arc;

use tauri::{AppHandle, Emitter, State};
use tokio::io::AsyncWriteExt;

use crate::fs_common::types::{format_permissions, join_path, sort_entries, FileEntry, FileStat};
use crate::sftp::manager::SftpSessionManager;
use crate::sftp::session::{SftpConnectConfig, SftpSessionEntry};
use crate::sftp::transfer::TransferTaskInfo;
use crate::ssh::session::AuthMethod;

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
// File operation commands (all use with_retry for transparent reconnection)
// ---------------------------------------------------------------------------

/// List directory contents. Returns entries sorted with directories first, then by name.
#[tauri::command]
pub async fn sftp_list_dir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<Vec<FileEntry>, String> {
    let read_dir = manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                sftp.read_dir(&path)
                    .await
                    .map_err(|e| format!("Failed to list directory: {e}"))
            }
        })
        .await?;

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

    sort_entries(&mut entries);

    Ok(entries)
}

/// Get file/directory metadata.
#[tauri::command]
pub async fn sftp_stat(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<FileStat, String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
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
        })
        .await
}

/// Create a remote directory.
#[tauri::command]
pub async fn sftp_mkdir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                sftp.create_dir(&path)
                    .await
                    .map_err(|e| format!("Failed to create directory: {e}"))
            }
        })
        .await
}

/// Remove a remote directory.
#[tauri::command]
pub async fn sftp_rmdir(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                sftp.remove_dir(&path)
                    .await
                    .map_err(|e| format!("Failed to remove directory: {e}"))
            }
        })
        .await
}

/// Remove a remote file.
#[tauri::command]
pub async fn sftp_remove(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<(), String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                sftp.remove_file(&path)
                    .await
                    .map_err(|e| format!("Failed to remove file: {e}"))
            }
        })
        .await
}

/// Rename a remote file or directory.
#[tauri::command]
pub async fn sftp_rename(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    from: String,
    to: String,
) -> Result<(), String> {
    manager
        .with_retry(&session_id, |sftp| {
            let from = from.clone();
            let to = to.clone();
            async move {
                sftp.rename(&from, &to)
                    .await
                    .map_err(|e| format!("Failed to rename: {e}"))
            }
        })
        .await
}

/// Change permissions on a remote file or directory.
#[tauri::command]
pub async fn sftp_chmod(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    mode: u32,
) -> Result<(), String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                use russh_sftp::protocol::FileAttributes;

                let mut attrs = FileAttributes::empty();
                attrs.permissions = Some(mode);

                sftp.set_metadata(&path, attrs)
                    .await
                    .map_err(|e| format!("Failed to chmod: {e}"))
            }
        })
        .await
}

/// Read a remote file as UTF-8 text. Default max 1 MB.
#[tauri::command]
pub async fn sftp_read_file(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    max_size: Option<usize>,
) -> Result<String, String> {
    let max_size = max_size.unwrap_or(1_048_576);

    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                let metadata = sftp
                    .metadata(&path)
                    .await
                    .map_err(|e| format!("Failed to stat file: {e}"))?;

                if let Some(size) = metadata.size {
                    if (size as usize) > max_size {
                        return Err(format!(
                            "File too large: {} bytes (max {} bytes)",
                            size, max_size
                        ));
                    }
                }

                let data = sftp
                    .read(&path)
                    .await
                    .map_err(|e| format!("Failed to read file: {e}"))?;

                String::from_utf8(data).map_err(|_| "File is not valid UTF-8".to_string())
            }
        })
        .await
}

/// Write UTF-8 text to a remote file.
#[tauri::command]
pub async fn sftp_write_file(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    content: String,
) -> Result<(), String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            let content = content.clone();
            async move {
                let mut file = sftp
                    .create(&path)
                    .await
                    .map_err(|e| format!("Failed to create remote file: {e}"))?;
                file.write_all(content.as_bytes())
                    .await
                    .map_err(|e| format!("Failed to write file: {e}"))?;
                Ok(())
            }
        })
        .await
}

/// Read the target of a symbolic link.
#[tauri::command]
pub async fn sftp_readlink(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
) -> Result<String, String> {
    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            async move {
                sftp.read_link(&path)
                    .await
                    .map_err(|e| format!("Failed to read link: {e}"))
            }
        })
        .await
}

/// Recursively search for files matching a pattern. Max 500 results, max depth 10.
#[tauri::command]
pub async fn sftp_search(
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    path: String,
    pattern: String,
) -> Result<Vec<FileEntry>, String> {
    const MAX_RESULTS: usize = 500;
    const MAX_DEPTH: usize = 10;

    let pattern_lower = pattern.to_lowercase();

    manager
        .with_retry(&session_id, |sftp| {
            let path = path.clone();
            let pattern_lower = pattern_lower.clone();
            async move {
                let mut results: Vec<FileEntry> = Vec::new();
                let mut dirs_to_visit: Vec<(String, usize)> = vec![(path, 0)];

                while let Some((current_dir, depth)) = dirs_to_visit.pop() {
                    if results.len() >= MAX_RESULTS {
                        break;
                    }

                    let read_dir = match sftp.read_dir(&current_dir).await {
                        Ok(rd) => rd,
                        Err(_) => continue,
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

                        if is_dir && depth < MAX_DEPTH {
                            dirs_to_visit.push((entry_path.clone(), depth + 1));
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

                sort_entries(&mut results);
                Ok(results)
            }
        })
        .await
}

// ---------------------------------------------------------------------------
// Upload / Download commands
// ---------------------------------------------------------------------------

/// Upload a local file to the remote server. Returns a transfer ID.
#[tauri::command]
pub async fn sftp_upload(
    app: AppHandle,
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    local_path: String,
    remote_path: String,
) -> Result<String, String> {
    let transfer_id = uuid::Uuid::new_v4().to_string();

    let data = tokio::fs::read(&local_path)
        .await
        .map_err(|e| format!("Failed to read local file: {e}"))?;

    let total_bytes = data.len() as u64;

    // Emit initial progress.
    let info = TransferTaskInfo {
        id: transfer_id.clone(),
        sftp_session_id: session_id.clone(),
        kind: crate::sftp::transfer::TransferKind::Upload,
        remote_path: remote_path.clone(),
        local_path: local_path.clone(),
        total_bytes: Some(total_bytes),
        transferred_bytes: 0,
        status: crate::sftp::transfer::TransferStatus::Active,
    };
    let _ = app.emit(&format!("sftp-transfer-progress-{session_id}"), &info);

    // Upload with auto-reconnect.
    // NOTE: SftpSession::write() only uses OpenFlags::WRITE which cannot create
    // new files. We use create() (CREATE | TRUNCATE | WRITE) instead.
    let data = Arc::new(data);
    let upload_result = manager
        .with_retry(&session_id, |sftp| {
            let remote_path = remote_path.clone();
            let data = Arc::clone(&data);
            async move {
                let mut file = sftp
                    .create(&remote_path)
                    .await
                    .map_err(|e| format!("Failed to create remote file: {e}"))?;
                file.write_all(&data)
                    .await
                    .map_err(|e| format!("Failed to upload file: {e}"))?;
                Ok(())
            }
        })
        .await;

    match upload_result {
        Ok(()) => {
            // Emit completion.
            let info = TransferTaskInfo {
                id: transfer_id.clone(),
                sftp_session_id: session_id.clone(),
                kind: crate::sftp::transfer::TransferKind::Upload,
                remote_path,
                local_path,
                total_bytes: Some(total_bytes),
                transferred_bytes: total_bytes,
                status: crate::sftp::transfer::TransferStatus::Completed,
            };
            let _ = app.emit(&format!("sftp-transfer-progress-{session_id}"), &info);
            Ok(transfer_id)
        }
        Err(e) => {
            // Emit failure so the UI can update the transfer status.
            let info = TransferTaskInfo {
                id: transfer_id.clone(),
                sftp_session_id: session_id.clone(),
                kind: crate::sftp::transfer::TransferKind::Upload,
                remote_path,
                local_path,
                total_bytes: Some(total_bytes),
                transferred_bytes: 0,
                status: crate::sftp::transfer::TransferStatus::Failed,
            };
            let _ = app.emit(&format!("sftp-transfer-progress-{session_id}"), &info);
            Err(e)
        }
    }
}

/// Download a remote file to the local filesystem. Returns a transfer ID.
#[tauri::command]
pub async fn sftp_download(
    app: AppHandle,
    manager: State<'_, SftpSessionManager>,
    session_id: String,
    remote_path: String,
    local_path: String,
) -> Result<String, String> {
    let transfer_id = uuid::Uuid::new_v4().to_string();

    // Download with auto-reconnect (stat + read together).
    let (data, total_bytes) = manager
        .with_retry(&session_id, |sftp| {
            let remote_path = remote_path.clone();
            async move {
                let metadata = sftp
                    .metadata(&remote_path)
                    .await
                    .map_err(|e| format!("Failed to stat remote file: {e}"))?;
                let total_bytes = metadata.size.unwrap_or(0);

                let data = sftp
                    .read(&remote_path)
                    .await
                    .map_err(|e| format!("Failed to download file: {e}"))?;

                Ok((data, total_bytes))
            }
        })
        .await?;

    // Emit initial progress.
    let info = TransferTaskInfo {
        id: transfer_id.clone(),
        sftp_session_id: session_id.clone(),
        kind: crate::sftp::transfer::TransferKind::Download,
        remote_path: remote_path.clone(),
        local_path: local_path.clone(),
        total_bytes: Some(total_bytes),
        transferred_bytes: 0,
        status: crate::sftp::transfer::TransferStatus::Active,
    };
    let _ = app.emit(&format!("sftp-transfer-progress-{session_id}"), &info);

    tokio::fs::write(&local_path, &data)
        .await
        .map_err(|e| format!("Failed to write local file: {e}"))?;

    // Emit completion.
    let info = TransferTaskInfo {
        id: transfer_id.clone(),
        sftp_session_id: session_id.clone(),
        kind: crate::sftp::transfer::TransferKind::Download,
        remote_path,
        local_path,
        total_bytes: Some(total_bytes),
        transferred_bytes: total_bytes,
        status: crate::sftp::transfer::TransferStatus::Completed,
    };
    let _ = app.emit(&format!("sftp-transfer-progress-{session_id}"), &info);

    Ok(transfer_id)
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
