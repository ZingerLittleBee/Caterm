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
    ops::chmod(&path, mode)
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
pub async fn local_fs_search(
    path: String,
    pattern: String,
) -> Result<Vec<FileEntry>, String> {
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
