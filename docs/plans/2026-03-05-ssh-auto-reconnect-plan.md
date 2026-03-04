# SSH Auto-Reconnect Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add backend-driven SSH auto-reconnect with input buffering, exponential backoff, and seamless terminal UX.

**Architecture:** The Rust reader loop detects unexpected disconnects (channel returns `None`), buffers user input, and retries connection using stored credentials. The frontend receives events and shows inline ANSI status messages in xterm. Same `sessionId` is reused throughout.

**Tech Stack:** Rust (russh, tokio, tauri), TypeScript (React, xterm.js, Tauri IPC)

---

### Task 1: Add ReconnectConfig types and Retry command variant

**Files:**
- Modify: `apps/web/src-tauri/src/ssh/session.rs:1-28`

**Step 1: Add AuthMethod enum, ReconnectConfig struct, and Retry variant**

Add after the existing `use` statements (line 11) and before the `ChannelCommand` enum (line 13):

```rust
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
```

Add a `Retry` variant to the `ChannelCommand` enum (after `Close`):

```rust
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
```

**Step 2: Add reconnect_config field to SshSession**

Update the `SshSession` struct to store the reconnect config and last known terminal size:

```rust
pub struct SshSession {
    pub id: String,
    pub host_id: String,
    command_tx: mpsc::Sender<ChannelCommand>,
    pending_reader: Mutex<Option<(Channel<Msg>, mpsc::Receiver<ChannelCommand>)>>,
    _handle: Handle<SshClientHandler>,
    app_handle: AppHandle,
    reconnect_config: ReconnectConfig,
}
```

**Step 3: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check 2>&1 | head -20`
Expected: Compilation errors about `reconnect_config` not being set in constructors (will fix in Task 2)

**Step 4: Commit**

```bash
git add apps/web/src-tauri/src/ssh/session.rs
git commit -m "feat(ssh): add ReconnectConfig types and Retry command variant"
```

---

### Task 2: Refactor connection into reusable function and store ReconnectConfig

**Files:**
- Modify: `apps/web/src-tauri/src/ssh/session.rs:48-159`

**Step 1: Extract shared connection logic into `establish_connection`**

Add a private helper method that handles TCP connect + auth + channel + PTY + shell. This will be called by both `connect_with_password`/`connect_with_key` and the reconnect loop.

Add this method to `impl SshSession` before `connect_with_password`:

```rust
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
```

**Step 2: Rewrite `connect_with_password` to use `establish_connection`**

```rust
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
```

**Step 3: Rewrite `connect_with_key` to use `establish_connection`**

```rust
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
```

**Step 4: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check 2>&1 | head -20`
Expected: Warnings about unused `Retry` variant, but no errors

**Step 5: Commit**

```bash
git add apps/web/src-tauri/src/ssh/session.rs
git commit -m "refactor(ssh): extract establish_connection and store ReconnectConfig"
```

---

### Task 3: Implement reconnect logic in reader_loop

**Files:**
- Modify: `apps/web/src-tauri/src/ssh/session.rs:229-344`

This is the most complex task. The reader_loop needs to become a state machine that handles reconnection.

**Step 1: Add serde dependency for event payloads**

Check `Cargo.toml` for serde. Add `serde` with `derive` feature if not present:

Run: `cd apps/web/src-tauri && grep serde Cargo.toml`

If serde is already there (likely via tauri), add `#[derive(serde::Serialize)]` to event payload structs.

**Step 2: Update `spawn_reader` to pass `ReconnectConfig`**

Replace the current `spawn_reader` method:

```rust
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
```

**Step 3: Rewrite `reader_loop` with reconnect support**

Replace the entire `reader_loop` method with the new implementation:

```rust
const MAX_RECONNECT_ATTEMPTS: u32 = 5;
const INITIAL_RECONNECT_DELAY_MS: u64 = 1000;
const MAX_RECONNECT_DELAY_MS: u64 = 30000;

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
        let mut reconnected = false;

        'reconnect: loop {
            let mut delay_ms = INITIAL_RECONNECT_DELAY_MS;

            for attempt in 1..=MAX_RECONNECT_ATTEMPTS {
                let next_delay_ms = (delay_ms * 2).min(MAX_RECONNECT_DELAY_MS);
                let _ = app_handle.emit(
                    &reconnecting_event,
                    serde_json::json!({
                        "attempt": attempt,
                        "maxAttempts": MAX_RECONNECT_ATTEMPTS,
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
                    Ok((_handle, new_channel)) => {
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
                        reconnected = true;
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
                                            input_buffer.push(data);
                                            let _ = reply.send(Ok(()));
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

        if !reconnected {
            break 'outer;
        }
        // Loop back to 'outer to resume normal read/write.
    }
}
```

