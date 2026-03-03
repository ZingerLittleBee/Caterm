//! Host CRUD commands.
//!
//! Note: The tauri-plugin-sql v2 does not expose a straightforward Rust-side
//! query API. All host CRUD operations (list, get, create, update, delete)
//! should be performed from the frontend using @tauri-apps/plugin-sql directly.
//!
//! These Tauri commands are provided as stubs that return placeholder data.
//! The frontend will use the SQL plugin's JS API for actual database access.

use crate::db::models::{CreateHostInput, SshHost, UpdateHostInput};

/// List all SSH hosts. Frontend should use SQL plugin directly instead.
#[tauri::command]
pub async fn list_hosts() -> Result<Vec<SshHost>, String> {
    // Placeholder: actual CRUD is done from the JS frontend via @tauri-apps/plugin-sql
    Ok(vec![])
}

/// Get a single SSH host by ID. Frontend should use SQL plugin directly instead.
#[tauri::command]
pub async fn get_host(host_id: String) -> Result<Option<SshHost>, String> {
    let _ = host_id;
    // Placeholder: actual CRUD is done from the JS frontend via @tauri-apps/plugin-sql
    Ok(None)
}

/// Create a new SSH host. Frontend should use SQL plugin directly instead.
#[tauri::command]
pub async fn create_host(input: CreateHostInput) -> Result<SshHost, String> {
    let now = chrono::Utc::now().to_rfc3339();
    let id = uuid::Uuid::new_v4().to_string();
    Ok(SshHost {
        id,
        name: input.name,
        hostname: input.hostname,
        port: input.port.unwrap_or(22),
        username: input.username,
        auth_type: input.auth_type,
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Update an existing SSH host. Frontend should use SQL plugin directly instead.
#[tauri::command]
pub async fn update_host(input: UpdateHostInput) -> Result<Option<SshHost>, String> {
    let _ = input;
    // Placeholder: actual CRUD is done from the JS frontend via @tauri-apps/plugin-sql
    Ok(None)
}

/// Delete an SSH host by ID. Frontend should use SQL plugin directly instead.
#[tauri::command]
pub async fn delete_host(host_id: String) -> Result<(), String> {
    let _ = host_id;
    // Placeholder: actual CRUD is done from the JS frontend via @tauri-apps/plugin-sql
    Ok(())
}
