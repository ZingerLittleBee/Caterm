# SSH Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a full-featured SSH terminal client into the Caterm Tauri desktop app with multi-tab sessions, encrypted credential storage, and host management.

**Architecture:** Session Manager singleton pattern in Rust. `SshSessionManager` holds `Arc<Mutex<HashMap<String, SshSession>>>`. Each session spawns a tokio background task reading SSH output and emitting Tauri events. Frontend uses React Context for session state, xterm.js for terminal rendering.

**Tech Stack:** Rust (russh, tauri-plugin-sql, tauri-plugin-stronghold, tokio), React 19 (xterm.js, @tanstack/react-form, zod, shadcn/ui with base-nova style)

**Design Doc:** `docs/plans/2026-03-03-ssh-feature-design.md`

---

## Task 1: Install Rust Dependencies

**Files:**
- Modify: `apps/web/src-tauri/Cargo.toml`

**Step 1: Add dependencies to Cargo.toml**

Add these dependencies to `[dependencies]` section:

```toml
russh = "0.46"
russh-keys = "0.46"
tokio = { version = "1", features = ["full"] }
uuid = { version = "1", features = ["v4"] }
base64 = "0.22"
tauri-plugin-sql = { version = "2", features = ["sqlite"] }
tauri-plugin-stronghold = "2"
async-trait = "0.1"
thiserror = "2"
```

Also add for debug build performance:

```toml
[profile.dev.package.scrypt]
opt-level = 3
```

**Step 2: Verify cargo resolves all dependencies**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles successfully (warnings OK)

**Step 3: Commit**

```bash
git add apps/web/src-tauri/Cargo.toml
git commit -m "feat(ssh): add Rust dependencies for SSH feature"
```

---

## Task 2: Install Frontend Dependencies

**Files:**
- Modify: `apps/web/package.json`

**Step 1: Install xterm.js packages**

Run from `apps/web/`:
```bash
bun add @xterm/xterm @xterm/addon-fit @xterm/addon-webgl @xterm/addon-web-links
```

**Step 2: Install TanStack Form**

```bash
bun add @tanstack/react-form
```

**Step 3: Install Tauri plugin JS bindings**

```bash
bun add @tauri-apps/plugin-sql @tauri-apps/plugin-stronghold
```

**Step 4: Verify installation**

Run: `bun run build`
Expected: Builds successfully

**Step 5: Commit**

```bash
git add apps/web/package.json bun.lock
git commit -m "feat(ssh): add frontend dependencies for SSH feature"
```

---

## Task 3: Database Module (SQLite Migrations + Host CRUD)

**Files:**
- Create: `apps/web/src-tauri/src/db/mod.rs`
- Create: `apps/web/src-tauri/src/db/migrations.rs`
- Create: `apps/web/src-tauri/src/db/models.rs`

**Step 1: Create db module directory**

Run: `mkdir -p apps/web/src-tauri/src/db`

**Step 2: Create models.rs with data structures**

File: `apps/web/src-tauri/src/db/models.rs`

```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshHost {
    pub id: String,
    pub name: String,
    pub hostname: String,
    pub port: i32,
    pub username: String,
    pub auth_type: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalSettings {
    pub id: String,
    pub font_family: String,
    pub font_size: i32,
    pub cursor_style: String,
    pub cursor_blink: bool,
    pub scrollback: i32,
    pub theme: String,
}

impl Default for TerminalSettings {
    fn default() -> Self {
        Self {
            id: "default".to_string(),
            font_family: "monospace".to_string(),
            font_size: 14,
            cursor_style: "block".to_string(),
            cursor_blink: true,
            scrollback: 1000,
            theme: "default".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateHostInput {
    pub name: String,
    pub hostname: String,
    pub port: Option<i32>,
    pub username: String,
    pub auth_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateHostInput {
    pub id: String,
    pub name: Option<String>,
    pub hostname: Option<String>,
    pub port: Option<i32>,
    pub username: Option<String>,
    pub auth_type: Option<String>,
}
```

**Step 3: Create migrations.rs**

File: `apps/web/src-tauri/src/db/migrations.rs`

```rust
use tauri_plugin_sql::{Migration, MigrationKind};

pub fn get_migrations() -> Vec<Migration> {
    vec![
        Migration {
            version: 1,
            description: "create_ssh_hosts_table",
            sql: "CREATE TABLE IF NOT EXISTS ssh_hosts (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                hostname    TEXT NOT NULL,
                port        INTEGER DEFAULT 22,
                username    TEXT NOT NULL,
                auth_type   TEXT NOT NULL,
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );",
            kind: MigrationKind::Up,
        },
        Migration {
            version: 2,
            description: "create_terminal_settings_table",
            sql: "CREATE TABLE IF NOT EXISTS terminal_settings (
                id           TEXT PRIMARY KEY DEFAULT 'default',
                font_family  TEXT DEFAULT 'monospace',
                font_size    INTEGER DEFAULT 14,
                cursor_style TEXT DEFAULT 'block',
                cursor_blink INTEGER DEFAULT 1,
                scrollback   INTEGER DEFAULT 1000,
                theme        TEXT DEFAULT 'default'
            );
            INSERT OR IGNORE INTO terminal_settings (id) VALUES ('default');",
            kind: MigrationKind::Up,
        },
    ]
}
```

**Step 4: Create db/mod.rs**

File: `apps/web/src-tauri/src/db/mod.rs`

```rust
pub mod migrations;
pub mod models;
```

**Step 5: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles (with unused warnings OK at this stage)

**Step 6: Commit**

```bash
git add apps/web/src-tauri/src/db/
git commit -m "feat(ssh): add database module with migrations and models"
```

---

## Task 4: Stronghold Encryption Module

**Files:**
- Create: `apps/web/src-tauri/src/crypto/mod.rs`
- Create: `apps/web/src-tauri/src/crypto/stronghold.rs`

**Step 1: Create crypto module directory**

Run: `mkdir -p apps/web/src-tauri/src/crypto`

**Step 2: Create stronghold.rs**

File: `apps/web/src-tauri/src/crypto/stronghold.rs`

```rust
use std::sync::Arc;
use tauri::AppHandle;
use tauri_plugin_stronghold::stronghold::Stronghold;
use tokio::sync::Mutex;

#[derive(Debug, thiserror::Error)]
pub enum StrongholdError {
    #[error("Stronghold not initialized")]
    NotInitialized,
    #[error("Stronghold error: {0}")]
    Internal(String),
    #[error("Record not found: {0}")]
    NotFound(String),
}

impl serde::Serialize for StrongholdError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

pub struct StrongholdManager {
    app_handle: AppHandle,
}

impl StrongholdManager {
    pub fn new(app_handle: AppHandle) -> Self {
        Self { app_handle }
    }

    pub fn save_record(&self, key: &str, value: &[u8]) -> Result<(), StrongholdError> {
        let stronghold = self
            .app_handle
            .stronghold()
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        let client = stronghold
            .load_client("caterm")
            .or_else(|_| stronghold.create_client("caterm"))
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        let store = client.store();
        store
            .insert(key.as_bytes().to_vec(), value.to_vec(), None)
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        stronghold
            .save()
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        Ok(())
    }

    pub fn get_record(&self, key: &str) -> Result<Vec<u8>, StrongholdError> {
        let stronghold = self
            .app_handle
            .stronghold()
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        let client = stronghold
            .load_client("caterm")
            .or_else(|_| stronghold.create_client("caterm"))
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        let store = client.store();
        let data = store
            .get(key.as_bytes())
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        data.ok_or_else(|| StrongholdError::NotFound(key.to_string()))
    }

    pub fn delete_record(&self, key: &str) -> Result<(), StrongholdError> {
        let stronghold = self
            .app_handle
            .stronghold()
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        let client = stronghold
            .load_client("caterm")
            .or_else(|_| stronghold.create_client("caterm"))
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        let store = client.store();
        let _ = store.delete(key.as_bytes());

        stronghold
            .save()
            .map_err(|e| StrongholdError::Internal(e.to_string()))?;

        Ok(())
    }
}

/// Extension trait to access Stronghold from AppHandle
trait StrongholdExt {
    fn stronghold(&self) -> Result<Arc<Stronghold>, String>;
}

impl StrongholdExt for AppHandle {
    fn stronghold(&self) -> Result<Arc<Stronghold>, String> {
        // This will be provided by tauri-plugin-stronghold after initialization
        self.try_state::<Arc<Stronghold>>()
            .map(|s| s.inner().clone())
            .ok_or_else(|| "Stronghold not initialized".to_string())
    }
}
```

