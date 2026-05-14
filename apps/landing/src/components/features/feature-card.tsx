import type React from 'react'

export function FeatureCard({ icon, title, body }: { icon: React.ReactNode; title: string; body: string }) {
  return (
    <div className="group rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-6 transition hover:border-[var(--color-accent)]/60">
      <div className="mb-4 inline-flex h-10 w-10 items-center justify-center rounded-xl border border-[var(--color-border)] bg-[var(--color-surface-hi)] text-[var(--color-accent)]">
        <div className="h-5 w-5">{icon}</div>
      </div>
      <h3 className="font-semibold text-[var(--color-text)] text-base">{title}</h3>
      <p className="mt-2 text-[var(--color-text-muted)] text-sm leading-relaxed">{body}</p>
    </div>
  )
}
