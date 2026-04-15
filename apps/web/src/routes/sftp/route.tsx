import { createFileRoute, Outlet } from '@tanstack/react-router'
import { SessionRouteError } from '@/components/auth/session-route-error'
import { SftpProvider } from '@/components/sftp/sftp-provider'
import { requireAuthenticatedSession } from '@/lib/route-auth'
import { prefetchSftpRouteData } from '@/lib/sync-prefetch'

export const Route = createFileRoute('/sftp')({
  beforeLoad: async () => {
    await requireAuthenticatedSession()
  },
  loader: ({ context }) => prefetchSftpRouteData(context.queryClient),
  errorComponent: ({ error }) => <SessionRouteError error={error} />,
  component: SftpRouteLayout
})

function SftpRouteLayout() {
  return (
    <SftpProvider>
      <Outlet />
    </SftpProvider>
  )
}
