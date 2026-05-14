import { useTranslations } from 'next-intl'
import { SyncAnimation } from './sync-animation'

export function SyncDeepDive() {
  const t = useTranslations('sync')
  const bullets = t.raw('bullets') as string[]

  return (
    <section className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8" id="sync">
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-20">
        <div>
          <p className="font-medium text-[var(--color-accent)] text-sm">{t('eyebrow')}</p>
          <h2 className="mt-2 text-balance font-semibold text-3xl tracking-tight md:text-4xl">{t('title')}</h2>
          <p className="mt-5 text-[var(--color-text-muted)] text-lg leading-relaxed">{t('body')}</p>
          <ul className="mt-8 space-y-3 text-[var(--color-text)] text-sm">
            {bullets.map((bullet) => (
              <li className="flex gap-3" key={bullet}>
                <span
                  aria-hidden="true"
                  className="mt-1.5 inline-block h-1.5 w-1.5 flex-none rounded-full bg-[var(--color-accent)]"
                />
                <span className="text-[var(--color-text-muted)]">{bullet}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-10">
          <SyncAnimation />
        </div>
      </div>
    </section>
  )
}
