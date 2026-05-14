import { useTranslations } from 'next-intl'
import { BookmarkIcon, GhosttyIcon, ICloudIcon, SftpIcon, SnippetIcon, SwiftIcon } from '@/components/icons'
import { FeatureCard } from './feature-card'

export function FeatureGrid() {
  const t = useTranslations('features')

  const items = [
    { key: 'swift', icon: <SwiftIcon /> },
    { key: 'ghostty', icon: <GhosttyIcon /> },
    { key: 'icloud', icon: <ICloudIcon /> },
    { key: 'sftp', icon: <SftpIcon /> },
    { key: 'bookmarks', icon: <BookmarkIcon /> },
    { key: 'snippets', icon: <SnippetIcon /> }
  ] as const

  return (
    <section
      className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8"
      id="features"
    >
      <div className="max-w-2xl">
        <h2 className="text-balance font-semibold text-3xl tracking-tight md:text-4xl">{t('sectionTitle')}</h2>
        <p className="mt-4 text-[var(--color-text-muted)] text-lg">{t('sectionSub')}</p>
      </div>
      <div className="mt-14 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        {items.map(({ key, icon }) => (
          <FeatureCard body={t(`items.${key}.body`)} icon={icon} key={key} title={t(`items.${key}.title`)} />
        ))}
      </div>
    </section>
  )
}
