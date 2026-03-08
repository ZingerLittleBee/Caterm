import { Dialog } from '@base-ui/react/dialog'
import { useQuery } from '@tanstack/react-query'
import { Bookmark, FolderOpen, Loader2, Plus, Trash2 } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ScrollArea } from '@/components/ui/scroll-area'
import { getHomeDir } from '@/lib/file-operations'
import { client, orpc, queryClient } from '@/lib/orpc'

interface LocalBookmark {
  id: string
  label: string
  path: string
}

const LOCAL_BOOKMARKS_KEY = 'caterm:local-bookmarks'

function buildDefaultLocalBookmarks(homeDir: string): LocalBookmark[] {
  return [
    { id: 'preset-home', label: 'Home', path: homeDir },
    { id: 'preset-desktop', label: 'Desktop', path: `${homeDir}/Desktop` },
    { id: 'preset-downloads', label: 'Downloads', path: `${homeDir}/Downloads` },
    { id: 'preset-documents', label: 'Documents', path: `${homeDir}/Documents` },
  ]
}

function getStoredLocalBookmarks(): LocalBookmark[] | null {
  try {
    const stored = localStorage.getItem(LOCAL_BOOKMARKS_KEY)
    if (stored) {
      return JSON.parse(stored) as LocalBookmark[]
    }
  } catch {
    // Ignore parse errors
  }
  return null
}

function saveLocalBookmarks(bookmarks: LocalBookmark[]): void {
  localStorage.setItem(LOCAL_BOOKMARKS_KEY, JSON.stringify(bookmarks))
}

interface BookmarkDialogProps {
  currentPath: string
  hostId?: string
  onClose: () => void
  onNavigate: (path: string) => void
  open: boolean
  source: 'local' | 'remote'
}

