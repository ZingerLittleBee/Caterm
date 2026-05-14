import { useTranslations } from 'next-intl'
import { LangSwitcher } from './lang-switcher'

const GITHUB_URL = 'https://github.com/ZingerLittleBee/caterm'

export function TopNav() {
  const t = useTranslations('nav')

  return (
    <header className="sticky top-0 z-50 border-[var(--color-border)]/60 border-b bg-[var(--color-bg)]/70 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6 lg:px-8">
        <a className="flex items-center gap-2 font-semibold tracking-tight" href="#top">
          <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-full bg-[var(--color-accent)]" />
          Caterm
        </a>

        <nav aria-label="Primary" className="hidden items-center gap-8 text-[var(--color-text-muted)] text-sm md:flex">
          <a className="hover:text-[var(--color-text)]" href="#features">
            {t('features')}
          </a>
          <a className="hover:text-[var(--color-text)]" href="#sync">
            {t('sync')}
          </a>
          <a className="hover:text-[var(--color-text)]" href="#open-source">
            {t('openSource')}
          </a>
        </nav>

        <div className="flex items-center gap-3">
          <LangSwitcher />
          <a
            aria-label={t('githubStarsAria')}
            className="inline-flex h-8 items-center gap-1.5 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] px-3 text-[var(--color-text)] text-xs hover:border-[var(--color-accent)]"
            href={GITHUB_URL}
            rel="noopener noreferrer"
            target="_blank"
          >
            <svg aria-hidden="true" className="h-3.5 w-3.5" fill="currentColor" viewBox="0 0 24 24">
              <title>GitHub</title>
              <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.11.79-.25.79-.56v-2.02c-3.2.7-3.88-1.37-3.88-1.37-.52-1.33-1.27-1.69-1.27-1.69-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.18 1.76 1.18 1.02 1.75 2.67 1.24 3.32.95.1-.74.4-1.24.73-1.53-2.55-.29-5.24-1.28-5.24-5.7 0-1.26.45-2.29 1.18-3.09-.12-.29-.51-1.46.11-3.05 0 0 .96-.31 3.16 1.18a10.96 10.96 0 0 1 5.76 0c2.19-1.49 3.15-1.18 3.15-1.18.63 1.59.23 2.76.11 3.05.74.8 1.18 1.83 1.18 3.09 0 4.43-2.69 5.41-5.26 5.69.41.36.78 1.05.78 2.12v3.15c0 .31.21.68.8.56C20.22 21.38 23.5 17.08 23.5 12 23.5 5.65 18.35.5 12 .5z" />
            </svg>
            {t('github')}
            <span aria-hidden="true" className="text-[var(--color-text-muted)]">
              ★ —
            </span>
          </a>
        </div>
      </div>
    </header>
  )
}