> **Note to implementer:** The exact Stronghold API depends on the plugin version. Check `tauri-plugin-stronghold` v2 docs for the precise `AppHandle` extension trait. The above is a structural guide — adjust method signatures to match the actual API. Use `agent-browser` to check https://v2.tauri.app/plugin/stronghold/ for the latest API.

**Step 3: Create crypto/mod.rs**

File: `apps/web/src-tauri/src/crypto/mod.rs`

```rust
pub mod stronghold;
```

**Step 4: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles (adjust Stronghold API if needed)

**Step 5: Commit**

```bash
git add apps/web/src-tauri/src/crypto/
git commit -m "feat(ssh): add Stronghold encryption module"
```

---

## Task 5: SSH Client Handler (russh)

**Files:**
- Create: `apps/web/src-tauri/src/ssh/mod.rs`
- Create: `apps/web/src-tauri/src/ssh/handler.rs`

**Step 1: Create ssh module directory**

Run: `mkdir -p apps/web/src-tauri/src/ssh`

**Step 2: Create handler.rs (russh Client Handler)**

File: `apps/web/src-tauri/src/ssh/handler.rs`

```rust
use async_trait::async_trait;
use russh::client;
use russh_keys::key;

pub struct SshClientHandler;

#[async_trait]
impl client::Handler for SshClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // Accept all host keys for now
        // TODO: Implement known_hosts verification
        Ok(true)
    }
}
```

> **Note to implementer:** The `client::Handler` trait methods vary by russh version. Check `docs.rs/russh` for the exact trait definition. The `check_server_key` method is the only required one. Use `agent-browser` to verify at https://docs.rs/russh/latest/russh/client/trait.Handler.html

**Step 3: Create ssh/mod.rs (initial)**

File: `apps/web/src-tauri/src/ssh/mod.rs`

```rust
pub mod handler;
```

**Step 4: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles

**Step 5: Commit**

```bash
git add apps/web/src-tauri/src/ssh/
git commit -m "feat(ssh): add russh client handler"
```

---

## Task 6: SSH Session & Manager

**Files:**
- Create: `apps/web/src-tauri/src/ssh/session.rs`
- Create: `apps/web/src-tauri/src/ssh/manager.rs`
- Modify: `apps/web/src-tauri/src/ssh/mod.rs`

**Step 1: Create session.rs**

File: `apps/web/src-tauri/src/ssh/session.rs`

```rust
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use russh::client;
use russh::ChannelId;
use std::sync::Arc;
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex;

#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),
    #[error("Authentication failed: {0}")]
    AuthFailed(String),
    #[error("Channel error: {0}")]
    ChannelError(String),
    #[error("Session not found: {0}")]
    NotFound(String),
    #[error("IO error: {0}")]
    Io(String),
}

impl serde::Serialize for SshError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

pub struct SshSession {
    pub id: String,
    pub host_id: String,
    channel: Arc<Mutex<russh::Channel<client::Msg>>>,
    handle: Arc<client::Handle<super::handler::SshClientHandler>>,
}

impl SshSession {
    pub async fn connect_with_password(
        id: String,
        host_id: String,
        hostname: &str,
        port: u16,
        username: &str,
        password: &str,
        app_handle: AppHandle,
    ) -> Result<Self, SshError> {
        let config = Arc::new(client::Config::default());
        let handler = super::handler::SshClientHandler;

        let mut handle = client::connect(config, (hostname, port), handler)
            .await
            .map_err(|e| SshError::ConnectionFailed(e.to_string()))?;

        let auth_result = handle
            .authenticate_password(username, password)
            .await
            .map_err(|e| SshError::AuthFailed(e.to_string()))?;

        if !auth_result {
            return Err(SshError::AuthFailed("Invalid credentials".to_string()));
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_pty(
                false,
                "xterm-256color",
                80,
                24,
                0,
                0,
                &[],
            )
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_shell(false)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        let channel = Arc::new(Mutex::new(channel));
        let handle = Arc::new(handle);

        let session = Self {
            id: id.clone(),
            host_id,
            channel: channel.clone(),
            handle,
        };

        // Spawn background task to read SSH output
        Self::spawn_reader(id, channel, app_handle);

        Ok(session)
    }

    pub async fn connect_with_key(
        id: String,
        host_id: String,
        hostname: &str,
        port: u16,
        username: &str,
        private_key: &str,
        passphrase: Option<&str>,
        app_handle: AppHandle,
    ) -> Result<Self, SshError> {
        let config = Arc::new(client::Config::default());
        let handler = super::handler::SshClientHandler;

        let mut handle = client::connect(config, (hostname, port), handler)
            .await
            .map_err(|e| SshError::ConnectionFailed(e.to_string()))?;

        let key_pair = if let Some(phrase) = passphrase {
            russh_keys::decode_secret_key(private_key, Some(phrase))
                .map_err(|e| SshError::AuthFailed(format!("Invalid key: {e}")))?
        } else {
            russh_keys::decode_secret_key(private_key, None)
                .map_err(|e| SshError::AuthFailed(format!("Invalid key: {e}")))?
        };

        let auth_result = handle
            .authenticate_publickey(username, Arc::new(key_pair))
            .await
            .map_err(|e| SshError::AuthFailed(e.to_string()))?;

        if !auth_result {
            return Err(SshError::AuthFailed(
                "Public key authentication rejected".to_string(),
            ));
        }

        let channel = handle
            .channel_open_session()
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_pty(
                false,
                "xterm-256color",
                80,
                24,
                0,
                0,
                &[],
            )
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        channel
            .request_shell(false)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))?;

        let channel = Arc::new(Mutex::new(channel));
        let handle = Arc::new(handle);

        let session = Self {
            id: id.clone(),
            host_id,
            channel: channel.clone(),
            handle,
        };

        Self::spawn_reader(id, channel, app_handle);

        Ok(session)
    }

    fn spawn_reader(
        session_id: String,
        channel: Arc<Mutex<russh::Channel<client::Msg>>>,
        app_handle: AppHandle,
    ) {
        tokio::spawn(async move {
            let event_name = format!("ssh-output-{session_id}");
            let disconnect_event = format!("ssh-disconnect-{session_id}");

            loop {
                let mut ch = channel.lock().await;
                match ch.wait().await {
                    Some(russh::ChannelMsg::Data { data }) => {
                        let encoded = BASE64.encode(data.as_ref());
                        let _ = app_handle.emit(&event_name, encoded);
                    }
                    Some(russh::ChannelMsg::ExtendedData { data, ext }) => {
                        // stderr (ext == 1)
                        let encoded = BASE64.encode(data.as_ref());
                        let _ = app_handle.emit(&event_name, encoded);
                    }
                    Some(russh::ChannelMsg::Eof | russh::ChannelMsg::Close) | None => {
                        let _ = app_handle.emit(&disconnect_event, ());
                        break;
                    }
                    _ => {}
                }
            }
        });
    }

    pub async fn write(&self, data: &[u8]) -> Result<(), SshError> {
        let channel = self.channel.lock().await;
        channel
            .data(data)
            .await
            .map_err(|e| SshError::Io(e.to_string()))
    }

    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), SshError> {
        let channel = self.channel.lock().await;
        channel
            .window_change(cols, rows, 0, 0)
            .await
            .map_err(|e| SshError::ChannelError(e.to_string()))
    }

    pub async fn close(&self) -> Result<(), SshError> {
        let channel = self.channel.lock().await;
        let _ = channel.eof().await;
        let _ = channel.close().await;
        Ok(())
    }
}
```

> **Note to implementer:** The russh API (channel methods like `data`, `request_pty`, `request_shell`, `window_change`, `wait`) varies between versions. Check `docs.rs/russh/0.46` for exact signatures. The `ChannelMsg` enum variants may differ. Use `agent-browser` to verify at https://docs.rs/russh/latest/russh/

**Step 2: Create manager.rs**

File: `apps/web/src-tauri/src/ssh/manager.rs`

```rust
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

use super::session::{SshError, SshSession};

pub struct SshSessionManager {
    sessions: Arc<Mutex<HashMap<String, SshSession>>>,
}

impl SshSessionManager {
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn add_session(&self, session: SshSession) {
        let mut sessions = self.sessions.lock().await;
        sessions.insert(session.id.clone(), session);
    }

    pub async fn write(&self, session_id: &str, data: &[u8]) -> Result<(), SshError> {
        let sessions = self.sessions.lock().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| SshError::NotFound(session_id.to_string()))?;
        session.write(data).await
    }

    pub async fn resize(
        &self,
        session_id: &str,
        cols: u32,
        rows: u32,
    ) -> Result<(), SshError> {
        let sessions = self.sessions.lock().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| SshError::NotFound(session_id.to_string()))?;
        session.resize(cols, rows).await
    }

    pub async fn disconnect(&self, session_id: &str) -> Result<(), SshError> {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.remove(session_id) {
            session.close().await?;
        }
        Ok(())
    }

    pub async fn disconnect_all(&self) {
        let mut sessions = self.sessions.lock().await;
        for (_, session) in sessions.drain() {
            let _ = session.close().await;
        }
    }

    pub async fn session_count(&self) -> usize {
        self.sessions.lock().await.len()
    }
}
```

