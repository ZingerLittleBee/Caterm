use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use russh::client::{self, Handle, Msg};
use russh::Channel;
use russh::ChannelMsg;
use tauri::{AppHandle, Emitter};
use tokio::sync::{Mutex, mpsc, oneshot};

use super::handler::SshClientHandler;

/// Authentication method for reconnection.
#[derive(Clone)]
pub(crate) enum AuthMethod {
    Password(String),
    PrivateKey {
        key: String,
        passphrase: Option<String>,
    },
}

/// Stores connection parameters needed for automatic reconnection.
#[derive(Clone)]
pub(crate) struct ReconnectConfig {
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
}

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
    Retry {
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
    /// Connection parameters for automatic reconnection.
    reconnect_config: ReconnectConfig,
}

impl SshSession {
    /// Establish an SSH connection, authenticate, open a channel with PTY and shell.
    /// Returns the client handle and the opened channel.
    async fn establish_connection(
        config: &ReconnectConfig,
        cols: u32,
        rows: u32,
    ) -> Result<(Handle<SshClientHandler>, Channel<Msg>), String> {
        let ssh_config = Arc::new(client::Config::default());
        let addr = format!("{}:{}", config.hostname, config.port);

        let mut handle = client::connect(ssh_config, &addr, SshClientHandler)
            .await
            .map_err(|e| format!("SSH connection failed: {e}"))?;

        let auth_ok = match &config.auth {
            AuthMethod::Password(password) => handle
                .authenticate_password(&config.username, password)
                .await
                .map_err(|e| format!("SSH authentication failed: {e}"))?,
            AuthMethod::PrivateKey { key, passphrase } => {
                let key_pair = russh_keys::decode_secret_key(key, passphrase.as_deref())
                    .map_err(|e| format!("Failed to decode private key: {e}"))?;
                handle
                    .authenticate_publickey(&config.username, Arc::new(key_pair))
                    .await
                    .map_err(|e| format!("SSH key authentication failed: {e}"))?
            }
        };

        if !auth_ok {
            return Err("SSH authentication rejected".to_string());
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| format!("Failed to open SSH channel: {e}"))?;

        channel
            .request_pty(true, "xterm-256color", cols, rows, 0, 0, &[])
            .await
            .map_err(|e| format!("Failed to request PTY: {e}"))?;

        channel
            .request_shell(true)
            .await
            .map_err(|e| format!("Failed to request shell: {e}"))?;

        Ok((handle, channel))
    }

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
        let reconnect_config = ReconnectConfig {
            hostname: hostname.to_string(),
            port,
            username: username.to_string(),
            auth: AuthMethod::Password(password.to_string()),
        };

        let (handle, channel) =
            Self::establish_connection(&reconnect_config, 80, 24).await?;

        let (command_tx, command_rx) = mpsc::channel(32);

