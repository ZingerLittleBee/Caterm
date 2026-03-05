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

const data = {
  user: {
    name: 'shadcn',
    email: 'm@example.com',
    avatar: '/avatars/shadcn.jpg'
  },
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
  return (
    <Sidebar collapsible="offcanvas" {...props}>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton className="data-[slot=sidebar-menu-button]:p-1.5!" render={<a href="#" />}>
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
      <SidebarFooter>
        <NavUser user={data.user} />
      </SidebarFooter>
    </Sidebar>
  )
}
