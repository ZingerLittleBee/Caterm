use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;

use russh_sftp::client::SftpSession;
use tokio::sync::Mutex;

use super::session::SftpSessionEntry;
use super::transfer::{TransferQueue, TransferTaskInfo};

/// Manages all active SFTP sessions. Thread-safe via Arc<Mutex<...>>.
pub struct SftpSessionManager {
    sessions: Arc<Mutex<HashMap<String, SftpSessionEntry>>>,
    transfer_queue: Arc<Mutex<TransferQueue>>,
}

impl SftpSessionManager {
    /// Create a new empty SFTP session manager.
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            transfer_queue: Arc::new(Mutex::new(TransferQueue::new(3))),
        }
    }

    /// Add an SFTP session to the manager.
    pub async fn add_session(&self, session: SftpSessionEntry) {
        let id = session.id.clone();
        self.sessions.lock().await.insert(id, session);
    }

    /// Remove an SFTP session from the manager.
    pub async fn remove_session(&self, session_id: &str) -> Option<SftpSessionEntry> {
        self.sessions.lock().await.remove(session_id)
    }

    /// Execute a closure with a reference to a specific SFTP session.
    ///
    /// The closure receives an `&SftpSessionEntry` and must not hold the
    /// reference across await points. Returns an error if the session is not found.
    pub async fn with_session<F, R>(&self, session_id: &str, f: F) -> Result<R, String>
    where
        F: FnOnce(&SftpSessionEntry) -> R,
    {
        let sessions = self.sessions.lock().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| format!("SFTP session not found: {session_id}"))?;
        Ok(f(session))
    }

    /// Close and remove a specific SFTP session.
    pub async fn close(&self, session_id: &str) -> Result<(), String> {
        let session = self.sessions.lock().await.remove(session_id);
        if session.is_none() {
            return Err(format!("SFTP session not found: {session_id}"));
        }
        // SftpSessionEntry is dropped here, which closes the underlying channel.
        Ok(())
    }

    /// Close and remove all SFTP sessions.
    pub async fn close_all(&self) {
        let mut sessions = self.sessions.lock().await;
        sessions.clear();
    }

    /// Close all SFTP sessions that are associated with a given SSH session ID.
    pub async fn close_by_ssh_session(&self, ssh_session_id: &str) {
        let mut sessions = self.sessions.lock().await;
        sessions.retain(|_, entry| {
            entry
                .ssh_session_id
                .as_deref()
                .map_or(true, |id| id != ssh_session_id)
        });
    }

    /// Get a cloneable SFTP session handle by session ID.
    ///
    /// Returns an `Arc<SftpSession>` that can be used across await points
    /// without holding the session manager lock.
    pub async fn get_sftp(&self, session_id: &str) -> Result<Arc<SftpSession>, String> {
        let sessions = self.sessions.lock().await;
        let session = sessions
            .get(session_id)
            .ok_or_else(|| format!("SFTP session not found: {session_id}"))?;
        Ok(session.sftp_arc())
    }

    /// Reconnect an existing SFTP session by re-establishing the SSH connection.
    pub async fn reconnect(&self, session_id: &str) -> Result<(), String> {
        let mut sessions = self.sessions.lock().await;
        let session = sessions
            .get_mut(session_id)
            .ok_or_else(|| format!("SFTP session not found: {session_id}"))?;
        session.reconnect().await
    }

    /// Execute an async SFTP operation with automatic reconnection on failure.
    ///
    /// If the operation fails with a connection-related error, reconnects the
    /// session and retries the operation once. Non-connection errors (e.g. file
    /// not found, permission denied) are returned immediately without retry.
    pub async fn with_retry<F, Fut, T>(&self, session_id: &str, f: F) -> Result<T, String>
    where
        F: Fn(Arc<SftpSession>) -> Fut,
        Fut: Future<Output = Result<T, String>>,
    {
        let sftp = self.get_sftp(session_id).await?;
        match f(sftp).await {
            Ok(val) => Ok(val),
            Err(e) if Self::is_retryable(&e) => {
                match self.reconnect(session_id).await {
                    Ok(()) => {
                        let sftp = self.get_sftp(session_id).await?;
                        f(sftp).await
                    }
                    Err(_) => Err(e), // Return original error if reconnect fails
                }
            }
            Err(e) => Err(e),
        }
    }

    /// Check if an error message indicates a broken connection that is worth retrying.
    fn is_retryable(err: &str) -> bool {
        let lower = err.to_lowercase();
        lower.contains("session closed")
            || lower.contains("channel closed")
            || lower.contains("connection reset")
            || lower.contains("broken pipe")
            || lower.contains("eof")
    }

    /// List all transfer tasks as serializable DTOs.
    pub async fn transfer_queue_list(&self) -> Vec<TransferTaskInfo> {
        self.transfer_queue.lock().await.list()
    }

    /// Cancel a transfer task by ID. Returns true if found and removed.
    pub async fn transfer_queue_cancel(&self, transfer_id: &str) -> bool {
        self.transfer_queue.lock().await.cancel(transfer_id)
    }
}

impl Default for SftpSessionManager {
    fn default() -> Self {
        Self::new()
    }
}
