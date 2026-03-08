// Re-export shared file system types for backward compatibility.
export type { FileEntry, FileStat } from './fs'

// ---------------------------------------------------------------------------
// SFTP session types (frontend-only, not backed by Rust structs)
// ---------------------------------------------------------------------------

export type SftpSessionStatus = 'connecting' | 'connected' | 'disconnected' | 'error'

export interface SftpSessionInfo {
  hostId: string
  hostName: string
  id: string
  sshSessionId: string | null
  status: SftpSessionStatus
}

// ---------------------------------------------------------------------------
// Transfer types — mirrors Rust structs in sftp/transfer.rs
// ---------------------------------------------------------------------------

export type TransferKind = 'upload' | 'download'

export type TransferStatus = 'pending' | 'active' | 'paused' | 'completed' | 'failed'

export interface TransferTaskInfo {
  id: string
  kind: TransferKind
  localPath: string
  remotePath: string
  sftpSessionId: string
  status: TransferStatus
  totalBytes: number | null
  transferredBytes: number
}

// ---------------------------------------------------------------------------
// Bookmark types (frontend-only)
// ---------------------------------------------------------------------------

export interface SftpBookmark {
  hostId: string
  id: string
  label: string
  remotePath: string
}
