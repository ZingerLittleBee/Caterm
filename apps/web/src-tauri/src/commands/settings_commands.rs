use crate::db::models::TerminalSettings;

/// Get the current terminal settings.
/// Returns default settings for now. Actual persistence is handled by the
/// frontend using @tauri-apps/plugin-sql.
#[tauri::command]
pub async fn get_terminal_settings() -> Result<TerminalSettings, String> {
    Ok(TerminalSettings::default())
}
