use std::collections::VecDeque;
use std::path::PathBuf;

use serde::Serialize;

/// The direction of a file transfer.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TransferKind {
    Upload,
    Download,
}

/// The current status of a file transfer.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TransferStatus {
    Pending,
    Active,
    Paused,
    Completed,
    Failed,
}

/// A file transfer task in the queue.
#[allow(dead_code)]
pub struct TransferTask {
    /// Unique transfer ID.
    pub id: String,
    /// The SFTP session this transfer belongs to.
    pub sftp_session_id: String,
    /// Upload or download.
    pub kind: TransferKind,
    /// Remote file path on the server.
    pub remote_path: String,
    /// Local file path on the client.
    pub local_path: PathBuf,
    /// Total file size in bytes (if known).
    pub total_bytes: Option<u64>,
    /// Bytes transferred so far.
    pub transferred_bytes: u64,
    /// Current status of the transfer.
    pub status: TransferStatus,
}

/// Serializable DTO for exposing transfer info to the frontend.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferTaskInfo {
    pub id: String,
    pub sftp_session_id: String,
    pub kind: TransferKind,
    pub remote_path: String,
    pub local_path: String,
    pub total_bytes: Option<u64>,
    pub transferred_bytes: u64,
    pub status: TransferStatus,
}

impl From<&TransferTask> for TransferTaskInfo {
    fn from(task: &TransferTask) -> Self {
        Self {
            id: task.id.clone(),
            sftp_session_id: task.sftp_session_id.clone(),
            kind: task.kind.clone(),
            remote_path: task.remote_path.clone(),
            local_path: task.local_path.to_string_lossy().into_owned(),
            total_bytes: task.total_bytes,
            transferred_bytes: task.transferred_bytes,
            status: task.status.clone(),
        }
    }
}

/// Queue for managing concurrent file transfers.
#[allow(dead_code)]
pub struct TransferQueue {
    /// Pending and active transfer tasks.
    tasks: VecDeque<TransferTask>,
    /// Number of currently active transfers.
    active_count: usize,
    /// Maximum number of concurrent transfers.
    max_concurrent: usize,
}

impl TransferQueue {
    /// Create a new transfer queue with the given concurrency limit.
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            tasks: VecDeque::new(),
            active_count: 0,
            max_concurrent,
        }
    }

    /// List all transfer tasks as serializable DTOs.
    #[allow(dead_code)]
    pub fn list(&self) -> Vec<TransferTaskInfo> {
        self.tasks.iter().map(TransferTaskInfo::from).collect()
    }

    /// Cancel a transfer task by ID. Returns true if the task was found and removed.
    #[allow(dead_code)]
    pub fn cancel(&mut self, transfer_id: &str) -> bool {
        if let Some(pos) = self.tasks.iter().position(|t| t.id == transfer_id) {
            let task = &self.tasks[pos];
            if task.status == TransferStatus::Active {
                self.active_count = self.active_count.saturating_sub(1);
            }
            self.tasks.remove(pos);
            true
        } else {
            false
        }
    }
}
