import { createFileRoute, Outlet } from '@tanstack/react-router'
import { SessionRouteError } from '@/components/auth/session-route-error'
import { SftpProvider } from '@/components/sftp/sftp-provider'
import { SshSessionProvider } from '@/components/ssh/ssh-session-provider'
import { TerminalSettingsProvider } from '@/components/terminal/terminal-settings-provider'
import { requireAuthenticatedSession } from '@/lib/route-auth'
import { prefetchSshRouteData } from '@/lib/sync-prefetch'

export const Route = createFileRoute('/ssh')({
  beforeLoad: async () => {
    await requireAuthenticatedSession()
  },
  loader: ({ context }) => prefetchSshRouteData(context.queryClient),
  errorComponent: ({ error }) => <SessionRouteError error={error} />,
  component: SshRouteLayout
})

function SshRouteLayout() {
  return (
    <TerminalSettingsProvider>
      <SshSessionProvider>
        <SftpProvider>
          <Outlet />
        </SftpProvider>
      </SshSessionProvider>
    </TerminalSettingsProvider>
  )
}
