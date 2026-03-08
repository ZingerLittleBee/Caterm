use crate::fs_common::types::{format_permissions, join_path, sort_entries, FileEntry, FileStat};

/// Validate that a path is absolute to prevent path traversal attacks.
fn validate_absolute_path(path: &str) -> Result<(), String> {
    if !path.starts_with('/') {
        return Err(format!("Path must be absolute, got: {path}"));
    }
    Ok(())
}

/// List directory entries with metadata.
pub async fn list_dir(path: &str) -> Result<Vec<FileEntry>, String> {
    validate_absolute_path(path)?;
    let mut read_dir = tokio::fs::read_dir(path)
        .await
        .map_err(|e| format!("Failed to read directory: {e}"))?;

    let mut entries: Vec<FileEntry> = Vec::new();

    while let Some(dir_entry) = read_dir
        .next_entry()
        .await
        .map_err(|e| format!("Failed to read entry: {e}"))?
    {
        let name = dir_entry
            .file_name()
            .to_string_lossy()
            .into_owned();

        // Use file_type() to detect symlinks (does not follow them).
        let file_type = match dir_entry.file_type().await {
            Ok(ft) => ft,
            Err(_) => continue,
        };
        let is_symlink = file_type.is_symlink();

        // Use regular metadata (follows symlinks) for size/permissions/mtime.
        let metadata = match dir_entry.metadata().await {
            Ok(m) => m,
            Err(_) => continue,
        };

        let is_dir = metadata.is_dir();
        let size = metadata.len();
        let modified_at = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64);

        let permissions = get_permissions(&metadata);
        let entry_path = join_path(path, &name);

        let link_target = if is_symlink {
            tokio::fs::read_link(&entry_path)
                .await
                .ok()
                .map(|p| p.to_string_lossy().into_owned())
        } else {
            None
        };

        entries.push(FileEntry {
            name,
            path: entry_path,
            is_dir,
            is_symlink,
            size,
            permissions,
            permissions_str: format_permissions(permissions, is_dir),
            modified_at,
            link_target,
        });
    }

    sort_entries(&mut entries);

    Ok(entries)
}

