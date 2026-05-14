import { useTranslations } from 'next-intl'
import { SftpAnimation } from './sftp-animation'

export function SftpDeepDive() {
  const t = useTranslations('sftp')

  return (
    <section className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8" id="sftp">
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-20">
        <div className="order-2 lg:order-1">
          <SftpAnimation />
        </div>
        <div className="order-1 lg:order-2">
          <p className="font-medium text-[var(--color-accent)] text-sm">{t('eyebrow')}</p>
          <h2 className="mt-2 text-balance font-semibold text-3xl tracking-tight md:text-4xl">{t('title')}</h2>
          <p className="mt-5 text-[var(--color-text-muted)] text-lg leading-relaxed">{t('body')}</p>
        </div>
      </div>
    </section>
  )
}
