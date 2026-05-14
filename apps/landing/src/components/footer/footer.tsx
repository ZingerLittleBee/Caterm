import { useTranslations } from 'next-intl'
import { LangSwitcher } from '@/components/nav/lang-switcher'

const GITHUB_URL = 'https://github.com/ZingerLittleBee/Caterm'

export function Footer() {
  const t = useTranslations('footer')

  return (
    <footer className="border-[var(--color-border)] border-t">
      <div className="mx-auto grid max-w-6xl gap-10 px-6 py-16 md:grid-cols-3 lg:px-8">
        <div>
          <div className="flex items-center gap-2 font-semibold tracking-tight">
            <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-full bg-[var(--color-accent)]" />
            Caterm
          </div>
          <p className="mt-2 text-[var(--color-text-muted)] text-sm">{t('tagline')}</p>
        </div>

        <div>
          <p className="font-medium text-[var(--color-text)] text-xs uppercase tracking-[0.2em]">{t('linksTitle')}</p>
          <ul className="mt-4 space-y-2 text-sm">
            <li>
              <a className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]" href="#features">
                {t('links.features')}
              </a>
            </li>
            <li>
              <a
                className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
                href={GITHUB_URL}
                rel="noopener noreferrer"
                target="_blank"
              >
                {t('links.github')}
              </a>
            </li>
            <li>
              <a
                className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
                href={`${GITHUB_URL}/blob/main/LICENSE`}
                rel="noopener noreferrer"
                target="_blank"
              >
                {t('links.license')}
              </a>
            </li>
            <li>
              <a className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]" href="#privacy">
                {t('links.privacy')}
              </a>
            </li>
          </ul>
        </div>

        <div className="flex flex-col items-start gap-4 md:items-end">
          <LangSwitcher />
          <p className="text-[var(--color-text-muted)] text-xs">{t('rights')}</p>
        </div>
      </div>
    </footer>
  )
}
