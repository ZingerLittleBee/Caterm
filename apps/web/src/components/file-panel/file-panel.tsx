import { Dialog } from '@base-ui/react/dialog'
import { ChevronLeft, ChevronRight, Loader2 } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ScrollArea } from '@/components/ui/scroll-area'
import type { FileOperations } from '@/lib/file-operations'
import type { FileEntry } from '@/types/fs'
import { BookmarkDialog } from './dialogs/bookmark-dialog'
import { ChmodDialog } from './dialogs/chmod-dialog'
import { FileEditorDialog } from './dialogs/file-editor-dialog'
import { SearchDialog } from './dialogs/search-dialog'
import { FileBreadcrumb } from './file-breadcrumb'
import { FileContextMenu } from './file-context-menu'
import { FileTable } from './file-table'
import { FileToolbar } from './file-toolbar'

interface FilePanelProps {
  extraContextMenuItems?: {
    onOpenInSystem?: (entry: FileEntry) => void
  }
  hostId?: string
  initialPath: string
  onDrop?: (entries: FileEntry[], targetPath: string) => void
  onPathChange?: (path: string) => void
  onTransfer?: (entries: FileEntry[]) => void
  operations: FileOperations
  refreshTrigger?: number
  source: 'local' | 'remote'
  title?: string
}

