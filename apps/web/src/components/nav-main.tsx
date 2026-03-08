'use client'

import { Link, useMatchRoute } from '@tanstack/react-router'
import {
  SidebarGroup,
  SidebarGroupContent,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem
} from '@/components/ui/sidebar'

export function NavMain({
  items
}: {
  items: {
    title: string
    url: string
    icon?: React.ReactNode
  }[]
}) {
  const matchRoute = useMatchRoute()

  return (
    <SidebarGroup>
      <SidebarGroupContent>
        <SidebarMenu>
          {items.map((item) => {
            const isActive = !!matchRoute({ to: item.url, fuzzy: true })
            return (
              <SidebarMenuItem key={item.title}>
                <SidebarMenuButton
                  className="data-active:bg-primary data-active:text-primary-foreground data-active:hover:bg-primary/90 data-active:hover:text-primary-foreground"
                  data-active={isActive || undefined}
                  render={<Link to={item.url} />}
                  tooltip={item.title}
                >
                  {item.icon}
                  <span>{item.title}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            )
          })}
        </SidebarMenu>
      </SidebarGroupContent>
    </SidebarGroup>
  )
}