**Step 3: Update ssh/mod.rs**

File: `apps/web/src-tauri/src/ssh/mod.rs`

```rust
pub mod handler;
pub mod manager;
pub mod session;
```

**Step 4: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles

**Step 5: Commit**

```bash
git add apps/web/src-tauri/src/ssh/
git commit -m "feat(ssh): add SSH session manager and session implementation"
```

---

## Task 7: Tauri Commands

**Files:**
- Create: `apps/web/src-tauri/src/commands/mod.rs`
- Create: `apps/web/src-tauri/src/commands/host_commands.rs`
- Create: `apps/web/src-tauri/src/commands/ssh_commands.rs`
- Create: `apps/web/src-tauri/src/commands/settings_commands.rs`

**Step 1: Create commands directory**

Run: `mkdir -p apps/web/src-tauri/src/commands`

**Step 2: Create host_commands.rs**

File: `apps/web/src-tauri/src/commands/host_commands.rs`

```rust
use crate::db::models::{CreateHostInput, SshHost, UpdateHostInput};
use tauri::AppHandle;
use tauri_plugin_sql::{DbInstances, DbPool};
use uuid::Uuid;

type Result<T> = std::result::Result<T, String>;

async fn get_db(app: &AppHandle) -> Result<DbPool> {
    let instances = app.state::<DbInstances>();
    let db = instances
        .0
        .lock()
        .await
        .get("sqlite:caterm.db")
        .cloned()
        .ok_or("Database not initialized")?;
    Ok(db)
}

#[tauri::command]
pub async fn list_hosts(app: AppHandle) -> Result<Vec<SshHost>> {
    let db = get_db(&app).await?;
    let hosts: Vec<SshHost> = sqlx::query_as(
        "SELECT id, name, hostname, port, username, auth_type, created_at, updated_at FROM ssh_hosts ORDER BY name"
    )
    .fetch_all(&*db)
    .await
    .map_err(|e| e.to_string())?;
    Ok(hosts)
}

#[tauri::command]
pub async fn get_host(app: AppHandle, host_id: String) -> Result<SshHost> {
    let db = get_db(&app).await?;
    let host: SshHost = sqlx::query_as(
        "SELECT id, name, hostname, port, username, auth_type, created_at, updated_at FROM ssh_hosts WHERE id = $1"
    )
    .bind(&host_id)
    .fetch_one(&*db)
    .await
    .map_err(|e| e.to_string())?;
    Ok(host)
}

#[tauri::command]
pub async fn create_host(app: AppHandle, input: CreateHostInput) -> Result<SshHost> {
    let db = get_db(&app).await?;
    let id = Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    let port = input.port.unwrap_or(22);

    sqlx::query(
        "INSERT INTO ssh_hosts (id, name, hostname, port, username, auth_type, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)"
    )
    .bind(&id)
    .bind(&input.name)
    .bind(&input.hostname)
    .bind(port)
    .bind(&input.username)
    .bind(&input.auth_type)
    .bind(&now)
    .bind(&now)
    .execute(&*db)
    .await
    .map_err(|e| e.to_string())?;

    Ok(SshHost {
        id,
        name: input.name,
        hostname: input.hostname,
        port,
        username: input.username,
        auth_type: input.auth_type,
        created_at: now.clone(),
        updated_at: now,
    })
}

#[tauri::command]
pub async fn update_host(app: AppHandle, input: UpdateHostInput) -> Result<SshHost> {
    let db = get_db(&app).await?;
    let now = chrono::Utc::now().to_rfc3339();

    // Fetch current host
    let current: SshHost = sqlx::query_as(
        "SELECT id, name, hostname, port, username, auth_type, created_at, updated_at FROM ssh_hosts WHERE id = $1"
    )
    .bind(&input.id)
    .fetch_one(&*db)
    .await
    .map_err(|e| e.to_string())?;

    let name = input.name.unwrap_or(current.name);
    let hostname = input.hostname.unwrap_or(current.hostname);
    let port = input.port.unwrap_or(current.port);
    let username = input.username.unwrap_or(current.username);
    let auth_type = input.auth_type.unwrap_or(current.auth_type);

    sqlx::query(
        "UPDATE ssh_hosts SET name = $1, hostname = $2, port = $3, username = $4, auth_type = $5, updated_at = $6 WHERE id = $7"
    )
    .bind(&name)
    .bind(&hostname)
    .bind(port)
    .bind(&username)
    .bind(&auth_type)
    .bind(&now)
    .bind(&input.id)
    .execute(&*db)
    .await
    .map_err(|e| e.to_string())?;

    Ok(SshHost {
        id: input.id,
        name,
        hostname,
        port,
        username,
        auth_type,
        created_at: current.created_at,
        updated_at: now,
    })
}

#[tauri::command]
pub async fn delete_host(app: AppHandle, host_id: String) -> Result<()> {
    let db = get_db(&app).await?;
    sqlx::query("DELETE FROM ssh_hosts WHERE id = $1")
        .bind(&host_id)
        .execute(&*db)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}
```

> **Note to implementer:** The `tauri-plugin-sql` v2 uses its own API, NOT raw sqlx. The database is accessed via the JS bridge (`@tauri-apps/plugin-sql`), not directly from Rust commands. The correct approach is to use the plugin's frontend API for SQL operations OR access the plugin's internal state. Check the actual plugin API — you may need to use `Database.load()` from JS instead. Alternatively, add `sqlx` directly as a Rust dependency alongside the plugin. Adjust the approach based on what compiles.

**Step 3: Create ssh_commands.rs**

File: `apps/web/src-tauri/src/commands/ssh_commands.rs`

```rust
use crate::ssh::manager::SshSessionManager;
use crate::ssh::session::SshSession;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use tauri::{AppHandle, State};
use uuid::Uuid;

type Result<T> = std::result::Result<T, String>;

#[tauri::command]
pub async fn ssh_connect(
    app: AppHandle,
    manager: State<'_, SshSessionManager>,
    host_id: String,
    hostname: String,
    port: u16,
    username: String,
    auth_type: String,
    password: Option<String>,
    private_key: Option<String>,
    key_passphrase: Option<String>,
) -> Result<String> {
    let session_id = Uuid::new_v4().to_string();

    let session = match auth_type.as_str() {
        "password" => {
            let pwd = password.ok_or("Password required for password auth")?;
            SshSession::connect_with_password(
                session_id.clone(),
                host_id,
                &hostname,
                port,
                &username,
                &pwd,
                app,
            )
            .await
            .map_err(|e| e.to_string())?
        }
        "key" => {
            let key = private_key.ok_or("Private key required for key auth")?;
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
            .await
            .map_err(|e| e.to_string())?
        }
        _ => return Err(format!("Unsupported auth type: {auth_type}")),
    };

    manager.add_session(session).await;

    Ok(session_id)
}

#[tauri::command]
pub async fn ssh_write(
    manager: State<'_, SshSessionManager>,
    session_id: String,
    data: String,
) -> Result<()> {
    let bytes = BASE64.decode(&data).map_err(|e| e.to_string())?;
    manager
        .write(&session_id, &bytes)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn ssh_resize(
    manager: State<'_, SshSessionManager>,
    session_id: String,
    cols: u32,
    rows: u32,
) -> Result<()> {
    manager
        .resize(&session_id, cols, rows)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn ssh_disconnect(
    manager: State<'_, SshSessionManager>,
    session_id: String,
) -> Result<()> {
    manager
        .disconnect(&session_id)
        .await
        .map_err(|e| e.to_string())
}
```

**Step 4: Create settings_commands.rs**

File: `apps/web/src-tauri/src/commands/settings_commands.rs`

```rust
use crate::db::models::TerminalSettings;
use tauri::AppHandle;

type Result<T> = std::result::Result<T, String>;

// Terminal settings will be managed via the SQL plugin from the frontend
// These commands are placeholder stubs if we need Rust-side access

#[tauri::command]
pub async fn get_terminal_settings(app: AppHandle) -> Result<TerminalSettings> {
    // For V1, settings are managed entirely from the frontend via @tauri-apps/plugin-sql
    // This command exists as a fallback
    Ok(TerminalSettings::default())
}
```

**Step 5: Create commands/mod.rs**

File: `apps/web/src-tauri/src/commands/mod.rs`

```rust
pub mod host_commands;
pub mod settings_commands;
pub mod ssh_commands;
```

