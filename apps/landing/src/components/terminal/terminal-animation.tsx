'use client'

import { useTranslations } from 'next-intl'
import { useEffect, useMemo, useState } from 'react'
import { buildFrames, type Frame, type Line } from './frames'
import { TerminalWindow } from './terminal-window'

const TYPE_SPEED_MS = 30

export function TerminalAnimation() {
  const t = useTranslations('terminal')
  const frames = useMemo<Frame[]>(
    () =>
      buildFrames({
        commentConnect: t('commentConnect'),
        statusConnected: t('statusConnected'),
        toastSync: t('toastSync')
      }),
    [t]
  )

  const [frameIdx, setFrameIdx] = useState(0)
  const [typedChars, setTypedChars] = useState(0)

  const frame = frames[frameIdx]

  useEffect(() => {
    const lastLine = frame.lines.at(-1)
    const typing = lastLine?.kind === 'type'

    if (typing) {
      const target = (lastLine as Extract<Line, { kind: 'type' }>).text.length
      if (typedChars < target) {
        const timer = setTimeout(() => {
          setTypedChars((n) => n + 1)
        }, TYPE_SPEED_MS)
        return () => clearTimeout(timer)
      }
    }

    const timer = setTimeout(() => {
      setTypedChars(0)
      setFrameIdx((i) => (i + 1) % frames.length)
    }, frame.durationMs)
    return () => clearTimeout(timer)
  }, [frame, frames.length, typedChars])

  return (
    <TerminalWindow
      activeTab={frame.activeTab}
      tabs={[
        { id: 'prod', label: t('tabProd') },
        { id: 'staging', label: t('tabStaging') }
      ]}
      title={t('title')}
    >
      <pre className="m-0 whitespace-pre-wrap font-mono text-[13px] text-[var(--color-text)]">
        {frame.lines.map((line, idx) => {
          const isLast = idx === frame.lines.length - 1
          const key = `${frameIdx}-${idx}-${line.kind}`
          if (line.kind === 'blank') {
            return <div className="h-4" key={key} />
          }
          if (line.kind === 'htop') {
            return <HtopBlock key={key} />
          }
          if (line.kind === 'progress') {
            return <ProgressLine key={key} label={line.label} />
          }
          const text = line.kind === 'type' && isLast ? line.text.slice(0, typedChars) : line.text
          return (
            <div className={line.className} key={key}>
              <span className="mr-2 text-[var(--color-text-muted)]">{frame.prompt}</span>
              {text}
              {line.kind === 'type' && isLast ? <Caret /> : null}
            </div>
          )
        })}
      </pre>

      {frame.toast ? (
        <div className="absolute right-4 bottom-4 animate-[fadeIn_400ms_ease-out] rounded-full border border-[var(--color-border)] bg-[var(--color-surface-hi)] px-3 py-1.5 text-[11px] text-[var(--color-text-muted)]">
          {frame.toast}
        </div>
      ) : null}

      <style>{`
				@keyframes fadeIn {
					from { opacity: 0; transform: translateY(4px); }
					to { opacity: 1; transform: translateY(0); }
				}
				@keyframes blink {
					0%, 49% { opacity: 1; }
					50%, 100% { opacity: 0; }
				}
				@keyframes pulseBar {
					0%, 100% { width: 30%; }
					50% { width: 78%; }
				}
				@keyframes pulseBar2 {
					0%, 100% { width: 55%; }
					50% { width: 22%; }
				}
				@keyframes pulseBar3 {
					0%, 100% { width: 18%; }
					50% { width: 64%; }
				}
				@keyframes pulseBar4 {
					0%, 100% { width: 72%; }
					50% { width: 41%; }
				}
				@keyframes progressFill {
					from { width: 0%; }
					to { width: 100%; }
				}
			`}</style>
    </TerminalWindow>
  )
}

function Caret() {
  return (
    <span
      aria-hidden="true"
      className="ml-0.5 inline-block h-3.5 w-1.5 translate-y-0.5 bg-[var(--color-accent)]"
      style={{ animation: 'blink 1s steps(1,end) infinite' }}
    />
  )
}

function HtopBlock() {
  return (
    <div className="mt-1 space-y-1">
      {(['pulseBar', 'pulseBar2', 'pulseBar3', 'pulseBar4'] as const).map((anim, i) => (
        <div className="flex items-center gap-2" key={anim}>
          <span className="w-12 text-[var(--color-text-muted)]">{`CPU${i}`}</span>
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-[var(--color-surface-hi)]">
            <div
              className="h-full bg-[var(--color-accent)]"
              style={{ animation: `${anim} 1.8s ease-in-out infinite` }}
            />
          </div>
        </div>
      ))}
    </div>
  )
}

function ProgressLine({ label }: { label: string }) {
  return (
    <div className="mt-1 flex items-center gap-2">
      <span className="text-[var(--color-text-muted)]">{label}</span>
      <div className="h-1.5 w-48 overflow-hidden rounded-full bg-[var(--color-surface-hi)]">
        <div className="h-full bg-[var(--color-accent)]" style={{ animation: 'progressFill 1.5s ease-out forwards' }} />
      </div>
    </div>
  )
}