        Ok(Self {
            id,
            host_id,
            command_tx,
            pending_reader: Mutex::new(Some((channel, command_rx))),
            _handle: handle,
            app_handle,
            reconnect_config,
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
        let reconnect_config = ReconnectConfig {
            hostname: hostname.to_string(),
            port,
            username: username.to_string(),
            auth: AuthMethod::PrivateKey {
                key: private_key_pem.to_string(),
                passphrase: passphrase.map(String::from),
            },
        };

        let (handle, channel) =
            Self::establish_connection(&reconnect_config, 80, 24).await?;

        let (command_tx, command_rx) = mpsc::channel(32);

        Ok(Self {
            id,
            host_id,
            command_tx,
            pending_reader: Mutex::new(Some((channel, command_rx))),
            _handle: handle,
            app_handle,
            reconnect_config,
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

    /// Send a retry command to restart the reconnect loop.
    #[allow(dead_code)]
    pub async fn retry(&self) -> Result<(), String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(ChannelCommand::Retry { reply: reply_tx })
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
    /// - `ssh-reconnecting-{session_id}` when a reconnect attempt starts.
    /// - `ssh-reconnected-{session_id}` when reconnection succeeds.
    /// - `ssh-disconnect-{session_id}` when the channel closes or reconnection fails.
    pub fn spawn_reader(&self) {
        let Some((channel, command_rx)) = self
            .pending_reader
            .try_lock()
            .expect("pending_reader lock should be uncontended during spawn_reader")
            .take()
        else {
            return;
        };

        let app_handle = self.app_handle.clone();
        let session_id = self.id.clone();
        let reconnect_config = self.reconnect_config.clone();

        tokio::spawn(async move {
            Self::reader_loop(
                channel,
                command_rx,
                app_handle,
                session_id,
                reconnect_config,
            )
            .await;
        });
    }

    const MAX_RECONNECT_ATTEMPTS: u32 = 5;
    const INITIAL_RECONNECT_DELAY_MS: u64 = 1000;
    const MAX_RECONNECT_DELAY_MS: u64 = 30000;
    const MAX_INPUT_BUFFER_BYTES: usize = 1_048_576; // 1 MB

    /// The reader loop that exclusively owns the SSH channel.
    ///
    /// Implements a state machine with two states:
    /// - **Connected**: normal read/write loop processing SSH data and commands.
    /// - **Reconnecting**: attempts to re-establish the SSH connection with
    ///   exponential backoff, buffering user input in the meantime.
    async fn reader_loop(
        mut channel: Channel<Msg>,
        mut command_rx: mpsc::Receiver<ChannelCommand>,
        app_handle: AppHandle,
        session_id: String,
        reconnect_config: ReconnectConfig,
    ) {
        let output_event = format!("ssh-output-{}", session_id);
        let reconnecting_event = format!("ssh-reconnecting-{}", session_id);
        let reconnected_event = format!("ssh-reconnected-{}", session_id);
        let disconnect_event = format!("ssh-disconnect-{}", session_id);

        // Track last known terminal size for PTY on reconnect.
        let mut last_cols: u32 = 80;
        let mut last_rows: u32 = 24;

        // Keep the active SSH handle alive for the duration of the connection.
        let mut _active_handle: Option<Handle<SshClientHandler>> = None;

        'outer: loop {
            // === CONNECTED STATE: normal read/write loop ===
            let needs_reconnect = loop {
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
                                // Server closed normally — no reconnect.
                                break false;
                            }
                            Some(_) => {}
                            None => {
                                // TCP drop / unexpected disconnect — reconnect.
                                break true;
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
                                last_cols = cols;
                                last_rows = rows;
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
                                break false; // User-initiated close — no reconnect.
                            }
                            Some(ChannelCommand::Retry { reply }) => {
                                // Retry only meaningful after failed reconnect.
                                let _ = reply.send(Ok(()));
                            }
                            None => {
                                let _ = channel.close().await;
                                break false; // All senders dropped — no reconnect.
                            }
                        }
                    }
                }
            };

            if !needs_reconnect {
                let _ = app_handle.emit(
                    &disconnect_event,
                    serde_json::json!({ "reason": "user" }),
                );
                break 'outer;
            }

            // === RECONNECTING STATE ===
            let mut input_buffer: Vec<Vec<u8>> = Vec::new();
            let mut pending_resize: Option<(u32, u32)> = None;
            'reconnect: loop {
                let mut delay_ms = Self::INITIAL_RECONNECT_DELAY_MS;

                for attempt in 1..=Self::MAX_RECONNECT_ATTEMPTS {
                    let next_delay_ms = (delay_ms * 2).min(Self::MAX_RECONNECT_DELAY_MS);
                    let _ = app_handle.emit(
                        &reconnecting_event,
                        serde_json::json!({
                            "attempt": attempt,
                            "maxAttempts": Self::MAX_RECONNECT_ATTEMPTS,
                            "nextDelayMs": next_delay_ms,
                        }),
                    );

                    match Self::establish_connection(
                        &reconnect_config,
                        pending_resize.map_or(last_cols, |(c, _)| c),
                        pending_resize.map_or(last_rows, |(_, r)| r),
                    )
                    .await
                    {
                        Ok((handle, new_channel)) => {
                            _active_handle = Some(handle);
                            channel = new_channel;

                            // Flush buffered input.
                            for data in input_buffer.drain(..) {
                                if channel.data(&data[..]).await.is_err() {
                                    break;
                                }
                            }

                            // Apply pending resize.
                            if let Some((cols, rows)) = pending_resize.take() {
                                last_cols = cols;
                                last_rows = rows;
                                let _ = channel.window_change(cols, rows, 0, 0).await;
                            }

                            let _ = app_handle.emit(&reconnected_event, serde_json::json!({}));
                            break 'reconnect;
                        }
                        Err(_) => {
                            // Wait for delay while draining commands.
                            let deadline =
                                tokio::time::Instant::now() + tokio::time::Duration::from_millis(delay_ms);
                            loop {
                                tokio::select! {
                                    _ = tokio::time::sleep_until(deadline) => {
                                        break;
                                    }
                                    cmd = command_rx.recv() => {
                                        match cmd {
                                            Some(ChannelCommand::Data { data, reply }) => {
                                                let total: usize = input_buffer.iter().map(|d| d.len()).sum();
                                                if total + data.len() <= Self::MAX_INPUT_BUFFER_BYTES {
                                                    input_buffer.push(data);
                                                    let _ = reply.send(Ok(()));
                                                } else {
                                                    let _ = reply.send(Err("Input buffer full during reconnection".to_string()));
                                                }
                                            }
                                            Some(ChannelCommand::Resize { cols, rows, reply }) => {
                                                pending_resize = Some((cols, rows));
                                                let _ = reply.send(Ok(()));
                                            }
                                            Some(ChannelCommand::Close { reply }) => {
                                                let _ = reply.send(Ok(()));
                                                let _ = app_handle.emit(
                                                    &disconnect_event,
                                                    serde_json::json!({ "reason": "user" }),
                                                );
                                                break 'outer;
                                            }
                                            Some(ChannelCommand::Retry { reply }) => {
                                                let _ = reply.send(Ok(()));
                                            }
                                            None => {
                                                break 'outer;
                                            }
                                        }
                                    }
                                }
                            }
                            delay_ms = next_delay_ms;
                        }
                    }
                }

                // All automatic attempts exhausted — wait for Retry or Close.
                let _ = app_handle.emit(
                    &disconnect_event,
                    serde_json::json!({ "reason": "failed" }),
                );

                loop {
                    match command_rx.recv().await {
                        Some(ChannelCommand::Retry { reply }) => {
                            let _ = reply.send(Ok(()));
                            continue 'reconnect; // Restart reconnect attempts.
                        }
                        Some(ChannelCommand::Close { reply }) => {
                            let _ = reply.send(Ok(()));
                            break 'outer;
                        }
                        Some(ChannelCommand::Data { data, reply }) => {
                            input_buffer.push(data);
                            let _ = reply.send(Ok(()));
                        }
                        Some(ChannelCommand::Resize { cols, rows, reply }) => {
                            pending_resize = Some((cols, rows));
                            let _ = reply.send(Ok(()));
                        }
                        None => {
                            break 'outer;
                        }
                    }
                }
            }

            // Loop back to 'outer to resume normal read/write.
        }
    }
}