**Step 6: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles (adjust API as needed)

**Step 7: Commit**

```bash
git add apps/web/src-tauri/src/commands/
git commit -m "feat(ssh): add Tauri commands for hosts, SSH, and settings"
```

---

## Task 8: Wire Up Plugins and Commands in lib.rs

**Files:**
- Modify: `apps/web/src-tauri/src/lib.rs`
- Modify: `apps/web/src-tauri/capabilities/default.json`
- Modify: `apps/web/src-tauri/tauri.conf.json`

**Step 1: Update lib.rs to register everything**

Replace `apps/web/src-tauri/src/lib.rs` with:

```rust
mod commands;
mod crypto;
mod db;
mod ssh;

use ssh::manager::SshSessionManager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::default()
                .level(log::LevelFilter::Info)
                .build(),
        )
        .plugin(
            tauri_plugin_sql::Builder::default()
                .add_migrations(
                    "sqlite:caterm.db",
                    db::migrations::get_migrations(),
                )
                .build(),
        )
        .plugin(
            tauri_plugin_stronghold::Builder::new(|password| {
                use argon2::{hash_raw, Config, Variant, Version};
                let config = Config {
                    lanes: 4,
                    mem_cost: 10_000,
                    time_cost: 10,
                    variant: Variant::Argon2id,
                    version: Version::Version13,
                    ..Default::default()
                };
                let salt = b"caterm-stronghold-salt";
                let key = hash_raw(password.as_ref(), salt, &config)
                    .expect("Failed to hash password");
                key.try_into()
                    .expect("Hash output must be 32 bytes")
            })
            .build(),
        )
        .manage(SshSessionManager::new())
        .invoke_handler(tauri::generate_handler![
            commands::ssh_commands::ssh_connect,
            commands::ssh_commands::ssh_write,
            commands::ssh_commands::ssh_resize,
            commands::ssh_commands::ssh_disconnect,
            commands::host_commands::list_hosts,
            commands::host_commands::get_host,
            commands::host_commands::create_host,
            commands::host_commands::update_host,
            commands::host_commands::delete_host,
            commands::settings_commands::get_terminal_settings,
        ])
        .setup(|_app| {
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

> **Note to implementer:** The Stronghold password hash builder requires `argon2` crate. Add `argon2 = "0.5"` to Cargo.toml if not already pulled in by tauri-plugin-stronghold. Also add `chrono = "0.4"` for timestamp generation in host_commands. Check actual `tauri_plugin_stronghold::Builder` API — the closure signature may differ. Use `agent-browser` to check https://v2.tauri.app/plugin/stronghold/ for exact init code.

**Step 2: Update capabilities/default.json**

Replace `apps/web/src-tauri/capabilities/default.json` with:

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "Capability for the main window",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "sql:default",
    "sql:allow-execute",
    "stronghold:default",
    "log:default"
  ]
}
```

**Step 3: Verify compilation**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Compiles

**Step 4: Commit**

```bash
git add apps/web/src-tauri/src/lib.rs apps/web/src-tauri/capabilities/default.json
git commit -m "feat(ssh): wire up plugins, commands, and capabilities"
```

---

## Task 9: Frontend — SSH Session Context Provider

**Files:**
- Create: `apps/web/src/components/ssh/ssh-session-provider.tsx`
- Create: `apps/web/src/types/ssh.ts`

**Step 1: Create types file**

File: `apps/web/src/types/ssh.ts`

```typescript
export interface SshHost {
  id: string
  name: string
  hostname: string
  port: number
  username: string
  authType: string
  createdAt: string
  updatedAt: string
}

export interface CreateHostInput {
  name: string
  hostname: string
  port?: number
  username: string
  authType: 'password' | 'key'
}

export interface UpdateHostInput {
  id: string
  name?: string
  hostname?: string
  port?: number
  username?: string
  authType?: string
}

export type SshSessionStatus =
  | 'connecting'
  | 'connected'
  | 'disconnected'
  | 'error'

export interface SshSessionInfo {
  id: string
  hostId: string
  hostName: string
  status: SshSessionStatus
}
```

**Step 2: Create SSH session provider**

File: `apps/web/src/components/ssh/ssh-session-provider.tsx`

```tsx
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import {
  createContext,
  useCallback,
  useContext,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import type { SshSessionInfo, SshSessionStatus } from '@/types/ssh'

interface SshSessionContextValue {
  sessions: Map<string, SshSessionInfo>
  activeSessionId: string | null
  connect: (params: {
    hostId: string
    hostName: string
    hostname: string
    port: number
    username: string
    authType: string
    password?: string
    privateKey?: string
    keyPassphrase?: string
  }) => Promise<string>
  disconnect: (sessionId: string) => Promise<void>
  setActive: (sessionId: string) => void
}

const SshSessionContext = createContext<SshSessionContextValue | null>(null)

export function useSshSessions() {
  const ctx = useContext(SshSessionContext)
  if (!ctx) {
    throw new Error('useSshSessions must be used within SshSessionProvider')
  }
  return ctx
}

export function SshSessionProvider({ children }: { children: ReactNode }) {
  const [sessions, setSessions] = useState<Map<string, SshSessionInfo>>(
    () => new Map(),
  )
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const unlistenRefs = useRef<Map<string, (() => void)[]>>(new Map())

  const updateSession = useCallback(
    (sessionId: string, updates: Partial<SshSessionInfo>) => {
      setSessions((prev) => {
        const next = new Map(prev)
        const current = next.get(sessionId)
        if (current) {
          next.set(sessionId, { ...current, ...updates })
        }
        return next
      })
    },
    [],
  )

  const connect = useCallback(
    async (params: {
      hostId: string
      hostName: string
      hostname: string
      port: number
      username: string
      authType: string
      password?: string
      privateKey?: string
      keyPassphrase?: string
    }) => {
      const sessionInfo: SshSessionInfo = {
        id: '', // will be set after connect
        hostId: params.hostId,
        hostName: params.hostName,
        status: 'connecting',
      }

      const sessionId = await invoke<string>('ssh_connect', {
        hostId: params.hostId,
        hostname: params.hostname,
        port: params.port,
        username: params.username,
        authType: params.authType,
        password: params.password,
        privateKey: params.privateKey,
        keyPassphrase: params.keyPassphrase,
      })

      sessionInfo.id = sessionId
      sessionInfo.status = 'connected'

      setSessions((prev) => {
        const next = new Map(prev)
        next.set(sessionId, sessionInfo)
        return next
      })
      setActiveSessionId(sessionId)

      // Listen for disconnect events
      const unlistenDisconnect = await listen(
        `ssh-disconnect-${sessionId}`,
        () => {
          updateSession(sessionId, { status: 'disconnected' })
        },
      )

      unlistenRefs.current.set(sessionId, [unlistenDisconnect])

      return sessionId
    },
    [updateSession],
  )

  const disconnect = useCallback(async (sessionId: string) => {
    await invoke('ssh_disconnect', { sessionId })

    // Clean up listeners
    const unlisteners = unlistenRefs.current.get(sessionId)
    if (unlisteners) {
      for (const unlisten of unlisteners) {
        unlisten()
      }
      unlistenRefs.current.delete(sessionId)
    }

    setSessions((prev) => {
      const next = new Map(prev)
      next.delete(sessionId)
      return next
    })

    setActiveSessionId((prev) => {
      if (prev === sessionId) {
        // Switch to another session or null
        const remaining = [...sessions.keys()].filter((k) => k !== sessionId)
        return remaining[0] ?? null
      }
      return prev
    })
  }, [sessions])

  const setActive = useCallback((sessionId: string) => {
    setActiveSessionId(sessionId)
  }, [])

  return (
    <SshSessionContext.Provider
      value={{ sessions, activeSessionId, connect, disconnect, setActive }}
    >
      {children}
    </SshSessionContext.Provider>
  )
}
```

**Step 3: Commit**

```bash
git add apps/web/src/types/ssh.ts apps/web/src/components/ssh/
git commit -m "feat(ssh): add SSH session context provider and types"
```

---

## Task 10: Frontend — xterm.js Terminal Component

**Files:**
- Create: `apps/web/src/components/ssh/ssh-terminal.tsx`

**Step 1: Create the xterm.js wrapper**

File: `apps/web/src/components/ssh/ssh-terminal.tsx`

