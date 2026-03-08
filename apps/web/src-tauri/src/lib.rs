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
            sftp_commands::sftp_upload,
            sftp_commands::sftp_download,
            sftp_commands::sftp_transfer_list,
            sftp_commands::sftp_transfer_cancel,
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
