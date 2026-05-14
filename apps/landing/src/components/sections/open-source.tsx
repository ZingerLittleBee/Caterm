import { useTranslations } from 'next-intl'

const GITHUB_URL = 'https://github.com/ZingerLittleBee/caterm'

export function OpenSource() {
  const t = useTranslations('openSource')
  const stackItems = t.raw('stack.items') as string[]

  return (
    <section
      className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8"
      id="open-source"
    >
      <div className="grid gap-12 lg:grid-cols-2 lg:gap-20">
        <div>
          <p className="font-medium text-[var(--color-accent)] text-sm">{t('eyebrow')}</p>
          <h2 className="mt-2 text-balance font-semibold text-3xl tracking-tight md:text-4xl">{t('title')}</h2>
          <p className="mt-5 text-[var(--color-text-muted)] text-lg leading-relaxed">{t('body')}</p>
          <a
            className="mt-8 inline-flex h-11 items-center gap-2 rounded-full bg-[var(--color-text)] px-6 font-medium text-[var(--color-bg)] text-sm transition hover:bg-white"
            href={GITHUB_URL}
            rel="noopener noreferrer"
            target="_blank"
          >
            {t('cta')}
            <span aria-hidden="true">→</span>
          </a>
        </div>
        <div className="rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-8">
          <p className="text-[var(--color-text-muted)] text-xs uppercase tracking-[0.2em]">{t('stack.label')}</p>
          <ul className="mt-5 grid grid-cols-2 gap-3">
            {stackItems.map((item) => (
              <li
                className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-hi)] px-3 py-2 font-mono text-[var(--color-text)] text-xs"
                key={item}
              >
                {item}
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  )
}
