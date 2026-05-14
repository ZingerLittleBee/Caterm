import { setRequestLocale } from 'next-intl/server'
import { FeatureGrid } from '@/components/features/feature-grid'
import { Footer } from '@/components/footer/footer'
import { Hero } from '@/components/hero/hero'
import { TopNav } from '@/components/nav/top-nav'
import { CapabilityStrip } from '@/components/sections/capability-strip'
import { OpenSource } from '@/components/sections/open-source'
import { SftpDeepDive } from '@/components/sections/sftp-deep-dive'
import { SyncDeepDive } from '@/components/sections/sync-deep-dive'
import { TerminalAnimation } from '@/components/terminal/terminal-animation'

export default async function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params
  setRequestLocale(locale)

  return (
    <>
      <TopNav />
      <Hero rightSlot={<TerminalAnimation />} />
      <FeatureGrid />
      <SyncDeepDive />
      <SftpDeepDive />
      <CapabilityStrip />
      <OpenSource />
      <Footer />
    </>
  )
}