export function FilePanel({
  extraContextMenuItems,
  hostId,
  initialPath,
  onTransfer,
  onDrop,
  onPathChange,
  operations,
  refreshTrigger,
  source,
  title
}: FilePanelProps) {
  const [currentPath, setCurrentPath] = useState(initialPath)
  const [entries, setEntries] = useState<FileEntry[]>([])
  const [selectedEntries, setSelectedEntries] = useState<FileEntry[]>([])
  const [loading, setLoading] = useState(false)
  const [newFolderDialogOpen, setNewFolderDialogOpen] = useState(false)
  const [newFolderName, setNewFolderName] = useState('')
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false)
  const newFolderInputRef = useRef<HTMLInputElement>(null)

  // Navigation history
  const historyBackRef = useRef<string[]>([])
  const historyForwardRef = useRef<string[]>([])
  const [canGoBack, setCanGoBack] = useState(false)
  const [canGoForward, setCanGoForward] = useState(false)

  const [dragOver, setDragOver] = useState(false)

  // Context menu state
  const [contextEntry, setContextEntry] = useState<FileEntry | null>(null)
  const [contextMenuPos, setContextMenuPos] = useState<{
    x: number
    y: number
  } | null>(null)

  // Dialog states
  const [searchOpen, setSearchOpen] = useState(false)
  const [bookmarksOpen, setBookmarksOpen] = useState(false)
  const [editorEntry, setEditorEntry] = useState<FileEntry | null>(null)
  const [editorReadOnly, setEditorReadOnly] = useState(true)
  const [chmodEntry, setChmodEntry] = useState<FileEntry | null>(null)
  const [renameDialogOpen, setRenameDialogOpen] = useState(false)
  const [renameEntry, setRenameEntry] = useState<FileEntry | null>(null)
  const [renameName, setRenameName] = useState('')

  const loadDirectory = useCallback(
    async (path: string) => {
      setLoading(true)
      try {
        const result = await operations.listDir(path)
        setEntries(result)
        setCurrentPath(path)
        setSelectedEntries([])
        onPathChange?.(path)
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        toast.error('Failed to list directory', { description: message })
      } finally {
        setLoading(false)
      }
    },
    [operations, onPathChange]
  )

  const navigateTo = useCallback(
    (path: string, pushHistory = true) => {
      if (pushHistory && currentPath !== path) {
        historyBackRef.current.push(currentPath)
        historyForwardRef.current = []
        setCanGoBack(true)
        setCanGoForward(false)
      }
      loadDirectory(path)
    },
    [loadDirectory, currentPath]
  )

  const handleGoBack = useCallback(() => {
    const prev = historyBackRef.current.pop()
    if (prev != null) {
      historyForwardRef.current.push(currentPath)
      setCanGoBack(historyBackRef.current.length > 0)
      setCanGoForward(true)
      loadDirectory(prev)
    }
  }, [loadDirectory, currentPath])

  const handleGoForward = useCallback(() => {
    const next = historyForwardRef.current.pop()
    if (next != null) {
      historyBackRef.current.push(currentPath)
      setCanGoBack(true)
      setCanGoForward(historyForwardRef.current.length > 0)
      loadDirectory(next)
    }
  }, [loadDirectory, currentPath])

  useEffect(() => {
    loadDirectory(initialPath)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only load on mount
  }, [])

  useEffect(() => {
    if (refreshTrigger) {
      loadDirectory(currentPath)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- refresh when trigger changes
  }, [refreshTrigger])

  const handleOpen = useCallback(
    (entry: FileEntry) => {
      if (entry.isDir) {
        navigateTo(entry.path)
      }
    },
    [navigateTo]
  )

  const handleNavigate = useCallback(
    (path: string) => {
      navigateTo(path)
    },
    [navigateTo]
  )

  const handleRefresh = useCallback(() => {
    loadDirectory(currentPath)
  }, [loadDirectory, currentPath])

  const handleNewFolderOpen = useCallback(() => {
    setNewFolderName('')
    setNewFolderDialogOpen(true)
  }, [])

  const handleNewFolderConfirm = useCallback(async () => {
    if (!newFolderName.trim()) {
      return
    }
    const name = newFolderName.trim()
    const newPath = currentPath === '/' ? `/${name}` : `${currentPath}/${name}`
    setNewFolderDialogOpen(false)
    try {
      await operations.mkdir(newPath)
      await loadDirectory(currentPath)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      toast.error('Failed to create folder', { description: message })
    }
  }, [newFolderName, currentPath, operations, loadDirectory])

  const handleDeleteOpen = useCallback(() => {
    if (selectedEntries.length === 0) {
      return
    }
    setDeleteDialogOpen(true)
  }, [selectedEntries.length])

  const handleDeleteConfirm = useCallback(async () => {
    if (selectedEntries.length === 0) {
      return
    }
    setDeleteDialogOpen(false)
    try {
      for (const entry of selectedEntries) {
        await operations.remove(entry.path)
      }
      await loadDirectory(currentPath)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      toast.error('Failed to delete', { description: message })
    }
  }, [selectedEntries, currentPath, operations, loadDirectory])

  // Context menu handlers
  const handleContextMenu = useCallback((entry: FileEntry, event: React.MouseEvent) => {
    setContextEntry(entry)
    setContextMenuPos({ x: event.clientX, y: event.clientY })
  }, [])

  const handleContextOpen = useCallback(
    (entry: FileEntry) => {
      handleOpen(entry)
    },
    [handleOpen]
  )

  const handleContextPreview = useCallback((entry: FileEntry) => {
    if (!entry.isDir) {
      setEditorEntry(entry)
      setEditorReadOnly(true)
    }
  }, [])

  const handleContextEdit = useCallback((entry: FileEntry) => {
    if (!entry.isDir) {
      setEditorEntry(entry)
      setEditorReadOnly(false)
    }
  }, [])

  const handleContextTransfer = useCallback(
    (entry: FileEntry) => {
      if (onTransfer) {
        onTransfer([entry])
      }
    },
    [onTransfer]
  )

  const handleContextRename = useCallback((entry: FileEntry) => {
    setRenameEntry(entry)
    setRenameName(entry.name)
    setRenameDialogOpen(true)
  }, [])

  const handleRenameConfirm = useCallback(async () => {
    if (!(renameEntry && renameName.trim())) {
      return
    }
    const parentPath = renameEntry.path.substring(0, renameEntry.path.lastIndexOf('/'))
    const newPath = parentPath ? `${parentPath}/${renameName.trim()}` : `/${renameName.trim()}`
    setRenameDialogOpen(false)
    try {
      await operations.rename(renameEntry.path, newPath)
      await loadDirectory(currentPath)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      toast.error('Failed to rename', { description: message })
    }
  }, [renameEntry, renameName, operations, loadDirectory, currentPath])

  const handleContextCopyPath = useCallback((entry: FileEntry) => {
    navigator.clipboard.writeText(entry.path)
    toast.success('Path copied to clipboard')
  }, [])

  const handleContextPermissions = useCallback((entry: FileEntry) => {
    setChmodEntry(entry)
  }, [])

  const handleContextDelete = useCallback((entry: FileEntry) => {
    setSelectedEntries([entry])
    setDeleteDialogOpen(true)
  }, [])

  return (
    // biome-ignore lint/a11y/noNoninteractiveElementInteractions: drag-and-drop zone requires event handlers on container div
    <div
      aria-label={`${source} file panel drop zone`}
      className={`flex h-full flex-col ${dragOver ? 'ring-2 ring-primary ring-inset' : ''}`}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target || !e.currentTarget.contains(e.relatedTarget as Node)) {
          setDragOver(false)
        }
      }}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes('application/x-caterm-files')) {
          e.preventDefault()
          e.dataTransfer.dropEffect = 'copy'
          setDragOver(true)
        }
      }}
      onDrop={(e) => {
        e.preventDefault()
        setDragOver(false)
        const raw = e.dataTransfer.getData('application/x-caterm-files')
        if (raw && onDrop) {
          try {
            const data = JSON.parse(raw) as { source: string; entries: FileEntry[] }
            if (data.source !== source) {
              onDrop(data.entries, currentPath)
            }
          } catch {
            // ignore invalid data
          }
        }
      }}
      role="region"
    >
      {/* Row 1: Title + Toolbar */}
      {title && (
        <div className="flex items-center gap-2 border-b px-3 py-1.5">
          <h2 className="min-w-0 flex-1 font-medium text-sm">{title}</h2>
          <FileToolbar
            onBookmarks={() => setBookmarksOpen(true)}
            onDelete={handleDeleteOpen}
            onNewFolder={handleNewFolderOpen}
            onOpenInSystem={
              source === 'local' && extraContextMenuItems?.onOpenInSystem
                ? () =>
                    extraContextMenuItems.onOpenInSystem?.({
                      isDir: true,
                      isSymlink: false,
                      linkTarget: null,
                      modifiedAt: null,
                      name: currentPath.split('/').pop() ?? '/',
                      path: currentPath,
                      permissions: 0,
                      permissionsStr: '',
                      size: 0
                    })
                : undefined
            }
            onRefresh={handleRefresh}
            onSearch={() => setSearchOpen(true)}
            onTransfer={onTransfer && selectedEntries.length > 0 ? () => onTransfer(selectedEntries) : undefined}
          />
        </div>
      )}

      {/* Row 2: Back/Forward + Breadcrumb */}
      <div className="flex items-center gap-0.5 border-b px-1 py-0.5">
        <Button className="h-7 w-7" disabled={!canGoBack} onClick={handleGoBack} size="icon" variant="ghost">
          <ChevronLeft className="h-4 w-4" />
          <span className="sr-only">Back</span>
        </Button>
        <Button className="h-7 w-7" disabled={!canGoForward} onClick={handleGoForward} size="icon" variant="ghost">
          <ChevronRight className="h-4 w-4" />
          <span className="sr-only">Forward</span>
        </Button>
        <div className="min-w-0 flex-1">
          <FileBreadcrumb onNavigate={handleNavigate} path={currentPath} />
        </div>
      </div>

      <ScrollArea className="min-h-0 flex-1">
        {loading ? (
          <div className="flex h-32 items-center justify-center">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        ) : (
          <>
            <FileTable
              entries={entries}
              onContextMenu={handleContextMenu}
              onOpen={handleOpen}
              onSelect={setSelectedEntries}
              source={source}
            />
            <FileContextMenu
              entry={contextEntry}
              onClose={() => {
                setContextEntry(null)
                setContextMenuPos(null)
              }}
              onCopyPath={handleContextCopyPath}
              onDelete={handleContextDelete}
              onEdit={handleContextEdit}
              onOpen={handleContextOpen}
              onOpenInSystem={extraContextMenuItems?.onOpenInSystem}
              onPermissions={handleContextPermissions}
              onPreview={handleContextPreview}
              onRename={handleContextRename}
              onTransfer={onTransfer ? handleContextTransfer : undefined}
              position={contextMenuPos}
            />
          </>
        )}
      </ScrollArea>

      {/* New Folder Dialog */}
      <Dialog.Root onOpenChange={setNewFolderDialogOpen} open={newFolderDialogOpen}>
        <Dialog.Portal>
          <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
          <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
            <Dialog.Title className="font-medium text-base">New Folder</Dialog.Title>
            <div className="mt-4">
              <Input
                autoFocus
                onChange={(e) => setNewFolderName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    handleNewFolderConfirm()
                  }
                }}
                placeholder="Folder name"
                ref={newFolderInputRef}
                value={newFolderName}
              />
            </div>
            <div className="mt-4 flex justify-end gap-2">
              <Dialog.Close
                render={
                  <Button onClick={() => setNewFolderDialogOpen(false)} variant="outline">
                    Cancel
                  </Button>
                }
              />
              <Button disabled={!newFolderName.trim()} onClick={handleNewFolderConfirm}>
                Create
              </Button>
            </div>
          </Dialog.Popup>
        </Dialog.Portal>
      </Dialog.Root>

      {/* Delete Confirmation Dialog */}
      <Dialog.Root onOpenChange={setDeleteDialogOpen} open={deleteDialogOpen}>
        <Dialog.Portal>
          <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
          <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
            <Dialog.Title className="font-medium text-base">Confirm Delete</Dialog.Title>
            <Dialog.Description className="mt-2 text-muted-foreground text-sm">
              Delete {selectedEntries.length} item(s)? This action cannot be undone.
            </Dialog.Description>
            <div className="mt-4 flex justify-end gap-2">
              <Dialog.Close
                render={
                  <Button onClick={() => setDeleteDialogOpen(false)} variant="outline">
                    Cancel
                  </Button>
                }
              />
              <Button onClick={handleDeleteConfirm} variant="destructive">
                Delete
              </Button>
            </div>
          </Dialog.Popup>
        </Dialog.Portal>
      </Dialog.Root>

      {/* Rename Dialog */}
      <Dialog.Root onOpenChange={setRenameDialogOpen} open={renameDialogOpen}>
        <Dialog.Portal>
          <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
          <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
            <Dialog.Title className="font-medium text-base">Rename</Dialog.Title>
            <div className="mt-4">
              <Input
                autoFocus
                onChange={(e) => setRenameName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    handleRenameConfirm()
                  }
                }}
                placeholder="New name"
                value={renameName}
              />
            </div>
            <div className="mt-4 flex justify-end gap-2">
              <Dialog.Close
                render={
                  <Button onClick={() => setRenameDialogOpen(false)} variant="outline">
                    Cancel
                  </Button>
                }
              />
              <Button disabled={!renameName.trim()} onClick={handleRenameConfirm}>
                Rename
              </Button>
            </div>
          </Dialog.Popup>
        </Dialog.Portal>
      </Dialog.Root>

      {/* Search Dialog */}
      <SearchDialog
        basePath={currentPath}
        onClose={() => setSearchOpen(false)}
        onNavigate={handleNavigate}
        open={searchOpen}
        search={operations.search}
      />

      {/* Bookmarks Dialog */}
      <BookmarkDialog
        currentPath={currentPath}
        hostId={hostId}
        onClose={() => setBookmarksOpen(false)}
        onNavigate={handleNavigate}
        open={bookmarksOpen}
        source={source}
      />

      {/* File Editor/Preview Dialog */}
      {editorEntry && (
        <FileEditorDialog
          onClose={() => setEditorEntry(null)}
          onSaved={handleRefresh}
          open={!!editorEntry}
          path={editorEntry.path}
          readFile={operations.readFile}
          readOnly={editorReadOnly}
          writeFile={operations.writeFile}
        />
      )}

      {/* Chmod Dialog */}
      {chmodEntry && (
        <ChmodDialog
          chmod={operations.chmod}
          currentPermissions={chmodEntry.permissions}
          onClose={() => {
            setChmodEntry(null)
            handleRefresh()
          }}
          open={!!chmodEntry}
          path={chmodEntry.path}
        />
      )}
    </div>
  )
}
