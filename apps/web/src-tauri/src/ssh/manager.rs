use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::Mutex;

use super::session::SshSession;

/// Manages all active SSH sessions. Thread-safe via Arc<Mutex<...>>.
pub struct SshSessionManager {
    sessions: Arc<Mutex<HashMap<String, SshSession>>>,
}

impl SshSessionManager {
    /// Create a new empty session manager.
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Add a session to the manager and start its reader.
    pub async fn add_session(&self, session: SshSession) {
        session.spawn_reader();
        let id = session.id.clone();
        self.sessions.lock().await.insert(id, session);
    }

    /// Write data to a specific session.
    ///
    /// Clones the command sender and releases the lock before awaiting
    /// to avoid holding the Mutex across an await point.
    pub async fn write(&self, session_id: &str, data: &[u8]) -> Result<(), String> {
        let tx = {
            let sessions = self.sessions.lock().await;
            let session = sessions
                .get(session_id)
                .ok_or_else(|| format!("Session not found: {session_id}"))?;
            session.command_sender()
        };
        SshSession::write_with(tx, data).await
    }

    /// Resize the terminal for a specific session.
    ///
    /// Clones the command sender and releases the lock before awaiting
    /// to avoid holding the Mutex across an await point.
    pub async fn resize(&self, session_id: &str, cols: u32, rows: u32) -> Result<(), String> {
        let tx = {
            let sessions = self.sessions.lock().await;
            let session = sessions
                .get(session_id)
                .ok_or_else(|| format!("Session not found: {session_id}"))?;
            session.command_sender()
        };
        SshSession::resize_with(tx, cols, rows).await
    }

    /// Disconnect a specific session and remove it from the manager.
    ///
    /// Removes the session from the map and releases the lock before
    /// awaiting the close command, consistent with write/resize.
    pub async fn disconnect(&self, session_id: &str) -> Result<(), String> {
        let session = {
            let mut sessions = self.sessions.lock().await;
            sessions.remove(session_id)
        };
        if let Some(session) = session {
            session.close().await?;
        }
        Ok(())
    }

    /// Disconnect all active sessions.
    ///
    /// Drains all sessions while holding the lock, then closes each
    /// one after releasing the lock to avoid blocking other operations.
    #[allow(dead_code)]
    pub async fn disconnect_all(&self) {
        let drained: Vec<SshSession> = {
            let mut sessions = self.sessions.lock().await;
            sessions.drain().map(|(_, s)| s).collect()
        };
        for session in drained {
            let _ = session.close().await;
        }
    }
}

impl Default for SshSessionManager {
    fn default() -> Self {
        Self::new()
    }
}
