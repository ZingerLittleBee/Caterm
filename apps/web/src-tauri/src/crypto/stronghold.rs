//! Stronghold credential storage key utilities.
//!
//! Credential operations (save, load, delete) are handled from the frontend
//! using the @tauri-apps/plugin-stronghold JS API. This module provides
//! key-naming conventions shared between backend and frontend.

/// Build a location key string for storing SSH passwords.
/// Format: "ssh-password:{host_id}"
#[allow(dead_code)]
pub fn password_key(host_id: &str) -> String {
    format!("ssh-password-{host_id}")
}

/// Build a location key string for storing SSH private keys.
/// Format: "ssh-private-key:{host_id}"
#[allow(dead_code)]
pub fn private_key_key(host_id: &str) -> String {
    format!("ssh-private-key-{host_id}")
}

/// Build a location key string for storing SSH key passphrases.
/// Format: "ssh-key-passphrase:{host_id}"
#[allow(dead_code)]
pub fn passphrase_key(host_id: &str) -> String {
    format!("ssh-key-passphrase-{host_id}")
}
