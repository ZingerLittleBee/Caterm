mod commands;
mod crypto;
mod db;
mod ssh;

use commands::ssh_commands;
use db::migrations::get_migrations;
use ssh::manager::SshSessionManager;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(SshSessionManager::new())
        .plugin(
            tauri_plugin_sql::Builder::default()
                .add_migrations("sqlite:caterm.db", get_migrations())
                .build(),
        )
        .plugin(tauri_plugin_log::Builder::default().build())
        .setup(|app| {
            let salt_path = app
                .path()
                .app_local_data_dir()
                .expect("could not resolve app local data path")
                .join("salt.txt");
            app.handle().plugin(
                tauri_plugin_stronghold::Builder::with_argon2(&salt_path).build(),
            )?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ssh_commands::ssh_connect,
            ssh_commands::ssh_write,
            ssh_commands::ssh_resize,
            ssh_commands::ssh_disconnect,
            ssh_commands::ssh_retry,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