/// Get file/directory metadata.
pub async fn stat(path: &str) -> Result<FileStat, String> {
    validate_absolute_path(path)?;
    let metadata = tokio::fs::symlink_metadata(path)
        .await
        .map_err(|e| format!("Failed to stat: {e}"))?;

    let is_dir = metadata.is_dir();
    let is_symlink = metadata.file_type().is_symlink();
    let permissions = get_permissions(&metadata);

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

    let (uid, gid) = get_uid_gid(&metadata);

    Ok(FileStat {
        size: metadata.len(),
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

/// Create a directory (and all parent directories).
pub async fn mkdir(path: &str) -> Result<(), String> {
    validate_absolute_path(path)?;
    tokio::fs::create_dir_all(path)
        .await
        .map_err(|e| format!("Failed to create directory: {e}"))
}

/// Rename a file or directory.
pub async fn rename(old_path: &str, new_path: &str) -> Result<(), String> {
    validate_absolute_path(old_path)?;
    validate_absolute_path(new_path)?;
    tokio::fs::rename(old_path, new_path)
        .await
        .map_err(|e| format!("Failed to rename: {e}"))
}

/// Remove a file or directory.
pub async fn remove(path: &str) -> Result<(), String> {
    validate_absolute_path(path)?;
    let metadata = tokio::fs::symlink_metadata(path)
        .await
        .map_err(|e| format!("Failed to stat: {e}"))?;

    if metadata.is_dir() {
        tokio::fs::remove_dir_all(path)
            .await
            .map_err(|e| format!("Failed to remove directory: {e}"))
    } else {
        tokio::fs::remove_file(path)
            .await
            .map_err(|e| format!("Failed to remove file: {e}"))
    }
}

/// Change file permissions (unix only).
pub fn chmod(path: &str, mode: u32) -> Result<(), String> {
    validate_absolute_path(path)?;
    #[cfg(unix)]
    {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let permissions = fs::Permissions::from_mode(mode);
        fs::set_permissions(path, permissions)
            .map_err(|e| format!("Failed to chmod: {e}"))
    }

    #[cfg(not(unix))]
    {
        let _ = (path, mode);
        Err("chmod is not supported on this platform".to_string())
    }
}

/// Read a file as UTF-8 text. Default max size is 1 MB.
pub async fn read_file(path: &str, max_size: Option<usize>) -> Result<String, String> {
    validate_absolute_path(path)?;
    let max_size = max_size.unwrap_or(1_048_576);

    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|e| format!("Failed to stat file: {e}"))?;

    let size = metadata.len() as usize;
    if size > max_size {
        return Err(format!(
            "File too large: {} bytes (max {} bytes)",
            size, max_size
        ));
    }

    let data = tokio::fs::read(path)
        .await
        .map_err(|e| format!("Failed to read file: {e}"))?;

    String::from_utf8(data).map_err(|_| "File is not valid UTF-8".to_string())
}

/// Write UTF-8 text to a file.
pub async fn write_file(path: &str, content: &str) -> Result<(), String> {
    validate_absolute_path(path)?;
    tokio::fs::write(path, content.as_bytes())
        .await
        .map_err(|e| format!("Failed to write file: {e}"))
}

/// Recursively search for files matching a pattern. Max 500 results, max depth 10.
pub async fn search(base_path: &str, pattern: &str) -> Result<Vec<FileEntry>, String> {
    validate_absolute_path(base_path)?;
    const MAX_RESULTS: usize = 500;
    const MAX_DEPTH: usize = 10;

    let pattern_lower = pattern.to_lowercase();
    let mut results: Vec<FileEntry> = Vec::new();
    let mut dirs_to_visit: Vec<(String, usize)> = vec![(base_path.to_string(), 0)];

    while let Some((current_dir, depth)) = dirs_to_visit.pop() {
        if results.len() >= MAX_RESULTS {
            break;
        }

        let mut read_dir = match tokio::fs::read_dir(&current_dir).await {
            Ok(rd) => rd,
            Err(_) => continue,
        };

        while let Ok(Some(dir_entry)) = read_dir.next_entry().await {
            if results.len() >= MAX_RESULTS {
                break;
            }

            let name = dir_entry.file_name().to_string_lossy().into_owned();

            // Use file_type() to detect symlinks (does not follow them).
            let file_type = match dir_entry.file_type().await {
                Ok(ft) => ft,
                Err(_) => continue,
            };
            let is_symlink = file_type.is_symlink();

            let metadata = match dir_entry.metadata().await {
                Ok(m) => m,
                Err(_) => continue,
            };

            let is_dir = metadata.is_dir();
            let entry_path = join_path(&current_dir, &name);

            if is_dir && depth < MAX_DEPTH {
                dirs_to_visit.push((entry_path.clone(), depth + 1));
            }

            if name.to_lowercase().contains(&pattern_lower) {
                let size = metadata.len();
                let permissions = get_permissions(&metadata);
                let modified_at = metadata
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64);

                let link_target = if is_symlink {
                    tokio::fs::read_link(&entry_path)
                        .await
                        .ok()
                        .map(|p| p.to_string_lossy().into_owned())
                } else {
                    None
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
                    link_target,
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
    validate_absolute_path(path)?;
    open::that(path).map_err(|e| format!("Failed to open: {e}"))
}

// ---------------------------------------------------------------------------
// Platform helpers
// ---------------------------------------------------------------------------

/// Extract unix permission bits from metadata. Returns 0o644/0o755 defaults on non-unix.
fn get_permissions(metadata: &std::fs::Metadata) -> u32 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o7777
    }

    #[cfg(not(unix))]
    {
        if metadata.permissions().readonly() {
            if metadata.is_dir() {
                0o555
            } else {
                0o444
            }
        } else if metadata.is_dir() {
            0o755
        } else {
            0o644
        }
    }
}

/// Extract uid/gid from metadata on unix. Returns (None, None) on non-unix.
fn get_uid_gid(metadata: &std::fs::Metadata) -> (Option<u32>, Option<u32>) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (Some(metadata.uid()), Some(metadata.gid()))
    }

    #[cfg(not(unix))]
    {
        let _ = metadata;
        (None, None)
    }
}
