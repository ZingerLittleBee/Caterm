'use client'

export function SyncAnimation() {
  return (
    <div aria-hidden="true" className="relative mx-auto flex h-72 max-w-md items-center justify-between">
      <Mac side="left" />
      <Cloud />
      <Mac side="right" />

      <style>{`
        @keyframes dotLeft {
          0%, 100% { transform: translateX(0); opacity: 0; }
          10% { opacity: 1; }
          50% { transform: translateX(60px); opacity: 1; }
          90% { opacity: 0; }
        }
        @keyframes dotRight {
          0%, 100% { transform: translateX(0); opacity: 0; }
          10% { opacity: 1; }
          50% { transform: translateX(-60px); opacity: 1; }
          90% { opacity: 0; }
        }
        @keyframes ledBlink {
          0%, 80%, 100% { opacity: 0.2; }
          90% { opacity: 1; }
        }
        @keyframes ledBlinkAlt {
          0%, 30%, 100% { opacity: 0.2; }
          40% { opacity: 1; }
        }
      `}</style>
    </div>
  )
}

function Mac({ side }: { side: 'left' | 'right' }) {
  return (
    <div className="relative flex flex-col items-center gap-2">
      <div className="relative h-24 w-36 rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] p-2">
        <div className="h-full w-full rounded-md bg-[var(--color-bg)] p-1.5">
          <div className="mb-1 h-1 w-6 rounded-full bg-[var(--color-border)]" />
          <div className="mb-1 h-1 w-12 rounded-full bg-[var(--color-border)]" />
          <div
            className="mb-1 h-1 w-10 rounded-full bg-[var(--color-accent)]"
            style={{
              animation: `${side === 'left' ? 'ledBlink' : 'ledBlinkAlt'} 2.4s infinite`
            }}
          />
          <div className="h-1 w-8 rounded-full bg-[var(--color-border)]" />
        </div>
      </div>
      <div className="h-1 w-20 rounded-b-md bg-[var(--color-border)]" />
    </div>
  )
}

function Cloud() {
  return (
    <div className="relative flex flex-col items-center">
      <div className="flex h-16 w-20 items-center justify-center rounded-full border border-[var(--color-border)] bg-[var(--color-surface-hi)] text-[var(--color-accent)]">
        <svg
          aria-hidden="true"
          className="h-7 w-7"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          viewBox="0 0 24 24"
        >
          <path d="M7 18a4 4 0 010-8 5 5 0 019.6-1.4A4 4 0 0117 18H7z" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>

      <div className="absolute top-1/2 left-1/2 -translate-x-[80px] -translate-y-1/2">
        <span
          className="block h-1.5 w-1.5 rounded-full bg-[var(--color-accent)]"
          style={{ animation: 'dotLeft 2.4s ease-in-out infinite' }}
        />
      </div>
      <div className="absolute top-1/2 left-1/2 translate-x-[20px] -translate-y-1/2">
        <span
          className="block h-1.5 w-1.5 rounded-full bg-[var(--color-accent)]"
          style={{
            animation: 'dotRight 2.4s ease-in-out infinite',
            animationDelay: '1.2s'
          }}
        />
      </div>
    </div>
  )
}