export function BookmarkDialog({ currentPath, hostId, onClose, onNavigate, open, source }: BookmarkDialogProps) {
  const [addLabel, setAddLabel] = useState('')
  const [adding, setAdding] = useState(false)
  const [localBookmarks, setLocalBookmarksState] = useState<LocalBookmark[]>([])

  // Load local bookmarks when dialog opens, resolving home dir for defaults
  useEffect(() => {
    if (open && source === 'local') {
      const stored = getStoredLocalBookmarks()
      if (stored) {
        setLocalBookmarksState(stored)
      } else {
        getHomeDir()
          .then((home) => setLocalBookmarksState(buildDefaultLocalBookmarks(home)))
          .catch(() => setLocalBookmarksState([]))
      }
    }
  }, [open, source])

  // Remote bookmarks query (only used when source === 'remote')
  const bookmarksQuery = useQuery({
    ...orpc.sftpBookmark.list.queryOptions({
      input: { hostId }
    }),
    enabled: source === 'remote'
  })

  const remoteBookmarks = bookmarksQuery.data ?? []

  const handleAddRemote = useCallback(async () => {
    if (!(hostId && addLabel.trim())) {
      return
    }
    setAdding(true)
    try {
      await client.sftpBookmark.create({
        hostId,
        label: addLabel.trim(),
        remotePath: currentPath
      })
      setAddLabel('')
      queryClient.invalidateQueries({
        queryKey: orpc.sftpBookmark.list.queryOptions({ input: { hostId } }).queryKey
      })
      toast.success('Bookmark added')
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      toast.error('Failed to add bookmark', { description: message })
    } finally {
      setAdding(false)
    }
  }, [hostId, addLabel, currentPath])

  const handleAddLocal = useCallback(() => {
    if (!addLabel.trim()) {
      return
    }
    const newBookmark: LocalBookmark = {
      id: crypto.randomUUID(),
      label: addLabel.trim(),
      path: currentPath
    }
    const updated = [...localBookmarks, newBookmark]
    saveLocalBookmarks(updated)
    setLocalBookmarksState(updated)
    setAddLabel('')
    toast.success('Bookmark added')
  }, [addLabel, currentPath, localBookmarks])

  const handleAdd = useCallback(() => {
    if (source === 'remote') {
      handleAddRemote()
    } else {
      handleAddLocal()
    }
  }, [source, handleAddRemote, handleAddLocal])

  const handleDeleteRemote = useCallback(
    async (id: string) => {
      try {
        await client.sftpBookmark.delete({ id })
        queryClient.invalidateQueries({
          queryKey: orpc.sftpBookmark.list.queryOptions({
            input: { hostId }
          }).queryKey
        })
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        toast.error('Failed to delete bookmark', { description: message })
      }
    },
    [hostId]
  )

  const handleDeleteLocal = useCallback(
    (id: string) => {
      const updated = localBookmarks.filter((bm) => bm.id !== id)
      saveLocalBookmarks(updated)
      setLocalBookmarksState(updated)
    },
    [localBookmarks]
  )

  const handleDelete = useCallback(
    (id: string) => {
      if (source === 'remote') {
        handleDeleteRemote(id)
      } else {
        handleDeleteLocal(id)
      }
    },
    [source, handleDeleteRemote, handleDeleteLocal]
  )

  const handleBookmarkClick = useCallback(
    (bookmarkPath: string) => {
      onNavigate(bookmarkPath)
      onClose()
    },
    [onNavigate, onClose]
  )

  const isAddDisabled = adding || !addLabel.trim() || (source === 'remote' && !hostId)

  const bookmarkItems =
    source === 'remote'
      ? remoteBookmarks.map((bm) => ({
          id: bm.id,
          label: bm.label,
          path: bm.remotePath
        }))
      : localBookmarks.map((bm) => ({
          id: bm.id,
          label: bm.label,
          path: bm.path
        }))

  const isLoading = source === 'remote' && bookmarksQuery.isLoading

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
          <Dialog.Title className="flex items-center gap-2 font-medium text-base">
            <Bookmark className="h-4 w-4" />
            Bookmarks
          </Dialog.Title>

          {/* Add bookmark */}
          <div className="mt-4 flex gap-2">
            <Input
              onChange={(e) => setAddLabel(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  handleAdd()
                }
              }}
              placeholder="Label for current path..."
              value={addLabel}
            />
            <Button disabled={isAddDisabled} onClick={handleAdd} size="icon">
              {adding ? <Loader2 className="h-4 w-4 animate-spin" /> : <Plus className="h-4 w-4" />}
            </Button>
          </div>
          <p className="mt-1 text-muted-foreground text-xs">Bookmarking: {currentPath}</p>

          {/* Bookmark list */}
          <ScrollArea className="mt-4 max-h-64">
            {isLoading && (
              <div className="flex h-16 items-center justify-center">
                <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
              </div>
            )}
            {bookmarkItems.length === 0 && !isLoading && (
              <p className="py-4 text-center text-muted-foreground text-sm">No bookmarks yet.</p>
            )}
            <div className="space-y-0.5">
              {bookmarkItems.map((bm) => (
                <div className="flex items-center gap-2 rounded-sm px-2 py-1.5 hover:bg-accent" key={bm.id}>
                  <button
                    className="flex min-w-0 flex-1 items-center gap-2 text-left text-sm"
                    onClick={() => handleBookmarkClick(bm.path)}
                    type="button"
                  >
                    <FolderOpen className="h-4 w-4 shrink-0 text-muted-foreground" />
                    <div className="min-w-0 flex-1">
                      <div className="truncate font-medium">{bm.label}</div>
                      <div className="truncate text-muted-foreground text-xs">{bm.path}</div>
                    </div>
                  </button>
                  <Button onClick={() => handleDelete(bm.id)} size="icon" variant="ghost">
                    <Trash2 className="h-3.5 w-3.5" />
                    <span className="sr-only">Delete</span>
                  </Button>
                </div>
              ))}
            </div>
          </ScrollArea>

          <div className="mt-4 flex justify-end">
            <Dialog.Close
              render={
                <Button onClick={onClose} variant="outline">
                  Close
                </Button>
              }
            />
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