**Step 4: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check 2>&1 | head -20`
Expected: Clean compile (possibly warnings about unused `_handle` in reconnect — that's fine, the handle needs to stay alive)

**Step 5: Commit**

```bash
git add apps/web/src-tauri/src/ssh/session.rs
git commit -m "feat(ssh): implement auto-reconnect with backoff and input buffering in reader_loop"
```

---

### Task 4: Add ssh_retry command and manager method

**Files:**
- Modify: `apps/web/src-tauri/src/ssh/session.rs` (add `retry` method)
- Modify: `apps/web/src-tauri/src/ssh/manager.rs` (add `retry` method)
- Modify: `apps/web/src-tauri/src/commands/ssh_commands.rs` (add `ssh_retry` command)
- Modify: `apps/web/src-tauri/src/lib.rs:32-37` (register command)

**Step 1: Add `retry` method to `SshSession`**

Add after the `close` method in `session.rs`:

```rust
/// Send a retry command to restart the reconnect loop.
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
```

**Step 2: Add `retry` method to `SshSessionManager`**

Add after the `disconnect` method in `manager.rs`:

```rust
/// Retry reconnection for a specific session.
pub async fn retry(&self, session_id: &str) -> Result<(), String> {
    let tx = {
        let sessions = self.sessions.lock().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| format!("Session not found: {session_id}"))?;
        session.command_sender()
    };
    let (reply_tx, reply_rx) = oneshot::channel();
    tx.send(ChannelCommand::Retry { reply: reply_tx })
        .await
        .map_err(|_| "SSH channel task has stopped".to_string())?;
    reply_rx
        .await
        .map_err(|_| "SSH channel task dropped the reply".to_string())?
}
```

Note: `manager.rs` will need to import `ChannelCommand` and `oneshot`:

```rust
use tokio::sync::{Mutex, oneshot};
use super::session::{SshSession, ChannelCommand};
```

**Step 3: Add `ssh_retry` tauri command**

Add to `ssh_commands.rs`:

```rust
/// Retry reconnection for a disconnected SSH session.
#[tauri::command]
pub async fn ssh_retry(
    manager: State<'_, SshSessionManager>,
    session_id: String,
) -> Result<(), String> {
    manager.retry(&session_id).await
}
```

**Step 4: Register the command in lib.rs**

Update the `invoke_handler` in `lib.rs` to include `ssh_retry`:

```rust
.invoke_handler(tauri::generate_handler![
    ssh_commands::ssh_connect,
    ssh_commands::ssh_write,
    ssh_commands::ssh_resize,
    ssh_commands::ssh_disconnect,
    ssh_commands::ssh_retry,
])
```

**Step 5: Verify it compiles**

Run: `cd apps/web/src-tauri && cargo check 2>&1 | head -20`
Expected: Clean compile

**Step 6: Commit**

```bash
git add apps/web/src-tauri/src/ssh/session.rs apps/web/src-tauri/src/ssh/manager.rs apps/web/src-tauri/src/commands/ssh_commands.rs apps/web/src-tauri/src/lib.rs
git commit -m "feat(ssh): add ssh_retry command for manual reconnection"
```

---

### Task 5: Update frontend types

**Files:**
- Modify: `apps/web/src/types/ssh.ts:29-33`

**Step 1: Add "reconnecting" to SshSessionStatus**

```typescript
export type SshSessionStatus =
	| "connecting"
	| "connected"
	| "reconnecting"
	| "disconnected"
	| "error";