```tsx
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { useEffect, useRef } from 'react'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'

interface SshTerminalProps {
  sessionId: string
  isActive: boolean
  fontSize?: number
  fontFamily?: string
  cursorStyle?: 'block' | 'underline' | 'bar'
  cursorBlink?: boolean
  scrollback?: number
}

export function SshTerminal({
  sessionId,
  isActive,
  fontSize = 14,
  fontFamily = 'monospace',
  cursorStyle = 'block',
  cursorBlink = true,
  scrollback = 1000,
}: SshTerminalProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const terminalRef = useRef<Terminal | null>(null)
  const fitAddonRef = useRef<FitAddon | null>(null)

  // Initialize terminal
  useEffect(() => {
    if (!containerRef.current) return

    const terminal = new Terminal({
      fontSize,
      fontFamily,
      cursorStyle,
      cursorBlink,
      scrollback,
      allowProposedApi: true,
    })

    const fitAddon = new FitAddon()
    terminal.loadAddon(fitAddon)
    terminal.loadAddon(new WebLinksAddon())

    terminal.open(containerRef.current)
    fitAddon.fit()

    // Try WebGL renderer, fallback gracefully
    try {
      const webglAddon = new WebglAddon()
      webglAddon.onContextLoss(() => webglAddon.dispose())
      terminal.loadAddon(webglAddon)
    } catch {
      // WebGL not available, use default canvas renderer
    }

    terminalRef.current = terminal
    fitAddonRef.current = fitAddon

    // Handle user input -> SSH write
    const onDataDispose = terminal.onData((data) => {
      const encoded = btoa(data)
      invoke('ssh_write', { sessionId, data: encoded }).catch(() => {
        // Connection may have been closed
      })
    })

    // Handle terminal resize -> SSH resize
    const onResizeDispose = terminal.onResize(({ cols, rows }) => {
      invoke('ssh_resize', { sessionId, cols, rows }).catch(() => {
        // Ignore resize errors on closed sessions
      })
    })

    // Listen for SSH output from Rust
    let unlistenOutput: (() => void) | undefined
    listen<string>(`ssh-output-${sessionId}`, (event) => {
      const decoded = atob(event.payload)
      terminal.write(decoded)
    }).then((unlisten) => {
      unlistenOutput = unlisten
    })

    // Resize on window resize (debounced via rAF)
    let rafId: number
    const handleResize = () => {
      cancelAnimationFrame(rafId)
      rafId = requestAnimationFrame(() => {
        fitAddon.fit()
      })
    }
    window.addEventListener('resize', handleResize)

    return () => {
      onDataDispose.dispose()
      onResizeDispose.dispose()
      unlistenOutput?.()
      window.removeEventListener('resize', handleResize)
      cancelAnimationFrame(rafId)
      terminal.dispose()
      terminalRef.current = null
      fitAddonRef.current = null
    }
  }, [sessionId]) // Only re-create when sessionId changes

  // Re-fit when becoming active
  useEffect(() => {
    if (isActive && fitAddonRef.current) {
      // Delay fit to ensure DOM is visible
      requestAnimationFrame(() => {
        fitAddonRef.current?.fit()
      })
    }
  }, [isActive])

  return (
    <div
      ref={containerRef}
      data-session-id={sessionId}
      style={{
        width: '100%',
        height: '100%',
        display: isActive ? 'block' : 'none',
      }}
    />
  )
}
```

**Step 2: Commit**

```bash
git add apps/web/src/components/ssh/ssh-terminal.tsx
git commit -m "feat(ssh): add xterm.js terminal wrapper component"
```

---

## Task 11: Frontend — Host Management UI

**Files:**
- Create: `apps/web/src/components/hosts/host-form.tsx`
- Create: `apps/web/src/components/hosts/host-list.tsx`
- Create: `apps/web/src/components/hosts/host-card.tsx`
- Create: `apps/web/src/components/hosts/host-delete-dialog.tsx`

**Step 1: Create hosts directory**

Run: `mkdir -p apps/web/src/components/hosts`

**Step 2: Create host-form.tsx**

File: `apps/web/src/components/hosts/host-form.tsx`

Uses TanStack Form + Zod for validation. Supports both create and edit modes. Shows password field or private key textarea based on `authType` selection.

```tsx
import { useForm } from '@tanstack/react-form'
import { zodValidator } from '@tanstack/zod-form-adapter'
import { z } from 'zod'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import type { SshHost } from '@/types/ssh'

const hostSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  hostname: z.string().min(1, 'Hostname is required'),
  port: z.number().int().min(1).max(65535),
  username: z.string().min(1, 'Username is required'),
  authType: z.enum(['password', 'key']),
  password: z.string().optional(),
  privateKey: z.string().optional(),
  keyPassphrase: z.string().optional(),
})

type HostFormValues = z.infer<typeof hostSchema>

interface HostFormProps {
  host?: SshHost
  onSubmit: (values: HostFormValues) => Promise<void>
  onCancel: () => void
}

export function HostForm({ host, onSubmit, onCancel }: HostFormProps) {
  const form = useForm({
    defaultValues: {
      name: host?.name ?? '',
      hostname: host?.hostname ?? '',
      port: host?.port ?? 22,
      username: host?.username ?? '',
      authType: (host?.authType ?? 'password') as 'password' | 'key',
      password: '',
      privateKey: '',
      keyPassphrase: '',
    },
    onSubmit: async ({ value }) => {
      await onSubmit(value)
    },
    validatorAdapter: zodValidator(),
    validators: {
      onChange: hostSchema,
    },
  })

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault()
        e.stopPropagation()
        form.handleSubmit()
      }}
      className="space-y-4"
    >
      <form.Field name="name">
        {(field) => (
          <div className="space-y-2">
            <Label htmlFor="name">Name</Label>
            <Input
              id="name"
              value={field.state.value}
              onChange={(e) => field.handleChange(e.target.value)}
              onBlur={field.handleBlur}
              placeholder="My Server"
            />
            {field.state.meta.errors.length > 0 && (
              <p className="text-sm text-destructive">
                {field.state.meta.errors[0]}
              </p>
            )}
          </div>
        )}
      </form.Field>

      <div className="grid grid-cols-3 gap-4">
        <form.Field name="hostname">
          {(field) => (
            <div className="col-span-2 space-y-2">
              <Label htmlFor="hostname">Hostname</Label>
              <Input
                id="hostname"
                value={field.state.value}
                onChange={(e) => field.handleChange(e.target.value)}
                onBlur={field.handleBlur}
                placeholder="192.168.1.1"
              />
            </div>
          )}
        </form.Field>

        <form.Field name="port">
          {(field) => (
            <div className="space-y-2">
              <Label htmlFor="port">Port</Label>
              <Input
                id="port"
                type="number"
                value={field.state.value}
                onChange={(e) => field.handleChange(Number(e.target.value))}
                onBlur={field.handleBlur}
              />
            </div>
          )}
        </form.Field>
      </div>

      <form.Field name="username">
        {(field) => (
          <div className="space-y-2">
            <Label htmlFor="username">Username</Label>
            <Input
              id="username"
              value={field.state.value}
              onChange={(e) => field.handleChange(e.target.value)}
              onBlur={field.handleBlur}
              placeholder="root"
            />
          </div>
        )}
      </form.Field>

      <form.Field name="authType">
        {(field) => (
          <div className="space-y-2">
            <Label>Authentication</Label>
            <Select
              value={field.state.value}
              onValueChange={(val) =>
                field.handleChange(val as 'password' | 'key')
              }
            >
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="password">Password</SelectItem>
                <SelectItem value="key">Private Key</SelectItem>
              </SelectContent>
            </Select>
          </div>
        )}
      </form.Field>

      <form.Subscribe selector={(state) => state.values.authType}>
        {(authType) =>
          authType === 'password' ? (
            <form.Field name="password">
              {(field) => (
                <div className="space-y-2">
                  <Label htmlFor="password">Password</Label>
                  <Input
                    id="password"
                    type="password"
                    value={field.state.value}
                    onChange={(e) => field.handleChange(e.target.value)}
                    onBlur={field.handleBlur}
                  />
                </div>
              )}
            </form.Field>
          ) : (
            <>
              <form.Field name="privateKey">
                {(field) => (
                  <div className="space-y-2">
                    <Label htmlFor="privateKey">Private Key</Label>
                    <textarea
                      id="privateKey"
                      className="border-input bg-background flex w-full rounded-md border px-3 py-2 text-sm font-mono min-h-[120px] resize-y"
                      value={field.state.value}
                      onChange={(e) => field.handleChange(e.target.value)}
                      onBlur={field.handleBlur}
                      placeholder="-----BEGIN OPENSSH PRIVATE KEY-----"
                    />
                  </div>
                )}
              </form.Field>
              <form.Field name="keyPassphrase">
                {(field) => (
                  <div className="space-y-2">
                    <Label htmlFor="keyPassphrase">
                      Key Passphrase (optional)
                    </Label>
                    <Input
                      id="keyPassphrase"
                      type="password"
                      value={field.state.value}
                      onChange={(e) => field.handleChange(e.target.value)}
                      onBlur={field.handleBlur}
                    />
                  </div>
                )}
              </form.Field>
            </>
          )
        }
      </form.Subscribe>

      <div className="flex justify-end gap-2 pt-4">
        <Button type="button" variant="outline" onClick={onCancel}>
          Cancel
        </Button>
        <form.Subscribe selector={(state) => state.isSubmitting}>
          {(isSubmitting) => (
            <Button type="submit" disabled={isSubmitting}>
              {host ? 'Update' : 'Create'}
            </Button>
          )}
        </form.Subscribe>
      </div>
    </form>
  )
}
```

