import { File, Folder, Link } from 'lucide-react'
import { useCallback, useRef, useState } from 'react'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import type { FileEntry } from '@/types/sftp'

interface SftpFileTableProps {
  entries: FileEntry[]
  onContextMenu?: (entry: FileEntry, event: React.MouseEvent) => void
  onOpen: (entry: FileEntry) => void
  onSelect: (entries: FileEntry[]) => void
}

function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

function formatDate(timestamp: number | null): string {
  if (timestamp === null) {
    return '-'
  }
  const date = new Date(timestamp * 1000)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24))

  if (diffDays === 0) {
    return date.toLocaleTimeString(undefined, {
      hour: '2-digit',
      minute: '2-digit'
    })
  }
  if (diffDays < 7) {
    return `${diffDays}d ago`
  }
  return date.toLocaleDateString(undefined, {
    day: 'numeric',
    month: 'short',
    year: date.getFullYear() !== now.getFullYear() ? 'numeric' : undefined
  })
}

function FileIcon({ entry }: { entry: FileEntry }) {
  if (entry.isSymlink) {
    return <Link className="h-4 w-4 shrink-0 text-blue-400" />
  }
  if (entry.isDir) {
    return <Folder className="h-4 w-4 shrink-0 text-yellow-500" />
  }
  return <File className="h-4 w-4 shrink-0 text-muted-foreground" />
}

export function SftpFileTable({ entries, onContextMenu, onOpen, onSelect }: SftpFileTableProps) {
  const [selectedPaths, setSelectedPaths] = useState<Set<string>>(new Set())
  const lastClickedIndex = useRef<number>(-1)

  const handleRowClick = useCallback(
    (entry: FileEntry, index: number, event: React.MouseEvent) => {
      let nextSelected: Set<string>

      if (event.metaKey || event.ctrlKey) {
        // Toggle selection
        nextSelected = new Set(selectedPaths)
        if (nextSelected.has(entry.path)) {
          nextSelected.delete(entry.path)
        } else {
          nextSelected.add(entry.path)
        }
      } else if (event.shiftKey && lastClickedIndex.current >= 0) {
        // Range selection
        const start = Math.min(lastClickedIndex.current, index)
        const end = Math.max(lastClickedIndex.current, index)
        nextSelected = new Set(selectedPaths)
        for (let i = start; i <= end; i++) {
          nextSelected.add(entries[i].path)
        }
      } else {
        // Single selection
        nextSelected = new Set([entry.path])
      }

      lastClickedIndex.current = index
      setSelectedPaths(nextSelected)
      onSelect(entries.filter((e) => nextSelected.has(e.path)))
    },
    [entries, selectedPaths, onSelect]
  )

  const handleRowDoubleClick = useCallback(
    (entry: FileEntry) => {
      onOpen(entry)
    },
    [onOpen]
  )

  const handleRowContextMenu = useCallback(
    (entry: FileEntry, index: number, event: React.MouseEvent) => {
      if (!onContextMenu) {
        return
      }
      event.preventDefault()
      if (!selectedPaths.has(entry.path)) {
        const nextSelected = new Set([entry.path])
        lastClickedIndex.current = index
        setSelectedPaths(nextSelected)
        onSelect([entry])
      }
      onContextMenu(entry, event)
    },
    [onContextMenu, selectedPaths, onSelect]
  )

  if (entries.length === 0) {
    return <div className="flex h-32 items-center justify-center text-muted-foreground text-sm">Empty directory</div>
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="min-w-[200px]">Name</TableHead>
          <TableHead className="w-24">Size</TableHead>
          <TableHead className="w-28">Permissions</TableHead>
          <TableHead className="w-28">Modified</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {entries.map((entry, index) => (
          <TableRow
            className={`cursor-pointer select-none ${selectedPaths.has(entry.path) ? 'bg-accent' : ''}`}
            data-state={selectedPaths.has(entry.path) ? 'selected' : undefined}
            key={entry.path}
            onClick={(e) => handleRowClick(entry, index, e)}
            onContextMenu={(e) => handleRowContextMenu(entry, index, e)}
            onDoubleClick={() => handleRowDoubleClick(entry)}
          >
            <TableCell>
              <div className="flex items-center gap-2">
                <FileIcon entry={entry} />
                <span className="truncate">{entry.name}</span>
                {entry.isSymlink && entry.linkTarget && (
                  <span className="truncate text-muted-foreground text-xs">-&gt; {entry.linkTarget}</span>
                )}
              </div>
            </TableCell>
            <TableCell className="text-muted-foreground">{entry.isDir ? '-' : formatSize(entry.size)}</TableCell>
            <TableCell className="font-mono text-muted-foreground text-xs">{entry.permissionsStr}</TableCell>
            <TableCell className="text-muted-foreground">{formatDate(entry.modifiedAt)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}
