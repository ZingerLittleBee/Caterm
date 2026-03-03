use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use tauri::{AppHandle, State};

use crate::ssh::manager::SshSessionManager;
use crate::ssh::session::SshSession;

/// Connect to an SSH host. Returns the session ID on success.
///
/// Credentials (password or private key) are passed directly from the frontend
/// rather than being retrieved from Stronghold on the Rust side, since the
/// Stronghold JS API is better documented and more practical for this use case.
#[tauri::command]
pub async fn ssh_connect(
    app: AppHandle,
    manager: State<'_, SshSessionManager>,
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

    let session = match auth_type.as_str() {
        "password" => {
            let password = password.ok_or("Password is required for password authentication")?;
            SshSession::connect_with_password(
                session_id.clone(),
                host_id,
                &hostname,
                port,
                &username,
                &password,
                app,
            )
            .await?
        }
        "key" => {
            let key = private_key.ok_or("Private key is required for key authentication")?;
            SshSession::connect_with_key(
                session_id.clone(),
                host_id,
                &hostname,
                port,
                &username,
                &key,
                key_passphrase.as_deref(),
                app,
            )
            .await?
        }
        _ => return Err(format!("Unsupported auth type: {auth_type}")),
    };

    manager.add_session(session).await;
    Ok(session_id)
}

/// Write data to an SSH session. Data is base64-encoded from the frontend.
#[tauri::command]
pub async fn ssh_write(
    manager: State<'_, SshSessionManager>,
    session_id: String,
    data: String,
) -> Result<(), String> {
    let bytes = BASE64
        .decode(&data)
        .map_err(|e| format!("Invalid base64 data: {e}"))?;
    manager.write(&session_id, &bytes).await
}

/// Resize the terminal for an SSH session.
#[tauri::command]
pub async fn ssh_resize(
    manager: State<'_, SshSessionManager>,
    session_id: String,
    cols: u32,
    rows: u32,
) -> Result<(), String> {
    manager.resize(&session_id, cols, rows).await
}

/// Disconnect an SSH session.
#[tauri::command]
pub async fn ssh_disconnect(
    manager: State<'_, SshSessionManager>,
    session_id: String,
) -> Result<(), String> {
    manager.disconnect(&session_id).await
}
