type Result<T> = std::result::Result<T, String>;

#[tauri::command]
pub async fn export_config(_password: String) -> Result<Vec<u8>> {
    Err("Export not yet implemented".to_string())
}

#[tauri::command]
pub async fn import_config(_data: Vec<u8>, _password: String) -> Result<()> {
    Err("Import not yet implemented".to_string())
}
