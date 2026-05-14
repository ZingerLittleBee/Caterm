import { getTranslations, setRequestLocale } from 'next-intl/server'

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params
  setRequestLocale(locale)
  const t = await getTranslations('hero')

  return (
    <main className="mx-auto max-w-6xl px-6 py-32 lg:px-8">
      <h1 className="font-semibold text-5xl tracking-tight md:text-7xl">{t('tagline')}</h1>
      <p className="mt-6 text-[var(--color-text-muted)] text-lg">{t('sub')}</p>
    </main>
  )
}