> **Note to implementer:** The TanStack Form + Zod adapter API may differ from what's shown. Check `@tanstack/react-form` docs for the exact `useForm`, `form.Field`, and `form.Subscribe` API. The `zodValidator()` adapter may need different import paths. Use Context7 MCP to query TanStack Form docs. Also the `Select` component may use a different API than shown here based on the project's `@base-ui/react` Select implementation — check `apps/web/src/components/ui/select.tsx` for the actual component API and adjust accordingly.

**Step 3: Create host-card.tsx**

File: `apps/web/src/components/hosts/host-card.tsx`

```tsx
import { MoreHorizontalIcon, PlugIcon, PencilIcon, TrashIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import type { SshHost } from '@/types/ssh'

interface HostCardProps {
  host: SshHost
  onConnect: (host: SshHost) => void
  onEdit: (host: SshHost) => void
  onDelete: (host: SshHost) => void
}

export function HostCard({ host, onConnect, onEdit, onDelete }: HostCardProps) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium">{host.name}</CardTitle>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon-sm">
              <MoreHorizontalIcon className="size-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={() => onConnect(host)}>
              <PlugIcon className="mr-2 size-4" />
              Connect
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => onEdit(host)}>
              <PencilIcon className="mr-2 size-4" />
              Edit
            </DropdownMenuItem>
            <DropdownMenuItem
              onClick={() => onDelete(host)}
              className="text-destructive"
            >
              <TrashIcon className="mr-2 size-4" />
              Delete
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </CardHeader>
      <CardContent>
        <p className="text-muted-foreground text-xs">
          {host.username}@{host.hostname}:{host.port}
        </p>
        <p className="text-muted-foreground text-xs mt-1">
          Auth: {host.authType}
        </p>
      </CardContent>
    </Card>
  )
}
```

**Step 4: Create host-list.tsx**

File: `apps/web/src/components/hosts/host-list.tsx`

```tsx
import { invoke } from '@tauri-apps/api/core'
import { PlusIcon } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import type { SshHost } from '@/types/ssh'
import { HostCard } from './host-card'
import { HostDeleteDialog } from './host-delete-dialog'

interface HostListProps {
  onConnect: (host: SshHost) => void
  onEdit: (host: SshHost) => void
  onAdd: () => void
}

export function HostList({ onConnect, onEdit, onAdd }: HostListProps) {
  const [hosts, setHosts] = useState<SshHost[]>([])
  const [deleteTarget, setDeleteTarget] = useState<SshHost | null>(null)

  const loadHosts = useCallback(async () => {
    const result = await invoke<SshHost[]>('list_hosts')
    setHosts(result)
  }, [])

  useEffect(() => {
    loadHosts()
  }, [loadHosts])

  const handleDelete = async (host: SshHost) => {
    await invoke('delete_host', { hostId: host.id })
    setDeleteTarget(null)
    loadHosts()
  }

  return (
    <div className="flex flex-col gap-2 p-2">
      <div className="flex items-center justify-between px-2">
        <h3 className="text-sm font-semibold">Hosts</h3>
        <Button variant="ghost" size="icon-sm" onClick={onAdd}>
          <PlusIcon className="size-4" />
        </Button>
      </div>
      <div className="flex flex-col gap-2">
        {hosts.map((host) => (
          <HostCard
            key={host.id}
            host={host}
            onConnect={onConnect}
            onEdit={onEdit}
            onDelete={setDeleteTarget}
          />
        ))}
        {hosts.length === 0 && (
          <p className="text-muted-foreground text-center text-sm py-8">
            No hosts configured
          </p>
        )}
      </div>

      <HostDeleteDialog
        host={deleteTarget}
        onConfirm={handleDelete}
        onCancel={() => setDeleteTarget(null)}
      />
    </div>
  )
}
```

**Step 5: Create host-delete-dialog.tsx**

File: `apps/web/src/components/hosts/host-delete-dialog.tsx`

```tsx
import { Button } from '@/components/ui/button'
import type { SshHost } from '@/types/ssh'

interface HostDeleteDialogProps {
  host: SshHost | null
  onConfirm: (host: SshHost) => void
  onCancel: () => void
}

export function HostDeleteDialog({
  host,
  onConfirm,
  onCancel,
}: HostDeleteDialogProps) {
  if (!host) return null

  return (
    <div className="bg-background/80 fixed inset-0 z-50 flex items-center justify-center backdrop-blur-sm">
      <div className="bg-card border rounded-lg p-6 max-w-sm w-full mx-4 shadow-lg">
        <h3 className="font-semibold text-lg">Delete Host</h3>
        <p className="text-muted-foreground text-sm mt-2">
          Are you sure you want to delete &quot;{host.name}&quot;? This action
          cannot be undone.
        </p>
        <div className="flex justify-end gap-2 mt-4">
          <Button variant="outline" onClick={onCancel}>
            Cancel
          </Button>
          <Button variant="destructive" onClick={() => onConfirm(host)}>
            Delete
          </Button>
        </div>
      </div>
    </div>
  )
}
```

> **Note to implementer:** The project uses `@base-ui/react` Dialog or the shadcn `sheet.tsx` for modals. Check if there's an `AlertDialog` component already in `src/components/ui/`. If so, use that instead of the custom overlay above. You may need to install `@shadcn/alert-dialog` via `bunx shadcn@latest add alert-dialog`.

**Step 6: Commit**

```bash
git add apps/web/src/components/hosts/
git commit -m "feat(ssh): add host management UI components"
```

---

## Task 12: Frontend — SSH Tab Bar & Status Bar

**Files:**
- Create: `apps/web/src/components/ssh/ssh-tab-bar.tsx`
- Create: `apps/web/src/components/ssh/ssh-status-bar.tsx`

**Step 1: Create ssh-tab-bar.tsx**

File: `apps/web/src/components/ssh/ssh-tab-bar.tsx`

```tsx
import { PlusIcon, XIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import type { SshSessionInfo } from '@/types/ssh'

interface SshTabBarProps {
  sessions: Map<string, SshSessionInfo>
  activeSessionId: string | null
  onSelect: (sessionId: string) => void
  onClose: (sessionId: string) => void
  onNew: () => void
}

export function SshTabBar({
  sessions,
  activeSessionId,
  onSelect,
  onClose,
  onNew,
}: SshTabBarProps) {
  const sessionList = [...sessions.values()]

  return (
    <div className="border-b flex items-center gap-0.5 px-2 h-9 bg-muted/30">
      {sessionList.map((session) => (
        <div
          key={session.id}
          className={cn(
            'flex items-center gap-1 px-3 h-7 rounded-t text-sm cursor-pointer border border-b-0 transition-colors',
            session.id === activeSessionId
              ? 'bg-background text-foreground'
              : 'bg-muted/50 text-muted-foreground hover:bg-muted',
          )}
          onClick={() => onSelect(session.id)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              onSelect(session.id)
            }
          }}
          role="tab"
          tabIndex={0}
          aria-selected={session.id === activeSessionId}
        >
          <span
            className={cn(
              'size-2 rounded-full',
              session.status === 'connected' && 'bg-green-500',
              session.status === 'connecting' && 'bg-yellow-500',
              session.status === 'disconnected' && 'bg-red-500',
              session.status === 'error' && 'bg-red-500',
            )}
          />
          <span className="truncate max-w-[120px]">{session.hostName}</span>
          <button
            type="button"
            className="ml-1 rounded hover:bg-muted-foreground/20 p-0.5"
            onClick={(e) => {
              e.stopPropagation()
              onClose(session.id)
            }}
            aria-label={`Close ${session.hostName}`}
          >
            <XIcon className="size-3" />
          </button>
        </div>
      ))}
      <Button
        variant="ghost"
        size="icon-sm"
        onClick={onNew}
        className="ml-1"
        aria-label="New connection"
      >
        <PlusIcon className="size-4" />
      </Button>
    </div>
  )
}
```

**Step 2: Create ssh-status-bar.tsx**

File: `apps/web/src/components/ssh/ssh-status-bar.tsx`

