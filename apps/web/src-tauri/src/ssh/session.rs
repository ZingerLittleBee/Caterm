use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use russh::client::{self, Handle, Msg};
use russh::Channel;
use russh::ChannelMsg;
use tauri::{AppHandle, Emitter};
use tokio::sync::{Mutex, mpsc, oneshot};

use super::handler::SshClientHandler;

/// Commands sent from write/resize/close to the reader task
/// that exclusively owns the SSH channel.
pub(crate) enum ChannelCommand {
    Data {
        data: Vec<u8>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Resize {
        cols: u32,
        rows: u32,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Close {
        reply: oneshot::Sender<Result<(), String>>,
    },
}

/// Represents an active SSH session with a remote host.
#[allow(dead_code)]
pub struct SshSession {
    /// Unique session identifier.
    pub id: String,
    /// The host ID this session is connected to.
    pub host_id: String,
    /// Sender for dispatching commands to the reader task that owns the channel.
    command_tx: mpsc::Sender<ChannelCommand>,
    /// The SSH channel and command receiver, held until `spawn_reader` takes them.
    /// Once the reader is spawned, this becomes `None`.
    pending_reader: Mutex<Option<(Channel<Msg>, mpsc::Receiver<ChannelCommand>)>>,
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

        let (command_tx, command_rx) = mpsc::channel(32);

        Ok(Self {
            id,
            host_id,
            command_tx,
            pending_reader: Mutex::new(Some((channel, command_rx))),
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

        let (command_tx, command_rx) = mpsc::channel(32);

        Ok(Self {
            id,
            host_id,
            command_tx,
            pending_reader: Mutex::new(Some((channel, command_rx))),
            _handle: handle,
            app_handle,
        })
    }

    /// Clone the command sender so callers can send commands without holding
    /// a long-lived borrow on the session (e.g. across await points).
    pub fn command_sender(&self) -> mpsc::Sender<ChannelCommand> {
        self.command_tx.clone()
    }

    /// Write data to the SSH channel.
    #[allow(dead_code)]
    pub async fn write(&self, data: &[u8]) -> Result<(), String> {
        Self::write_with(self.command_tx.clone(), data).await
    }

    /// Write data using a pre-cloned command sender.
    /// This avoids holding a Mutex across the await.
    pub async fn write_with(
        tx: mpsc::Sender<ChannelCommand>,
        data: &[u8],
    ) -> Result<(), String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        tx.send(ChannelCommand::Data {
            data: data.to_vec(),
            reply: reply_tx,
        })
        .await
        .map_err(|_| "SSH channel task has stopped".to_string())?;
        reply_rx
            .await
            .map_err(|_| "SSH channel task dropped the reply".to_string())?
    }

    /// Resize the remote terminal.
    #[allow(dead_code)]
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), String> {
        Self::resize_with(self.command_tx.clone(), cols, rows).await
    }

    /// Resize using a pre-cloned command sender.
    /// This avoids holding a Mutex across the await.
    pub async fn resize_with(
        tx: mpsc::Sender<ChannelCommand>,
        cols: u32,
        rows: u32,
    ) -> Result<(), String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        tx.send(ChannelCommand::Resize {
            cols,
            rows,
            reply: reply_tx,
        })
        .await
        .map_err(|_| "SSH channel task has stopped".to_string())?;
        reply_rx
            .await
            .map_err(|_| "SSH channel task dropped the reply".to_string())?
    }

    /// Close the SSH channel.
    pub async fn close(&self) -> Result<(), String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(ChannelCommand::Close { reply: reply_tx })
            .await
            .map_err(|_| "SSH channel task has stopped".to_string())?;
        reply_rx
            .await
            .map_err(|_| "SSH channel task dropped the reply".to_string())?
    }

    /// Spawn a background task that reads SSH output and emits Tauri events.
    ///
    /// The reader task takes exclusive ownership of the SSH channel, preventing
    /// deadlocks. Write, resize, and close operations are dispatched to this task
    /// via an internal command channel.
    ///
    /// Emits:
    /// - `ssh-output-{session_id}` with base64-encoded data for each data message.
    /// - `ssh-disconnect-{session_id}` when the channel closes or reaches EOF.
    pub fn spawn_reader(&self) {
        // Take the channel and command receiver out of the pending slot.
        // This uses try_lock because spawn_reader is not async; the lock is
        // uncontended at this point since it is called right after construction.
        let Some((channel, command_rx)) = self
            .pending_reader
            .try_lock()
            .expect("pending_reader lock should be uncontended during spawn_reader")
            .take()
        else {
            // Reader was already spawned.
            return;
        };

        let app_handle = self.app_handle.clone();
        let session_id = self.id.clone();
        let output_event = format!("ssh-output-{}", self.id);
        let disconnect_event = format!("ssh-disconnect-{}", self.id);

        tokio::spawn(async move {
            Self::reader_loop(
                channel,
                command_rx,
                app_handle,
                session_id,
                output_event,
                disconnect_event,
            )
            .await;
        });
    }

    /// The reader loop that exclusively owns the SSH channel.
    ///
    /// Uses `tokio::select!` to concurrently handle:
    /// - Incoming SSH data from `channel.wait()`
    /// - Outgoing commands (write, resize, close) from the mpsc receiver
    async fn reader_loop(
        mut channel: Channel<Msg>,
        mut command_rx: mpsc::Receiver<ChannelCommand>,
        app_handle: AppHandle,
        session_id: String,
        output_event: String,
        disconnect_event: String,
    ) {
        loop {
            tokio::select! {
                msg = channel.wait() => {
                    match msg {
                        Some(ChannelMsg::Data { data }) => {
                            let encoded = BASE64.encode(&data);
                            let _ = app_handle.emit(&output_event, encoded);
                        }
                        Some(ChannelMsg::ExtendedData { data, .. }) => {
                            let encoded = BASE64.encode(&data);
                            let _ = app_handle.emit(&output_event, encoded);
                        }
                        Some(ChannelMsg::Eof | ChannelMsg::Close) => {
                            let _ = app_handle.emit(&disconnect_event, &session_id);
                            break;
                        }
                        Some(_) => {
                            // Ignore other channel messages.
                        }
                        None => {
                            // Channel closed.
                            let _ = app_handle.emit(&disconnect_event, &session_id);
                            break;
                        }
                    }
                }
                cmd = command_rx.recv() => {
                    match cmd {
                        Some(ChannelCommand::Data { data, reply }) => {
                            let result = channel
                                .data(&data[..])
                                .await
                                .map_err(|e| format!("Failed to write to SSH channel: {e}"));
                            let _ = reply.send(result);
                        }
                        Some(ChannelCommand::Resize { cols, rows, reply }) => {
                            let result = channel
                                .window_change(cols, rows, 0, 0)
                                .await
                                .map_err(|e| format!("Failed to resize terminal: {e}"));
                            let _ = reply.send(result);
                        }
                        Some(ChannelCommand::Close { reply }) => {
                            let result = channel
                                .close()
                                .await
                                .map_err(|e| format!("Failed to close SSH channel: {e}"));
                            let _ = reply.send(result);
                            break;
                        }
                        None => {
                            // All command senders dropped; session is being torn down.
                            let _ = channel.close().await;
                            let _ = app_handle.emit(&disconnect_event, &session_id);
                            break;
                        }
                    }
                }
            }
        }
    }
}
