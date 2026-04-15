import { useMutation, useQuery } from '@tanstack/react-query'
import { Loader2, PlusIcon } from 'lucide-react'
import { useCallback, useState } from 'react'
import { toast } from 'sonner'
import { SyncStatusBanner } from '@/components/sync/sync-status-banner'
import {
  SidebarGroup,
  SidebarGroupAction,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu
} from '@/components/ui/sidebar'
import { orpc, queryClient } from '@/lib/orpc'
import { getSshHostsSyncQueryOptions } from '@/lib/sync-query-options'
import { getHostSyncPresentation } from '@/lib/sync-status'
import type { SshHost } from '@/types/ssh'
import { HostCard } from './host-card'
import { HostDeleteDialog } from './host-delete-dialog'

interface HostListProps {
  onConnect: (host: SshHost) => void
  onEdit: (host: SshHost) => void
  onNewHost: () => void
}

export function HostList({ onConnect, onEdit, onNewHost }: HostListProps) {
  const [deleteTarget, setDeleteTarget] = useState<SshHost | null>(null)

  const { data: hosts = [], error, isError, isPending, refetch } = useQuery(getSshHostsSyncQueryOptions())

  const presentation = getHostSyncPresentation({
    hostCount: hosts.length,
    isError,
    isPending
  })

  const deleteMutation = useMutation({
    ...orpc.sshHost.delete.mutationOptions(),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: orpc.sshHost.list.queryOptions().queryKey
      })
      setDeleteTarget(null)
    }
  })

  const handleDelete = useCallback(
    async (host: SshHost) => {
      try {
        await deleteMutation.mutateAsync({ id: host.id })
      } catch (caughtError) {
        const message = caughtError instanceof Error ? caughtError.message : String(caughtError)
        toast.error('Failed to delete host', { description: message })
      }
    },
    [deleteMutation]
  )

  const shouldRenderHosts = !(presentation.showLoadingState || presentation.showEmptyState || presentation.banner)

  return (
    <SidebarGroup>
      <SidebarGroupLabel>Hosts</SidebarGroupLabel>
      <SidebarGroupAction
        disabled={presentation.disableActions}
        onClick={() => {
          if (!presentation.disableActions) {
            onNewHost()
          }
        }}
      >
        <PlusIcon />
        <span className="sr-only">Add host</span>
      </SidebarGroupAction>
      <SidebarGroupContent>
        {presentation.banner ? (
          <div className="px-2 pb-2">
            <SyncStatusBanner
              description={
                error instanceof Error
                  ? `${presentation.banner.description} ${error.message}`
                  : presentation.banner.description
              }
              onRetry={refetch}
              title={presentation.banner.title}
            />
          </div>
        ) : null}

        <SidebarMenu>
          {presentation.showLoadingState ? (
            <div className="flex items-center justify-center px-2 py-8 text-muted-foreground text-sm">
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              Syncing hosts...
            </div>
          ) : null}

          {presentation.showEmptyState ? (
            <p className="px-2 py-8 text-center text-muted-foreground text-sm">
              No hosts configured. Click + to add one.
            </p>
          ) : null}

          {shouldRenderHosts
            ? hosts.map((host) => (
                <HostCard host={host} key={host.id} onConnect={onConnect} onDelete={setDeleteTarget} onEdit={onEdit} />
              ))
            : null}
        </SidebarMenu>
      </SidebarGroupContent>
      <HostDeleteDialog
        host={deleteTarget}
        onCancel={() => setDeleteTarget(null)}
        onConfirm={handleDelete}
        open={deleteTarget !== null}
      />
    </SidebarGroup>
  )
}