```tsx
import { cn } from '@/lib/utils'
import type { SshSessionInfo } from '@/types/ssh'

interface SshStatusBarProps {
  session: SshSessionInfo | null
}

const STATUS_LABELS: Record<string, string> = {
  connecting: 'Connecting...',
  connected: 'Connected',
  disconnected: 'Disconnected',
  error: 'Error',
}

export function SshStatusBar({ session }: SshStatusBarProps) {
  if (!session) return null

  return (
    <div className="border-t px-3 py-1 flex items-center gap-2 text-xs text-muted-foreground bg-muted/30">
      <span
        className={cn(
          'size-2 rounded-full',
          session.status === 'connected' && 'bg-green-500',
          session.status === 'connecting' && 'bg-yellow-500',
          session.status === 'disconnected' && 'bg-red-500',
          session.status === 'error' && 'bg-red-500',
        )}
      />
      <span>{STATUS_LABELS[session.status]}</span>
      <span className="ml-auto">{session.hostName}</span>
    </div>
  )
}
```

**Step 3: Commit**

```bash
git add apps/web/src/components/ssh/ssh-tab-bar.tsx apps/web/src/components/ssh/ssh-status-bar.tsx
git commit -m "feat(ssh): add SSH tab bar and status bar components"
```

---

## Task 13: Frontend — SSH Route Layout

**Files:**
- Create: `apps/web/src/routes/ssh/route.tsx`

**Step 1: Create SSH route directory and layout**

Run: `mkdir -p apps/web/src/routes/ssh`

File: `apps/web/src/routes/ssh/route.tsx`

```tsx
import { createFileRoute } from '@tanstack/react-router'
import { useCallback, useState } from 'react'
import { toast } from 'sonner'
import { HostForm } from '@/components/hosts/host-form'
import { HostList } from '@/components/hosts/host-list'
import { SshSessionProvider, useSshSessions } from '@/components/ssh/ssh-session-provider'
import { SshStatusBar } from '@/components/ssh/ssh-status-bar'
import { SshTabBar } from '@/components/ssh/ssh-tab-bar'
import { SshTerminal } from '@/components/ssh/ssh-terminal'
import type { SshHost } from '@/types/ssh'

export const Route = createFileRoute('/ssh')({
  component: SshPage,
})

function SshPage() {
  return (
    <SshSessionProvider>
      <SshLayout />
    </SshSessionProvider>
  )
}

function SshLayout() {
  const { sessions, activeSessionId, connect, disconnect, setActive } =
    useSshSessions()
  const [showForm, setShowForm] = useState(false)
  const [editHost, setEditHost] = useState<SshHost | null>(null)

  const activeSession = activeSessionId
    ? sessions.get(activeSessionId) ?? null
    : null

  const handleConnect = useCallback(
    async (host: SshHost) => {
      try {
        // TODO: Retrieve credentials from Stronghold
        // For now, prompt is handled by the form
        await connect({
          hostId: host.id,
          hostName: host.name,
          hostname: host.hostname,
          port: host.port,
          username: host.username,
          authType: host.authType,
          // credentials will be retrieved from Stronghold
        })
      } catch (err) {
        toast.error(`Connection failed: ${err}`)
      }
    },
    [connect],
  )

  const handleDisconnect = useCallback(
    async (sessionId: string) => {
      try {
        await disconnect(sessionId)
      } catch (err) {
        toast.error(`Disconnect failed: ${err}`)
      }
    },
    [disconnect],
  )

  return (
    <div className="flex h-screen">
      {/* Sidebar */}
      <div className="w-60 border-r flex flex-col overflow-y-auto">
        <HostList
          onConnect={handleConnect}
          onEdit={(host) => {
            setEditHost(host)
            setShowForm(true)
          }}
          onAdd={() => {
            setEditHost(null)
            setShowForm(true)
          }}
        />
      </div>

      {/* Main area */}
      <div className="flex-1 flex flex-col min-w-0">
        <SshTabBar
          sessions={sessions}
          activeSessionId={activeSessionId}
          onSelect={setActive}
          onClose={handleDisconnect}
          onNew={() => {
            setEditHost(null)
            setShowForm(true)
          }}
        />

        {/* Terminal area */}
        <div className="flex-1 relative">
          {[...sessions.entries()].map(([id]) => (
            <SshTerminal
              key={id}
              sessionId={id}
              isActive={id === activeSessionId}
            />
          ))}

          {sessions.size === 0 && (
            <div className="flex items-center justify-center h-full text-muted-foreground">
              <p>Select a host to connect, or add a new one.</p>
            </div>
          )}
        </div>

        <SshStatusBar session={activeSession} />
      </div>

      {/* Host form dialog/sheet */}
      {showForm && (
        <div className="bg-background/80 fixed inset-0 z-50 flex items-center justify-center backdrop-blur-sm">
          <div className="bg-card border rounded-lg p-6 max-w-md w-full mx-4 shadow-lg max-h-[90vh] overflow-y-auto">
            <h2 className="text-lg font-semibold mb-4">
              {editHost ? 'Edit Host' : 'New Host'}
            </h2>
            <HostForm
              host={editHost ?? undefined}
              onSubmit={async (values) => {
                // TODO: Save host via invoke and credentials via Stronghold
                setShowForm(false)
                toast.success(editHost ? 'Host updated' : 'Host created')
              }}
              onCancel={() => setShowForm(false)}
            />
          </div>
        </div>
      )}
    </div>
  )
}
```

> **Note to implementer:** This is a scaffold. The form submission needs to wire up `invoke('create_host')` / `invoke('update_host')` and credential storage via Stronghold JS API. Also ensure the route is registered properly — TanStack Router file-based routing may require specific directory/file naming. Check `apps/web/src/routes/` for the exact pattern used and run `bun run dev` to verify the route tree regenerates.

**Step 2: Commit**

```bash
git add apps/web/src/routes/ssh/
git commit -m "feat(ssh): add SSH route layout with terminal, tabs, and host sidebar"
```

---

## Task 14: Frontend — Terminal Settings Page

**Files:**
- Create: `apps/web/src/routes/ssh/settings.tsx`
- Create: `apps/web/src/components/settings/terminal-settings-form.tsx`

**Step 1: Create settings component**

Run: `mkdir -p apps/web/src/components/settings`

File: `apps/web/src/components/settings/terminal-settings-form.tsx`

```tsx
import Database from '@tauri-apps/plugin-sql'
import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'

interface TerminalSettingsValues {
  fontFamily: string
  fontSize: number
  cursorStyle: string
  cursorBlink: boolean
  scrollback: number
  theme: string
}

export function TerminalSettingsForm() {
  const [settings, setSettings] = useState<TerminalSettingsValues>({
    fontFamily: 'monospace',
    fontSize: 14,
    cursorStyle: 'block',
    cursorBlink: true,
    scrollback: 1000,
    theme: 'default',
  })

  const loadSettings = useCallback(async () => {
    const db = await Database.load('sqlite:caterm.db')
    const rows = await db.select<TerminalSettingsValues[]>(
      'SELECT font_family as fontFamily, font_size as fontSize, cursor_style as cursorStyle, cursor_blink as cursorBlink, scrollback, theme FROM terminal_settings WHERE id = $1',
      ['default'],
    )
    if (rows.length > 0) {
      setSettings({
        ...rows[0],
        cursorBlink: Boolean(rows[0].cursorBlink),
      })
    }
  }, [])

  useEffect(() => {
    loadSettings()
  }, [loadSettings])

  const handleSave = async () => {
    const db = await Database.load('sqlite:caterm.db')
    await db.execute(
      'UPDATE terminal_settings SET font_family = $1, font_size = $2, cursor_style = $3, cursor_blink = $4, scrollback = $5, theme = $6 WHERE id = $7',
      [
        settings.fontFamily,
        settings.fontSize,
        settings.cursorStyle,
        settings.cursorBlink ? 1 : 0,
        settings.scrollback,
        settings.theme,
        'default',
      ],
    )
    toast.success('Settings saved')
  }

  return (
    <div className="max-w-lg space-y-6">
      <div className="space-y-2">
        <Label htmlFor="fontFamily">Font Family</Label>
        <Input
          id="fontFamily"
          value={settings.fontFamily}
          onChange={(e) =>
            setSettings((s) => ({ ...s, fontFamily: e.target.value }))
          }
        />
      </div>

      <div className="space-y-2">
        <Label htmlFor="fontSize">Font Size</Label>
        <Input
          id="fontSize"
          type="number"
          value={settings.fontSize}
          onChange={(e) =>
            setSettings((s) => ({ ...s, fontSize: Number(e.target.value) }))
          }
          min={8}
          max={32}
        />
      </div>

      <div className="space-y-2">
        <Label>Cursor Style</Label>
        <Select
          value={settings.cursorStyle}
          onValueChange={(val) =>
            setSettings((s) => ({ ...s, cursorStyle: val }))
          }
        >
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="block">Block</SelectItem>
            <SelectItem value="underline">Underline</SelectItem>
            <SelectItem value="bar">Bar</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex items-center gap-2">
        <input
          type="checkbox"
          id="cursorBlink"
          checked={settings.cursorBlink}
          onChange={(e) =>
            setSettings((s) => ({ ...s, cursorBlink: e.target.checked }))
          }
        />
        <Label htmlFor="cursorBlink">Cursor Blink</Label>
      </div>

      <div className="space-y-2">
        <Label htmlFor="scrollback">Scrollback Lines</Label>
        <Input
          id="scrollback"
          type="number"
          value={settings.scrollback}
          onChange={(e) =>
            setSettings((s) => ({ ...s, scrollback: Number(e.target.value) }))
          }
          min={100}
          max={10000}
        />
      </div>

      <Button onClick={handleSave}>Save Settings</Button>
    </div>
  )
}
```

