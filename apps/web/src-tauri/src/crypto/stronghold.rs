//! Stronghold credential storage wrapper.
//!
//! Note: The tauri-plugin-stronghold v2 Rust-side API for storing/retrieving
//! secrets is not well-documented. The pragmatic approach is to handle credential
//! operations from the frontend JavaScript side using @tauri-apps/plugin-stronghold,
//! and pass credentials to Rust SSH commands as parameters.
//!
//! This module provides helper functions that can be expanded once better
//! Rust-side documentation becomes available, or can serve as a thin wrapper
//! if needed in the future.

use tauri::AppHandle;

/// Build a location key string for storing SSH credentials.
/// Format: "ssh-credential:{host_id}"
pub fn credential_key(host_id: &str) -> String {
    format!("ssh-credential:{host_id}")
}

/// Build a location key string for storing SSH private keys.
/// Format: "ssh-key:{host_id}"
pub fn private_key_key(host_id: &str) -> String {
    format!("ssh-key:{host_id}")
}

/// Placeholder for saving a credential via Stronghold from Rust side.
/// Currently, credential operations should be done from the frontend using
/// the @tauri-apps/plugin-stronghold JS API.
pub fn save_credential(_app: &AppHandle, _key: &str, _value: &[u8]) -> Result<(), String> {
    // Stronghold Rust-side store/retrieve API is complex and poorly documented.
    // Use the JS-side API for now: Stronghold.load() -> client.getStore() -> store.insert()
    Ok(())
}

/// Placeholder for retrieving a credential via Stronghold from Rust side.
pub fn get_credential(_app: &AppHandle, _key: &str) -> Result<Vec<u8>, String> {
    Err("Credential retrieval should be done from JS side".to_string())
}

/// Placeholder for deleting a credential via Stronghold from Rust side.
pub fn delete_credential(_app: &AppHandle, _key: &str) -> Result<(), String> {
    Ok(())
}
