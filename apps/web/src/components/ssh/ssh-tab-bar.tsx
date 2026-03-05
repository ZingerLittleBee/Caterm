import { PlusIcon, XIcon } from 'lucide-react'
import { useCallback } from 'react'
import { Button } from '@/components/ui/button'
import type { SshSessionInfo, SshSessionStatus } from '@/types/ssh'

interface SshTabBarProps {
  activeSessionId: string | null
  onAddSession: () => void
  onCloseSession: (sessionId: string) => void
  onSelectSession: (sessionId: string) => void
  sessions: Map<string, SshSessionInfo>
}

const STATUS_COLORS: Record<SshSessionStatus, string> = {
  connected: 'bg-green-500',
  connecting: 'bg-yellow-500',
  reconnecting: 'bg-yellow-500 animate-pulse',
  disconnected: 'bg-red-500',
  error: 'bg-red-500'
}

export function SshTabBar({
  sessions,
  activeSessionId,
  onSelectSession,
  onCloseSession,
  onAddSession
}: SshTabBarProps) {
  const sessionList = Array.from(sessions.values())

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent, sessionId: string) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        onSelectSession(sessionId)
      }
    },
    [onSelectSession]
  )

  return (
    <div aria-label="SSH sessions" className="flex items-center gap-0.5 border-b bg-muted/30 px-1" role="tablist">
      {sessionList.map((session) => {
        const isActive = session.id === activeSessionId
        return (
          <div
            aria-selected={isActive}
            className={`group flex cursor-pointer items-center gap-1.5 rounded-t-lg border-b-2 px-3 py-1.5 text-sm transition-colors ${
              isActive
                ? 'border-primary bg-background text-foreground'
                : 'border-transparent text-muted-foreground hover:bg-muted hover:text-foreground'
            }`}
            key={session.id}
            onClick={() => onSelectSession(session.id)}
            onKeyDown={(e) => handleKeyDown(e, session.id)}
            role="tab"
            tabIndex={0}
          >
            <span
              aria-label={session.status}
              className={`size-2 shrink-0 rounded-full ${STATUS_COLORS[session.status]}`}
              role="img"
            />
            <span className="max-w-32 truncate">{session.hostName}</span>
            <button
              aria-label={`Close ${session.hostName}`}
              className="ml-1 rounded p-0.5 opacity-0 transition-opacity hover:bg-muted group-hover:opacity-100"
              onClick={(e) => {
                e.stopPropagation()
                onCloseSession(session.id)
              }}
              type="button"
            >
              <XIcon className="size-3" />
            </button>
          </div>
        )
      })}
      <Button className="ml-1" onClick={onAddSession} size="icon-xs" variant="ghost">
        <PlusIcon />
        <span className="sr-only">New session</span>
      </Button>
    </div>
  )
}