> **Note to implementer:** The `@base-ui/react` Checkbox component from the project should be used instead of `<input type="checkbox">`. Check `apps/web/src/components/ui/checkbox.tsx` for the actual component API. Also the `Select` component API should match the project's implementation.

**Step 2: Create settings route**

File: `apps/web/src/routes/ssh/settings.tsx`

```tsx
import { createFileRoute } from '@tanstack/react-router'
import { TerminalSettingsForm } from '@/components/settings/terminal-settings-form'

export const Route = createFileRoute('/ssh/settings')({
  component: TerminalSettingsPage,
})

function TerminalSettingsPage() {
  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-6">Terminal Settings</h1>
      <TerminalSettingsForm />
    </div>
  )
}
```

**Step 3: Commit**

```bash
git add apps/web/src/components/settings/ apps/web/src/routes/ssh/settings.tsx
git commit -m "feat(ssh): add terminal settings page"
```

---

## Task 15: Update Navigation & Root Layout

**Files:**
- Modify: `apps/web/src/components/nav-main.tsx`
- Modify: `apps/web/src/components/app-sidebar.tsx`

**Step 1: Add SSH navigation items**

Add SSH-related items to the sidebar navigation. Check the current `nav-main.tsx` for the data structure pattern and add:

- SSH Terminal (icon: `TerminalIcon`, route: `/ssh`)
- Terminal Settings (icon: `SettingsIcon`, route: `/ssh/settings`)

**Step 2: Verify route tree regeneration**

Run: `cd apps/web && bun run dev`
Expected: TanStack Router picks up new routes, generates updated `routeTree.gen.ts`

**Step 3: Verify navigation works**

Check that clicking SSH in sidebar navigates to `/ssh` route.

**Step 4: Commit**

```bash
git add apps/web/src/components/nav-main.tsx apps/web/src/components/app-sidebar.tsx apps/web/src/routes/
git commit -m "feat(ssh): add SSH navigation to sidebar"
```

---

## Task 16: Export/Import Configuration

**Files:**
- Create: `apps/web/src-tauri/src/commands/config_commands.rs`
- Modify: `apps/web/src-tauri/src/commands/mod.rs`
- Modify: `apps/web/src-tauri/src/lib.rs`

**Step 1: Create config export/import commands**

File: `apps/web/src-tauri/src/commands/config_commands.rs`

```rust
use serde::{Deserialize, Serialize};
use tauri::AppHandle;

type Result<T> = std::result::Result<T, String>;

#[derive(Serialize, Deserialize)]
struct ExportData {
    version: u32,
    hosts: Vec<serde_json::Value>,
    credentials: Vec<(String, Vec<u8>)>,
    settings: serde_json::Value,
}

#[tauri::command]
pub async fn export_config(app: AppHandle, password: String) -> Result<Vec<u8>> {
    // TODO: Implementation
    // 1. Read all hosts from SQLite
    // 2. Read all credentials from Stronghold
    // 3. Read terminal settings from SQLite
    // 4. Serialize to JSON
    // 5. Encrypt with password using Stronghold
    // 6. Return encrypted bytes
    Err("Export not yet implemented".to_string())
}

#[tauri::command]
pub async fn import_config(
    app: AppHandle,
    data: Vec<u8>,
    password: String,
) -> Result<()> {
    // TODO: Implementation
    // 1. Decrypt data with password
    // 2. Deserialize JSON
    // 3. Insert hosts into SQLite
    // 4. Store credentials in Stronghold
    // 5. Update terminal settings
    Err("Import not yet implemented".to_string())
}
```

> **Note:** Export/import is a V1.1 feature. The stubs are placed now for API completeness. Implement the actual logic after the core SSH functionality works end-to-end.

**Step 2: Update commands/mod.rs**

Add `pub mod config_commands;`

**Step 3: Register in lib.rs invoke_handler**

Add:
```rust
commands::config_commands::export_config,
commands::config_commands::import_config,
```

**Step 4: Commit**

```bash
git add apps/web/src-tauri/src/commands/
git commit -m "feat(ssh): add export/import config command stubs"
```

---

## Task 17: Integration Verification & Polish

**Step 1: Run Rust compilation check**

Run: `cd apps/web/src-tauri && cargo check`
Expected: Clean compilation

**Step 2: Run frontend build**

Run: `cd apps/web && bun run build`
Expected: Successful build

**Step 3: Run linting**

Run: `bun x ultracite check`
Expected: No errors (run `bun x ultracite fix` to auto-fix if needed)

**Step 4: Run Tauri dev**

Run: `cd apps/web && bun run tauri:dev` (or `make tauri-dev` from root)
Expected: App launches, SSH route accessible, host CRUD works

**Step 5: Manual test checklist**

- [ ] Navigate to SSH page from sidebar
- [ ] Add a new host with password auth
- [ ] Add a new host with key auth
- [ ] Edit an existing host
- [ ] Delete a host
- [ ] Connect to a host (requires real SSH server)
- [ ] Verify terminal output displays
- [ ] Type commands in terminal
- [ ] Open multiple tabs
- [ ] Switch between tabs (hidden tabs should preserve state)
- [ ] Close a tab (session disconnects)
- [ ] Resize window (terminal should re-fit)
- [ ] Navigate to Terminal Settings
- [ ] Change font size and verify it applies

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat(ssh): integration verification and polish"
```

---

## Summary of All Tasks

| # | Task | Files | Estimated Steps |
|---|------|-------|----------------|
| 1 | Rust dependencies | Cargo.toml | 3 |
| 2 | Frontend dependencies | package.json | 5 |
| 3 | Database module | db/mod.rs, models.rs, migrations.rs | 6 |
| 4 | Stronghold module | crypto/mod.rs, stronghold.rs | 5 |
| 5 | SSH handler | ssh/handler.rs | 5 |
| 6 | SSH session & manager | ssh/session.rs, manager.rs | 5 |
| 7 | Tauri commands | commands/*.rs | 7 |
| 8 | Wire up lib.rs + capabilities | lib.rs, default.json | 4 |
| 9 | SSH session context | ssh-session-provider.tsx, types/ssh.ts | 3 |
| 10 | xterm.js terminal | ssh-terminal.tsx | 2 |
| 11 | Host management UI | hosts/*.tsx | 6 |
| 12 | Tab bar & status bar | ssh-tab-bar.tsx, ssh-status-bar.tsx | 3 |
| 13 | SSH route layout | routes/ssh/route.tsx | 2 |
| 14 | Terminal settings | settings form + route | 3 |
| 15 | Navigation update | nav-main.tsx, app-sidebar.tsx | 4 |
| 16 | Export/import stubs | config_commands.rs | 4 |
| 17 | Integration verification | — | 6 |

**Total: 17 tasks, ~73 steps**

## Important Notes for Implementer

1. **API verification is critical.** The russh, tauri-plugin-sql, and tauri-plugin-stronghold APIs shown are structural guides. The exact method signatures WILL differ. Use `agent-browser` to check docs.rs and Tauri plugin docs before implementing each module.

2. **The tauri-plugin-sql approach for host CRUD may need adjustment.** The plugin is designed for frontend JS access, not direct Rust-side sqlx queries. You may need to either: (a) use the plugin's JS API for all DB operations, or (b) add sqlx as a direct dependency alongside the plugin. Decide based on what compiles.

3. **The Select component** in this project uses `@base-ui/react` Select, which has a different API than the standard shadcn Select. Check `apps/web/src/components/ui/select.tsx` and adapt all form code accordingly.

4. **TanStack Form adapter** — verify `@tanstack/zod-form-adapter` is the correct package name and install it if needed. The TanStack Form + Zod integration API may have changed.

5. **Compile and test frequently.** After each task, run `cargo check` (Rust) and `bun run build` (frontend) to catch issues early.
