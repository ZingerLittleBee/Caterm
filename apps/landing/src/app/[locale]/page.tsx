import { setRequestLocale } from 'next-intl/server'
import { Hero } from '@/components/hero/hero'
import { TopNav } from '@/components/nav/top-nav'

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params
  setRequestLocale(locale)

  return (
    <>
      <TopNav />
      <Hero
        rightSlot={
          <div className="aspect-[4/3] w-full rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)]" />
        }
      />
    </>
  )
}
