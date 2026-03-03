use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use russh::client::{self, Handle, Msg};
use russh::Channel;
use russh::ChannelMsg;
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex;

use super::handler::SshClientHandler;

/// Represents an active SSH session with a remote host.
#[allow(dead_code)]
pub struct SshSession {
    /// Unique session identifier.
    pub id: String,
    /// The host ID this session is connected to.
    pub host_id: String,
    /// The SSH channel for reading/writing.
    channel: Arc<Mutex<Channel<Msg>>>,
    /// The SSH client handle for the connection.
    _handle: Handle<SshClientHandler>,
    /// Handle to the Tauri application for emitting events.
    app_handle: AppHandle,
}

impl SshSession {
    /// Connect to an SSH host using password authentication.
    pub async fn connect_with_password(
        id: String,
        host_id: String,
        hostname: &str,
        port: u16,
        username: &str,
        password: &str,
        app_handle: AppHandle,
    ) -> Result<Self, String> {
        let config = Arc::new(client::Config::default());
        let addr = format!("{hostname}:{port}");

        let mut handle = client::connect(config, &addr, SshClientHandler)
            .await
            .map_err(|e| format!("SSH connection failed: {e}"))?;

        let auth_ok = handle
            .authenticate_password(username, password)
            .await
            .map_err(|e| format!("SSH authentication failed: {e}"))?;

        if !auth_ok {
            return Err("SSH password authentication rejected".to_string());
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Failed to open SSH channel: {e}"))?;

        // Request a PTY with default terminal settings.
        channel
            .request_pty(true, "xterm-256color", 80, 24, 0, 0, &[])
            .await
            .map_err(|e| format!("Failed to request PTY: {e}"))?;

        // Request an interactive shell.
        channel
            .request_shell(true)
            .await
            .map_err(|e| format!("Failed to request shell: {e}"))?;

        Ok(Self {
            id,
            host_id,
            channel: Arc::new(Mutex::new(channel)),
            _handle: handle,
            app_handle,
        })
    }

    /// Connect to an SSH host using private key authentication.
    pub async fn connect_with_key(
        id: String,
        host_id: String,
        hostname: &str,
        port: u16,
        username: &str,
        private_key_pem: &str,
        passphrase: Option<&str>,
        app_handle: AppHandle,
    ) -> Result<Self, String> {
        let config = Arc::new(client::Config::default());
        let addr = format!("{hostname}:{port}");

        let mut handle = client::connect(config, &addr, SshClientHandler)
            .await
            .map_err(|e| format!("SSH connection failed: {e}"))?;

        let key_pair = russh_keys::decode_secret_key(private_key_pem, passphrase)
            .map_err(|e| format!("Failed to decode private key: {e}"))?;

        let auth_ok = handle
            .authenticate_publickey(username, Arc::new(key_pair))
            .await
            .map_err(|e| format!("SSH key authentication failed: {e}"))?;

        if !auth_ok {
            return Err("SSH key authentication rejected".to_string());
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Failed to open SSH channel: {e}"))?;

        channel
            .request_pty(true, "xterm-256color", 80, 24, 0, 0, &[])
            .await
            .map_err(|e| format!("Failed to request PTY: {e}"))?;

        channel
            .request_shell(true)
            .await
            .map_err(|e| format!("Failed to request shell: {e}"))?;

        Ok(Self {
            id,
            host_id,
            channel: Arc::new(Mutex::new(channel)),
            _handle: handle,
            app_handle,
        })
    }

    /// Write data to the SSH channel.
    pub async fn write(&self, data: &[u8]) -> Result<(), String> {
        let channel = self.channel.lock().await;
        channel
            .data(data)
            .await
            .map_err(|e| format!("Failed to write to SSH channel: {e}"))
    }

    /// Resize the remote terminal.
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), String> {
        let channel = self.channel.lock().await;
        channel
            .window_change(cols, rows, 0, 0)
            .await
            .map_err(|e| format!("Failed to resize terminal: {e}"))
    }

    /// Close the SSH channel.
    pub async fn close(&self) -> Result<(), String> {
        let channel = self.channel.lock().await;
        channel
            .close()
            .await
            .map_err(|e| format!("Failed to close SSH channel: {e}"))
    }

    /// Spawn a background task that reads SSH output and emits Tauri events.
    ///
    /// Emits:
    /// - `ssh-output-{session_id}` with base64-encoded data for each data message.
    /// - `ssh-disconnect-{session_id}` when the channel closes or reaches EOF.
    pub fn spawn_reader(&self) {
        let channel = self.channel.clone();
        let app_handle = self.app_handle.clone();
        let session_id = self.id.clone();
        let output_event = format!("ssh-output-{}", self.id);
        let disconnect_event = format!("ssh-disconnect-{}", self.id);

        tokio::spawn(async move {
            let mut ch = channel.lock().await;
            loop {
                match ch.wait().await {
                    Some(ChannelMsg::Data { data }) => {
                        let encoded = BASE64.encode(&data);
                        let _ = app_handle.emit(&output_event, encoded);
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        let encoded = BASE64.encode(&data);
                        let _ = app_handle.emit(&output_event, encoded);
                    }
                    Some(ChannelMsg::Eof | ChannelMsg::Close) => {
                        let _ = app_handle.emit(&disconnect_event, session_id);
                        break;
                    }
                    Some(_) => {
                        // Ignore other channel messages.
                    }
                    None => {
                        // Channel closed.
                        let _ = app_handle.emit(&disconnect_event, session_id);
                        break;
                    }
                }
            }
        });
    }
}
