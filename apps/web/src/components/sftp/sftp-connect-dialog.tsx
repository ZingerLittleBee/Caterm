import { Dialog } from '@base-ui/react/dialog'
import { useQuery } from '@tanstack/react-query'
import { Loader2, Server } from 'lucide-react'
import { useCallback, useState } from 'react'
import { toast } from 'sonner'
import { SyncStatusBanner } from '@/components/sync/sync-status-banner'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import { client } from '@/lib/orpc'
import { getSshHostsSyncQueryOptions } from '@/lib/sync-query-options'
import { getHostSyncPresentation } from '@/lib/sync-status'
import type { SshHost } from '@/types/ssh'

interface SftpConnectDialogProps {
  onClose: () => void
  onConnect: (sessionId: string) => void
  open: boolean
  openStandalone: (params: {
    authType: 'password' | 'key'
    hostId: string
    hostName: string
    hostname: string
    keyPassphrase?: string
    password?: string
    port?: number
    privateKey?: string
    username: string
  }) => Promise<string>
}

function SftpHostListContent({
  isLoading,
  hosts,
  connecting,
  isError,
  onRetry,
  onSelectHost
}: {
  connecting: string | null
  isError: boolean
  hosts: SshHost[]
  isLoading: boolean
  onRetry: () => void
  onSelectHost: (host: SshHost) => void
}) {
  const presentation = getHostSyncPresentation({
    hostCount: hosts.length,
    isError,
    isPending: isLoading
  })

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-8">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (presentation.banner) {
    return (
      <SyncStatusBanner
        description={presentation.banner.description}
        onRetry={onRetry}
        title={presentation.banner.title}
      />
    )
  }

  if (presentation.showEmptyState) {
    return (
      <p className="py-8 text-center text-muted-foreground text-sm">
        No hosts configured. Add a host from the SSH page first.
      </p>
    )
  }

  return (
    <ScrollArea className="max-h-64">
      <div className="flex flex-col gap-1">
        {hosts.map((host) => (
          <button
            className="flex items-center gap-3 rounded-lg px-3 py-2 text-left transition-colors hover:bg-muted disabled:opacity-50"
            disabled={connecting !== null}
            key={host.id}
            onClick={() => onSelectHost(host)}
            type="button"
          >
            {connecting === host.id ? (
              <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
            ) : (
              <Server className="h-4 w-4 text-muted-foreground" />
            )}
            <div className="min-w-0 flex-1">
              <p className="truncate font-medium text-sm">{host.name}</p>
              <p className="truncate text-muted-foreground text-xs">
                {host.username}@{host.hostname}:{host.port}
              </p>
            </div>
          </button>
        ))}
      </div>
    </ScrollArea>
  )
}

export function SftpConnectDialog({ open, onClose, onConnect, openStandalone }: SftpConnectDialogProps) {
  const { data: hosts = [], isError, isPending, refetch } = useQuery(getSshHostsSyncQueryOptions())
  const [connecting, setConnecting] = useState<string | null>(null)

  const handleSelectHost = useCallback(
    async (host: SshHost) => {
      setConnecting(host.id)
      try {
        const stored = await client.sshHost.getById({ id: host.id })
        const sessionId = await openStandalone({
          authType: stored.authType as 'password' | 'key',
          hostId: stored.id,
          hostName: stored.name,
          hostname: stored.hostname,
          keyPassphrase: stored.keyPassphrase ?? undefined,
          password: stored.password ?? undefined,
          port: stored.port,
          privateKey: stored.privateKey ?? undefined,
          username: stored.username
        })
        onConnect(sessionId)
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        toast.error('SFTP connection failed', { description: message })
      } finally {
        setConnecting(null)
      }
    },
    [openStandalone, onConnect]
  )

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
          <Dialog.Title className="font-medium text-base">Connect to SFTP</Dialog.Title>
          <Dialog.Description className="mt-1 text-muted-foreground text-sm">
            Select a saved host to connect via SFTP.
          </Dialog.Description>

          <div className="mt-4">
            <SftpHostListContent
              connecting={connecting}
              hosts={hosts}
              isError={isError}
              isLoading={isPending}
              onRetry={refetch}
              onSelectHost={handleSelectHost}
            />
          </div>

          <div className="mt-4 flex justify-end">
            <Dialog.Close
              render={
                <Button onClick={onClose} variant="outline">
                  Cancel
                </Button>
              }
            />
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
