import type React from 'react'

export function TerminalWindow({
  title,
  tabs,
  activeTab,
  children
}: {
  title: string
  tabs: Array<{ id: string; label: string }>
  activeTab: string
  children: React.ReactNode
}) {
  return (
    <div className="overflow-hidden rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] shadow-[0_30px_80px_-20px_rgba(34,211,238,0.15)]">
      <div className="flex items-center gap-3 border-[var(--color-border)] border-b bg-[var(--color-surface-hi)] px-4 py-2.5">
        <div aria-hidden="true" className="flex items-center gap-1.5">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="flex-1 truncate text-center text-[var(--color-text-muted)] text-xs">{title}</div>
        <div aria-hidden="true" className="w-12" />
      </div>
      <div className="flex gap-1 border-[var(--color-border)] border-b bg-[var(--color-surface-hi)] px-3 py-1.5">
        {tabs.map((tab) => {
          const active = tab.id === activeTab
          return (
            <div
              className={`flex items-center gap-1.5 rounded-md px-2.5 py-1 text-xs transition ${
                active ? 'bg-[var(--color-surface)] text-[var(--color-text)]' : 'text-[var(--color-text-muted)]'
              }`}
              key={tab.id}
            >
              <span
                aria-hidden="true"
                className={`h-1.5 w-1.5 rounded-full ${
                  active ? 'bg-[var(--color-accent)]' : 'bg-[var(--color-border)]'
                }`}
              />
              {tab.label}
            </div>
          )
        })}
      </div>
      <div className="relative min-h-[340px] bg-[var(--color-bg)] p-5 font-mono text-[13px] leading-relaxed">
        {children}
      </div>
    </div>
  )
}
