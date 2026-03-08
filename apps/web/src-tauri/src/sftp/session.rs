use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, Handle};
use russh_sftp::client::SftpSession;
use tauri::AppHandle;

use crate::ssh::handler::SshClientHandler;
use crate::ssh::session::AuthMethod;

/// Configuration needed to establish a standalone SFTP connection.
#[derive(Clone)]
pub struct SftpConnectConfig {
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
}

/// Represents an active SFTP session backed by an SSH connection.
#[allow(dead_code)]
pub struct SftpSessionEntry {
    /// Unique SFTP session identifier.
    pub id: String,
    /// The host ID this session is connected to.
    pub host_id: String,
    /// If this SFTP session reuses an existing SSH session, its ID.
    pub ssh_session_id: Option<String>,
    /// The SFTP session handle for file operations, wrapped in Arc for cloning.
    sftp: Arc<SftpSession>,
    /// The underlying SSH client handle (kept alive).
    _handle: Handle<SshClientHandler>,
    /// Handle to the Tauri application for emitting events.
    app_handle: AppHandle,
    /// Connection config stored for automatic reconnection.
    connect_config: SftpConnectConfig,
}

impl SftpSessionEntry {
    /// Establish an SSH connection, authenticate, and open an SFTP subsystem.
    async fn establish(
        config: &SftpConnectConfig,
    ) -> Result<(Handle<SshClientHandler>, Arc<SftpSession>), String> {
        let ssh_config = Arc::new(client::Config {
            inactivity_timeout: Some(Duration::from_secs(15)),
            ..Default::default()
        });
        let addr = format!("{}:{}", config.hostname, config.port);

        let mut handle = client::connect(ssh_config, &addr, SshClientHandler)
            .await
            .map_err(|e| format!("SFTP SSH connection failed: {e}"))?;

        let auth_ok = match &config.auth {
            AuthMethod::Password(password) => handle
                .authenticate_password(&config.username, password)
                .await
                .map_err(|e| format!("SFTP SSH authentication failed: {e}"))?,
            AuthMethod::PrivateKey { key, passphrase } => {
                let key_pair = russh_keys::decode_secret_key(key, passphrase.as_deref())
                    .map_err(|e| format!("Failed to decode private key: {e}"))?;
                handle
                    .authenticate_publickey(&config.username, Arc::new(key_pair))
                    .await
                    .map_err(|e| format!("SFTP SSH key authentication failed: {e}"))?
            }
        };

        if !auth_ok {
            return Err("SFTP SSH authentication rejected".to_string());
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Failed to open SFTP channel: {e}"))?;

        channel
            .request_subsystem(true, "sftp")
            .await
            .map_err(|e| format!("Failed to request SFTP subsystem: {e}"))?;

        let sftp = SftpSession::new(channel.into_stream())
            .await
            .map_err(|e| format!("Failed to create SFTP session: {e}"))?;

        Ok((handle, Arc::new(sftp)))
    }

    /// Open a standalone SFTP connection by creating a new SSH session,
    /// authenticating, opening a channel, and requesting the SFTP subsystem.
    pub async fn open_standalone(
        id: String,
        host_id: String,
        config: &SftpConnectConfig,
        app_handle: AppHandle,
    ) -> Result<Self, String> {
        let (handle, sftp) = Self::establish(config).await?;

        Ok(Self {
            id,
            host_id,
            ssh_session_id: None,
            sftp,
            _handle: handle,
            app_handle,
            connect_config: config.clone(),
        })
    }

    /// Reconnect this SFTP session by establishing a new SSH connection.
    pub async fn reconnect(&mut self) -> Result<(), String> {
        let (handle, sftp) = Self::establish(&self.connect_config).await?;
        self._handle = handle;
        self.sftp = sftp;
        Ok(())
    }

    /// Get a reference to the SFTP session for file operations.
    pub fn sftp(&self) -> &SftpSession {
        &self.sftp
    }

    /// Get a cloneable handle to the SFTP session.
    ///
    /// This allows callers to hold the SFTP session across await points
    /// without keeping the session manager locked.
    pub fn sftp_arc(&self) -> Arc<SftpSession> {
        Arc::clone(&self.sftp)
    }

    /// Get a reference to the Tauri app handle.
    pub fn app_handle(&self) -> &AppHandle {
        &self.app_handle
    }
}
