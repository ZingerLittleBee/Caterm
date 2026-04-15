import { createFileRoute } from '@tanstack/react-router'
import type * as React from 'react'
import { AppSidebar } from '@/components/app-sidebar'
import { TerminalSettingsForm } from '@/components/settings/terminal-settings-form'
import { TerminalSettingsSyncBanner } from '@/components/terminal/terminal-settings-sync-banner'
import { ScrollArea } from '@/components/ui/scroll-area'
import { SidebarInset, SidebarProvider } from '@/components/ui/sidebar'

export const Route = createFileRoute('/ssh/settings')({
  component: SshSettingsPage
})

function SshSettingsPage() {
  return (
    <SidebarProvider
      style={
        {
          '--sidebar-width': 'calc(var(--spacing) * 72)',
          '--header-height': 'calc(var(--spacing) * 12)'
        } as React.CSSProperties
      }
    >
      <AppSidebar variant="inset" />
      <SidebarInset>
        <div className="flex items-center border-b px-4 py-3">
          <h1 className="font-semibold text-lg">Terminal Settings</h1>
        </div>
        <ScrollArea className="flex-1 overflow-hidden">
          <div className="flex flex-col gap-4 p-6">
            <TerminalSettingsSyncBanner />
            <TerminalSettingsForm />
          </div>
        </ScrollArea>
      </SidebarInset>
    </SidebarProvider>
  )
}
