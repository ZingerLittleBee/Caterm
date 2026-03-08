'use client'

import { CommandIcon, FolderSyncIcon, Settings2Icon, TerminalIcon } from 'lucide-react'
import type * as React from 'react'
import { NavMain } from '@/components/nav-main'
import { NavSecondary } from '@/components/nav-secondary'
import { NavUser } from '@/components/nav-user'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem
} from '@/components/ui/sidebar'
import { authClient } from '@/lib/auth-client'

const data = {
  navMain: [
    {
      title: 'SSH Terminal',
      url: '/ssh',
      icon: <TerminalIcon />
    },
    {
      title: 'File Manager',
      url: '/sftp',
      icon: <FolderSyncIcon />
    }
  ],
  navSecondary: [
    {
      title: 'Terminal Settings',
      url: '/ssh/settings',
      icon: <Settings2Icon />
    }
  ]
}
export function AppSidebar({ children, ...props }: React.ComponentProps<typeof Sidebar>) {
  const { data: session } = authClient.useSession()
  const user = session?.user
    ? {
        name: session.user.name,
        email: session.user.email,
        avatar: session.user.image ?? ''
      }
    : null

  return (
    <Sidebar collapsible="offcanvas" {...props}>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton className="data-[slot=sidebar-menu-button]:p-1.5!" render={<a href="/" />}>
              <CommandIcon className="size-5!" />
              <span className="font-semibold text-base">Caterm</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>
      <SidebarContent>
        <NavMain items={data.navMain} />
        {children}
        <NavSecondary className="mt-auto" items={data.navSecondary} />
      </SidebarContent>
      <SidebarFooter>{user && <NavUser user={user} />}</SidebarFooter>
    </Sidebar>
  )
}
