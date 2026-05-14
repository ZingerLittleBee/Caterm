'use client'

import { useTranslations } from 'next-intl'

export function SftpAnimation() {
  const t = useTranslations('sftp')
  const files = t.raw('fileList') as string[]
  const bookmarks = t.raw('bookmarks') as string[]

  return (
    <div
      aria-hidden="true"
      className="relative h-80 overflow-hidden rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-4"
    >
      <div className="flex h-full gap-3">
        <div
          className="w-40 flex-none rounded-lg border border-[var(--color-border)] bg-[var(--color-bg)] p-3 opacity-0"
          style={{ animation: 'slideInDrawer 1200ms ease-out 200ms forwards' }}
        >
          <div className="mb-3 flex items-center justify-between">
            <span className="text-[11px] text-[var(--color-text-muted)] uppercase tracking-wider">files</span>
            <span className="text-[11px] text-[var(--color-text-muted)]">/var/www</span>
          </div>
          <ul className="space-y-1 font-mono text-[12px]">
            {files.map((file, i) => (
              <li
                className="flex items-center gap-1.5 truncate text-[var(--color-text)] opacity-0"
                key={file}
                style={{
                  animation: 'fadeFile 400ms ease-out forwards',
                  animationDelay: `${600 + i * 120}ms`
                }}
              >
                <span className="text-[var(--color-text-muted)]">·</span>
                <span className="truncate">{file}</span>
              </li>
            ))}
          </ul>
        </div>

        <div className="relative flex-1 rounded-lg border border-[var(--color-border)] bg-[var(--color-bg)] p-3 font-mono text-[12px]">
          <div className="space-y-1 text-[var(--color-text-muted)]">
            <div>
              <span className="text-[var(--color-text)]">deploy@prod</span> ~ $ ls
            </div>
            <div>release.tar.gz Caddyfile logs</div>
            <div>
              <span className="text-[var(--color-text)]">deploy@prod</span> ~ ${' '}
              <span
                className="ml-1 inline-block h-3 w-1.5 translate-y-0.5 bg-[var(--color-accent)] align-middle"
                style={{ animation: 'blink 1s steps(1,end) infinite' }}
              />
            </div>
          </div>

          <div
            className="absolute top-4 right-4 w-44 rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-hi)] p-2 opacity-0 shadow-[0_8px_30px_rgba(0,0,0,0.35)]"
            style={{ animation: 'fadeBookmark 500ms ease-out 1400ms forwards' }}
          >
            <div className="mb-1.5 text-[10px] text-[var(--color-text-muted)] uppercase tracking-wider">bookmarks</div>
            <ul className="space-y-1 text-[11px]">
              {bookmarks.map((bookmark, i) => (
                <li
                  className="flex items-center gap-1.5 rounded-md bg-[var(--color-surface)] px-2 py-1 text-[var(--color-text)] opacity-0"
                  key={bookmark}
                  style={{
                    animation: 'fadeFile 400ms ease-out forwards',
                    animationDelay: `${1600 + i * 150}ms`
                  }}
                >
                  <span className="h-1.5 w-1.5 rounded-full bg-[var(--color-accent)]" />
                  {bookmark}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>

      <style>{`
        @keyframes slideInDrawer {
          from { transform: translateX(-110%); opacity: 0; }
          to { transform: translateX(0); opacity: 1; }
        }
        @keyframes fadeFile {
          from { opacity: 0; transform: translateY(4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @keyframes fadeBookmark {
          from { opacity: 0; transform: translateY(-6px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @keyframes blink {
          0%, 49% { opacity: 1; }
          50%, 100% { opacity: 0; }
        }
      `}</style>
    </div>
  )
}
