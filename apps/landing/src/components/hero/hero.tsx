import { useTranslations } from 'next-intl'

const GITHUB_URL = 'https://github.com/ZingerLittleBee/caterm'

export function Hero({ rightSlot }: { rightSlot: React.ReactNode }) {
  const t = useTranslations('hero')

  return (
    <section className="relative mx-auto max-w-6xl px-6 pt-20 pb-24 lg:px-8 lg:pt-28 lg:pb-32" id="top">
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(ellipse_at_top,_rgba(34,211,238,0.08),_transparent_60%)]"
      />
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
        <div>
          <h1 className="text-balance font-semibold text-5xl text-[var(--color-text)] leading-[1.05] tracking-tight md:text-7xl">
            {t('tagline')}
          </h1>
          <p className="mt-6 max-w-xl text-balance text-[var(--color-text-muted)] text-lg leading-relaxed">
            {t('sub')}
          </p>
          <div className="mt-10 flex flex-wrap items-center gap-3">
            <a
              className="inline-flex h-11 items-center gap-2 rounded-full bg-[var(--color-text)] px-6 font-medium text-[var(--color-bg)] text-sm transition hover:bg-white"
              href={GITHUB_URL}
              rel="noopener noreferrer"
              target="_blank"
            >
              {t('ctaPrimary')}
              <span aria-hidden="true">→</span>
            </a>
            <a
              className="inline-flex h-11 items-center gap-2 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] px-6 font-medium text-[var(--color-text)] text-sm transition hover:border-[var(--color-accent)]"
              href="#download"
            >
              {t('ctaSecondary')}
            </a>
          </div>
          <p className="mt-5 text-[var(--color-text-muted)] text-xs">{t('requirements')}</p>
        </div>

        <div className="relative">{rightSlot}</div>
      </div>
    </section>
  )
}
