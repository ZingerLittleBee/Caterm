// ---------------------------------------------------------------------------
// Shared file-system types used by both local and remote (SFTP) operations.
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
