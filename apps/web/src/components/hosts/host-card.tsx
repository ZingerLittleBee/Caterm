import { MoreHorizontalIcon, PencilIcon, PlugIcon, TerminalIcon, Trash2Icon } from 'lucide-react'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger
} from '@/components/ui/dropdown-menu'
import { SidebarMenuAction, SidebarMenuButton, SidebarMenuItem } from '@/components/ui/sidebar'
import type { SshHost } from '@/types/ssh'

interface HostCardProps {
  host: SshHost
  onConnect: (host: SshHost) => void
  onDelete: (host: SshHost) => void
  onEdit: (host: SshHost) => void
}

export function HostCard({ host, onConnect, onEdit, onDelete }: HostCardProps) {
  return (
    <SidebarMenuItem>
      <SidebarMenuButton onClick={() => onConnect(host)} tooltip={`${host.username}@${host.hostname}:${host.port}`}>
        <TerminalIcon />
        <span className="truncate">{host.name}</span>
      </SidebarMenuButton>
      <DropdownMenu>
        <DropdownMenuTrigger render={<SidebarMenuAction showOnHover />}>
          <MoreHorizontalIcon />
          <span className="sr-only">Host actions</span>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" side="right">
          <DropdownMenuItem onClick={() => onConnect(host)}>
            <PlugIcon />
            Connect
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => onEdit(host)}>
            <PencilIcon />
            Edit
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => onDelete(host)} variant="destructive">
            <Trash2Icon />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </SidebarMenuItem>
  )
}
