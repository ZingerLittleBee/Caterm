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
    pub async fn disconnect(&self, session_id: &str) -> Result<(), String> {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.remove(session_id) {
            session.close().await?;
        }
        Ok(())
    }

    /// Disconnect all active sessions.
    #[allow(dead_code)]
    pub async fn disconnect_all(&self) {
        let mut sessions = self.sessions.lock().await;
        for (_, session) in sessions.drain() {
            let _ = session.close().await;
        }
    }
}

impl Default for SshSessionManager {
    fn default() -> Self {
        Self::new()
    }
}