```

**Step 2: Verify frontend compiles**

Run: `cd apps/web && bun run build 2>&1 | tail -10`
Expected: Clean build (the new status value is additive)

**Step 3: Commit**

```bash
git add apps/web/src/types/ssh.ts
git commit -m "feat(ssh): add reconnecting status type"
```

---

### Task 6: Update ssh-session-provider to handle reconnect events

**Files:**
- Modify: `apps/web/src/components/ssh/ssh-session-provider.tsx:103-150`

**Step 1: Update the `connect` callback to listen for reconnecting/reconnected events**

Replace the disconnect listener setup inside `connect()` (lines 127-137) with listeners for all three event types:

```typescript
const connect = useCallback(
    async (params: ConnectParams): Promise<string> => {
        const sessionInfo: SshSessionInfo = {
            id: "",
            hostId: params.hostId,
            hostName: params.hostName,
            status: "connecting",
        };

        const sessionId = await invoke<string>("ssh_connect", {
            hostId: params.hostId,
            hostname: params.hostname,
            port: params.port ?? 22,
            username: params.username,
            authType: params.authType,
            password: params.password,
            privateKey: params.privateKey,
            keyPassphrase: params.keyPassphrase,
        });

        sessionInfo.id = sessionId;
        sessionInfo.status = "connected";

        // Listen for reconnecting events.
        const unlistenReconnecting = await listen(
            `ssh-reconnecting-${sessionId}`,
            () => {
                updateSessionStatus(sessionId, "reconnecting");
            }
        );

        // Listen for reconnected events.
        const unlistenReconnected = await listen(
            `ssh-reconnected-${sessionId}`,
            () => {
                updateSessionStatus(sessionId, "connected");
            }
        );

        // Listen for disconnect events.
        const unlistenDisconnect = await listen(
            `ssh-disconnect-${sessionId}`,
            () => {
                updateSessionStatus(sessionId, "disconnected");
            }
        );

        // Store a combined unlisten function.
        const unlisten = () => {
            unlistenReconnecting();
            unlistenReconnected();
            unlistenDisconnect();
        };
        unlistenMap.current.set(sessionId, unlisten);

        setSessions((prev) => {
            const next = new Map(prev);
            next.set(sessionId, sessionInfo);
            return next;
        });

        setActiveSessionId(sessionId);

        return sessionId;
    },
    [updateSessionStatus]
);
```

Note: The old disconnect listener was self-cleaning (removed itself on disconnect). The new version keeps all listeners alive because reconnect can happen multiple times. They are cleaned up by `removeSession` or the unmount effect.

**Step 2: Verify frontend compiles**

Run: `cd apps/web && bun run build 2>&1 | tail -10`
Expected: Clean build

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/ssh-session-provider.tsx
git commit -m "feat(ssh): listen for reconnecting/reconnected events in session provider"
```

---

### Task 7: Update ssh-terminal for inline reconnect feedback and manual retry

**Files:**
- Modify: `apps/web/src/components/ssh/ssh-terminal.tsx:134-143`

**Step 1: Replace the disconnect listener with reconnecting/reconnected/disconnect listeners**

Replace the disconnect listener section (lines 134-143) with:

```typescript
// Listen for reconnecting events — show inline status.
let reconnectingUnlisten: (() => void) | null = null;
const reconnectingListenerPromise = listen<string>(
    `ssh-reconnecting-${sessionId}`,
    (event) => {
        const payload = JSON.parse(event.payload as unknown as string || "{}");
        const attempt = payload.attempt ?? "?";
        const max = payload.maxAttempts ?? "?";
        terminal.write(
            `\r\n\x1b[33mConnection lost. Reconnecting (${attempt}/${max})...\x1b[0m`
        );
    }
).then((unlisten) => {
    reconnectingUnlisten = unlisten;
});

// Listen for reconnected events — confirm success.
let reconnectedUnlisten: (() => void) | null = null;
const reconnectedListenerPromise = listen(
    `ssh-reconnected-${sessionId}`,
    () => {
        terminal.write("\r\n\x1b[32mReconnected.\x1b[0m\r\n");
    }
).then((unlisten) => {
    reconnectedUnlisten = unlisten;
});

// Listen for disconnect events — show failure or normal disconnect.
let disconnectUnlisten: (() => void) | null = null;
const disconnectListenerPromise = listen<string>(
    `ssh-disconnect-${sessionId}`,
    (event) => {
        let reason = "user";
        try {
            const payload = JSON.parse(event.payload as unknown as string || "{}");
            reason = payload.reason ?? "user";
        } catch {
            // Fallback to default
        }
        if (reason === "failed") {
            terminal.write(
                "\r\n\x1b[31mReconnection failed.\x1b[0m\r\n\x1b[31mPress Enter to retry or close this tab.\x1b[0m\r\n"
            );
        } else {
            terminal.write("\r\n\x1b[31mDisconnected.\x1b[0m\r\n");
        }
    }
).then((unlisten) => {
    disconnectUnlisten = unlisten;
});
```

**Step 2: Update the cleanup function**

Update the cleanup return (around line 156) to remove the new listeners:

```typescript
return () => {
    window.removeEventListener("resize", handleWindowResize);
    cancelAnimationFrame(rafIdRef.current);

    dataDisposable.dispose();
    resizeDisposable.dispose();

    outputListenerPromise.then(() => {
        outputUnlisten?.();
    });
    reconnectingListenerPromise.then(() => {
        reconnectingUnlisten?.();
    });
    reconnectedListenerPromise.then(() => {
        reconnectedUnlisten?.();
    });
    disconnectListenerPromise.then(() => {
        disconnectUnlisten?.();
    });

    terminal.dispose();
    terminalRef.current = null;
    fitAddonRef.current = null;
};
```

**Step 3: Verify frontend compiles**

Run: `cd apps/web && bun run build 2>&1 | tail -10`
Expected: Clean build

**Step 4: Commit**

```bash
git add apps/web/src/components/ssh/ssh-terminal.tsx
git commit -m "feat(ssh): show inline reconnect status messages in terminal"
```

---

### Task 8: Update tab bar and status bar for reconnecting status

**Files:**
- Modify: `apps/web/src/components/ssh/ssh-tab-bar.tsx:14-19`
- Modify: `apps/web/src/components/ssh/ssh-status-bar.tsx:7-19`

**Step 1: Add reconnecting to STATUS_COLORS in ssh-tab-bar.tsx**

```typescript
const STATUS_COLORS: Record<SshSessionStatus, string> = {
	connected: "bg-green-500",
	connecting: "bg-yellow-500",
	reconnecting: "bg-yellow-500 animate-pulse",
	disconnected: "bg-red-500",
	error: "bg-red-500",
};
```

**Step 2: Add reconnecting to STATUS_LABELS and STATUS_COLORS in ssh-status-bar.tsx**

```typescript
const STATUS_LABELS: Record<SshSessionStatus, string> = {
	connected: "Connected",
	connecting: "Connecting...",
	reconnecting: "Reconnecting...",
	disconnected: "Disconnected",
	error: "Error",
};

const STATUS_COLORS: Record<SshSessionStatus, string> = {
	connected: "text-green-500",
	connecting: "text-yellow-500",
	reconnecting: "text-yellow-500",
	disconnected: "text-red-500",
	error: "text-red-500",
};
```

**Step 3: Verify frontend compiles**

Run: `cd apps/web && bun run build 2>&1 | tail -10`
Expected: Clean build

**Step 4: Commit**

```bash
git add apps/web/src/components/ssh/ssh-tab-bar.tsx apps/web/src/components/ssh/ssh-status-bar.tsx
git commit -m "feat(ssh): add reconnecting status indicators to tab bar and status bar"
```

---

### Task 9: Add manual retry handling in terminal

**Files:**
- Modify: `apps/web/src/components/ssh/ssh-terminal.tsx`
- Modify: `apps/web/src/components/ssh/ssh-session-provider.tsx`

**Step 1: Add `retry` function to session provider context**

In `ssh-session-provider.tsx`, add a `retry` callback and expose it in the context:

Update the context interface:

```typescript
interface SshSessionContextValue {
	activeSessionId: string | null;
	connect: (params: ConnectParams) => Promise<string>;
	disconnect: (sessionId: string) => Promise<void>;
	retry: (sessionId: string) => Promise<void>;
	sessions: Map<string, SshSessionInfo>;
	setActive: (sessionId: string | null) => void;
}
```

Add the retry callback (after `disconnect`):

```typescript
const retry = useCallback(async (sessionId: string): Promise<void> => {
    await invoke("ssh_retry", { sessionId });
}, []);
```

Add `retry` to the provider value:

```typescript
<SshSessionContext.Provider
    value={{
        sessions,
        activeSessionId,
        connect,
        disconnect,
        retry,
        setActive,
    }}
>
```

**Step 2: Add retry-on-Enter logic to ssh-terminal.tsx**

The terminal needs to know the session status so it can intercept Enter for retry. Add a `status` prop:

```typescript
interface SshTerminalProps {
	cursorBlink?: boolean;
	cursorStyle?: "block" | "underline" | "bar";
	fontFamily?: string;
	fontSize?: number;
	isActive: boolean;
	onRetry?: () => void;
	scrollback?: number;
	sessionId: string;
	status: SshSessionStatus;
}
```

Update the component signature:

```typescript
export function SshTerminal({
	sessionId,
	isActive,
	status,
	onRetry,
	fontSize = 14,
	fontFamily = "monospace",
	cursorStyle = "block",
	cursorBlink = true,
	scrollback = 1000,
}: SshTerminalProps) {
```

Store status and onRetry in refs so the data handler can access them without re-creating the terminal:

```typescript
const statusRef = useRef(status);
statusRef.current = status;
const onRetryRef = useRef(onRetry);
onRetryRef.current = onRetry;
```

Modify the `terminal.onData` handler to intercept Enter when disconnected:

```typescript
const dataDisposable = terminal.onData((data: string) => {
    // Intercept Enter key when disconnected for manual retry.
    if (statusRef.current === "disconnected" && data === "\r") {
        onRetryRef.current?.();
        return;
    }

    const bytes = new TextEncoder().encode(data);
    const chunks: string[] = [];
    const CHUNK_SIZE = 8192;
    for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
        const slice = bytes.subarray(i, i + CHUNK_SIZE);
        chunks.push(String.fromCodePoint(...slice));
    }
    const encoded = btoa(chunks.join(""));
    invoke("ssh_write", { sessionId, data: encoded }).catch(() => {});
});
```

**Step 3: Update route.tsx to pass new props**

In `apps/web/src/routes/ssh/route.tsx`, update the `SshTerminal` usage (around line 278):

```typescript
Array.from(sessions.values()).map((session) => (
    <SshTerminal
        cursorBlink={terminalSettings.cursorBlink}
        cursorStyle={terminalSettings.cursorStyle}
        fontFamily={terminalSettings.fontFamily}
        fontSize={terminalSettings.fontSize}
        isActive={session.id === activeSessionId}
        key={session.id}
        onRetry={() => retry(session.id)}
        scrollback={terminalSettings.scrollback}
        sessionId={session.id}
        status={session.status}
    />
))
```

Also destructure `retry` from `useSshSessions()`:

```typescript
const { sessions, activeSessionId, connect, disconnect, retry, setActive } =
    useSshSessions();
```

Import `SshSessionStatus` type if needed (already imported via `SshHost`).

**Step 4: Verify frontend compiles**

Run: `cd apps/web && bun run build 2>&1 | tail -10`
Expected: Clean build

**Step 5: Run ultracite lint**

Run: `cd apps/web && bun x ultracite check 2>&1 | tail -20`
Fix any issues found.

**Step 6: Commit**

```bash
git add apps/web/src/components/ssh/ssh-terminal.tsx apps/web/src/components/ssh/ssh-session-provider.tsx apps/web/src/routes/ssh/route.tsx
git commit -m "feat(ssh): add manual retry on Enter key after reconnection failure"
```

---

### Task 10: Full build verification and final commit

**Files:**
- All modified files

**Step 1: Verify Rust backend compiles**

Run: `cd apps/web/src-tauri && cargo check 2>&1 | tail -20`
Expected: Clean compile

**Step 2: Verify frontend builds**

Run: `cd apps/web && bun run build 2>&1 | tail -20`
Expected: Clean build

**Step 3: Run ultracite lint and fix**

Run: `cd apps/web && bun x ultracite fix && bun x ultracite check 2>&1 | tail -20`
Expected: No remaining issues

**Step 4: Commit any lint fixes**

```bash
git add -A
git commit -m "chore: fix lint issues from auto-reconnect implementation"
```

---

## Testing Checklist (Manual)

Since this is a Tauri desktop app, verify manually:

1. **Normal connect** — Connect to a host, verify terminal works as before
2. **User disconnect** — Close a tab, verify NO reconnect attempt
3. **Network drop** — Disconnect network (WiFi off), verify:
   - Terminal shows yellow "Connection lost. Reconnecting (1/5)..."
   - Tab bar shows pulsing yellow indicator
   - Status bar shows "Reconnecting..."
   - After restoring network, see "Reconnected." in green
4. **Input buffering** — While reconnecting, type some text. After reconnect, verify the text appears in the remote shell
5. **Max retries exceeded** — Keep network off for > 5 attempts, verify:
   - Terminal shows red "Reconnection failed" message
   - Status changes to "disconnected"
   - Pressing Enter triggers new reconnect cycle
6. **Multiple sessions** — Open 2+ sessions, disconnect network, verify each session reconnects independently
