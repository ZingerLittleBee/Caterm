import { invoke } from '@tauri-apps/api/core'
import type { FileEntry, FileStat } from '@/types/fs'

export interface FileOperations {
  chmod(path: string, mode: number): Promise<void>
  listDir(path: string): Promise<FileEntry[]>
  mkdir(path: string): Promise<void>
  readFile(path: string, maxSize?: number): Promise<string>
  remove(path: string): Promise<void>
  rename(oldPath: string, newPath: string): Promise<void>
  search(path: string, pattern: string): Promise<FileEntry[]>
  stat(path: string): Promise<FileStat>
  writeFile(path: string, content: string): Promise<void>
}

export function createLocalFileOps(): FileOperations {
  return {
    chmod: (path, mode) => invoke('local_fs_chmod', { path, mode }),
    listDir: (path) => invoke<FileEntry[]>('local_fs_list_dir', { path }),
    mkdir: (path) => invoke('local_fs_mkdir', { path }),
    readFile: (path, maxSize) => invoke<string>('local_fs_read_file', { path, maxSize: maxSize ?? null }),
    remove: (path) => invoke('local_fs_remove', { path }),
    rename: (oldPath, newPath) => invoke('local_fs_rename', { oldPath, newPath }),
    search: (path, pattern) => invoke<FileEntry[]>('local_fs_search', { path, pattern }),
    stat: (path) => invoke<FileStat>('local_fs_stat', { path }),
    writeFile: (path, content) => invoke('local_fs_write_file', { path, content })
  }
}

export function createSftpFileOps(
  sessionId: string,
  sftpOps: {
    chmod: (sessionId: string, path: string, mode: number) => Promise<void>
    listDir: (sessionId: string, path: string) => Promise<FileEntry[]>
    mkdir: (sessionId: string, path: string) => Promise<void>
    readFile: (sessionId: string, path: string, maxSize?: number) => Promise<string>
    remove: (sessionId: string, path: string) => Promise<void>
    rename: (sessionId: string, oldPath: string, newPath: string) => Promise<void>
    rmdir: (sessionId: string, path: string) => Promise<void>
    search: (sessionId: string, path: string, pattern: string) => Promise<FileEntry[]>
    stat: (sessionId: string, path: string) => Promise<FileStat>
    writeFile: (sessionId: string, path: string, content: string) => Promise<void>
  }
): FileOperations {
  return {
    chmod: (path, mode) => sftpOps.chmod(sessionId, path, mode),
    listDir: (path) => sftpOps.listDir(sessionId, path),
    mkdir: (path) => sftpOps.mkdir(sessionId, path),
    readFile: (path, maxSize) => sftpOps.readFile(sessionId, path, maxSize),
    remove: async (path) => {
      const s = await sftpOps.stat(sessionId, path)
      if (s.isDir) {
        await sftpOps.rmdir(sessionId, path)
      } else {
        await sftpOps.remove(sessionId, path)
      }
    },
    rename: (oldPath, newPath) => sftpOps.rename(sessionId, oldPath, newPath),
    search: (path, pattern) => sftpOps.search(sessionId, path, pattern),
    stat: (path) => sftpOps.stat(sessionId, path),
    writeFile: (path, content) => sftpOps.writeFile(sessionId, path, content)
  }
}

export function getHomeDir(): Promise<string> {
  return invoke<string>('local_fs_get_home_dir')
}

export async function openInSystem(path: string): Promise<void> {
  await invoke('local_fs_open_in_system', { path })
}
