'use client'

import { useLocale, useTranslations } from 'next-intl'
import { routing, usePathname, useRouter } from '@/i18n/routing'
import { cn } from '@/lib/cn'

export function LangSwitcher() {
  const t = useTranslations('nav')
  const router = useRouter()
  const pathname = usePathname()
  const current = useLocale()

  function setLocale(next: string) {
    document.cookie = `NEXT_LOCALE=${next}; path=/; max-age=31536000; samesite=lax`
    router.replace(pathname, { locale: next as (typeof routing.locales)[number] })
  }

  return (
    <div
      aria-label={t('languageAria')}
      className="flex items-center gap-1 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] p-0.5 text-xs"
      role="group"
    >
      {routing.locales.map((loc) => (
        <button
          aria-pressed={current === loc}
          className={cn(
            'rounded-full px-2.5 py-1 transition',
            current === loc
              ? 'bg-[var(--color-surface-hi)] text-[var(--color-text)]'
              : 'text-[var(--color-text-muted)] hover:text-[var(--color-text)]'
          )}
          key={loc}
          onClick={() => setLocale(loc)}
          type="button"
        >
          {loc === 'en' ? t('english') : t('chinese')}
        </button>
      ))}
    </div>
  )
}
