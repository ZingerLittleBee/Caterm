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
// File types — mirrors Rust structs in sftp_commands.rs
// ---------------------------------------------------------------------------

export interface FileEntry {
  isDir: boolean
  isSymlink: boolean
  linkTarget: string | null
  modifiedAt: number | null
  name: string
  path: string
  permissions: number
  permissionsStr: string
  size: number
}

export interface FileStat {
  accessedAt: number | null
  gid: number | null
  isDir: boolean
  isSymlink: boolean
  modifiedAt: number | null
  permissions: number
  permissionsStr: string
  size: number
  uid: number | null
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
