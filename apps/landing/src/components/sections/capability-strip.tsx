import { useTranslations } from 'next-intl'
import {
  AskpassIcon,
  ControlMasterIcon,
  JumpHostIcon,
  KeychainIcon,
  PortForwardIcon,
  SnippetIcon,
  ThemeIcon
} from '@/components/icons'

export function CapabilityStrip() {
  const t = useTranslations('capabilities')

  const items = [
    { key: 'portForward', Icon: PortForwardIcon },
    { key: 'jumpHost', Icon: JumpHostIcon },
    { key: 'keychain', Icon: KeychainIcon },
    { key: 'controlMaster', Icon: ControlMasterIcon },
    { key: 'themes', Icon: ThemeIcon },
    { key: 'snippets', Icon: SnippetIcon },
    { key: 'askpass', Icon: AskpassIcon }
  ] as const

  return (
    <section className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-20 lg:px-8">
      <h2 className="text-center text-[var(--color-text-muted)] text-sm uppercase tracking-[0.2em]">{t('title')}</h2>
      <ul className="mt-8 flex flex-wrap items-center justify-center gap-3">
        {items.map(({ key, Icon }) => (
          <li
            className="inline-flex items-center gap-2 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] px-4 py-2 text-[var(--color-text)] text-sm"
            key={key}
          >
            <span className="text-[var(--color-accent)]">
              <Icon className="h-4 w-4" />
            </span>
            {t(`items.${key}`)}
          </li>
        ))}
      </ul>
    </section>
  )
}
