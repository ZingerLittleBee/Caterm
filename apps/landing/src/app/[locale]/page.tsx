import { setRequestLocale } from 'next-intl/server'
import { FeatureGrid } from '@/components/features/feature-grid'
import { Hero } from '@/components/hero/hero'
import { TopNav } from '@/components/nav/top-nav'
import { TerminalAnimation } from '@/components/terminal/terminal-animation'

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params
  setRequestLocale(locale)

  return (
    <>
      <TopNav />
      <Hero rightSlot={<TerminalAnimation />} />
      <FeatureGrid />
    </>
  )
}
