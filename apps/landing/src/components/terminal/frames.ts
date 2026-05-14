export type Line =
  | { kind: 'type'; text: string; className?: string }
  | { kind: 'instant'; text: string; className?: string }
  | { kind: 'htop' }
  | { kind: 'progress'; label: string }
  | { kind: 'blank' }

export interface Frame {
  activeTab: 'prod' | 'staging'
  durationMs: number
  lines: Line[]
  prompt: string
  toast?: string
}

export function buildFrames(t: { commentConnect: string; statusConnected: string; toastSync: string }): Frame[] {
  const prompt = 'deploy@prod ~ $'

  return [
    {
      prompt,
      activeTab: 'prod',
      durationMs: 1200,
      lines: [
        {
          kind: 'type',
          text: t.commentConnect,
          className: 'text-[var(--color-text-muted)]'
        }
      ]
    },
    {
      prompt,
      activeTab: 'prod',
      durationMs: 1400,
      lines: [
        {
          kind: 'instant',
          text: t.commentConnect,
          className: 'text-[var(--color-text-muted)]'
        },
        { kind: 'type', text: 'ssh deploy@prod.caterm.dev' }
      ]
    },
    {
      prompt,
      activeTab: 'prod',
      durationMs: 800,
      lines: [
        {
          kind: 'instant',
          text: t.commentConnect,
          className: 'text-[var(--color-text-muted)]'
        },
        { kind: 'instant', text: 'ssh deploy@prod.caterm.dev' },
        {
          kind: 'instant',
          text: t.statusConnected,
          className: 'text-[var(--color-accent)]'
        }
      ]
    },
    {
      prompt,
      activeTab: 'prod',
      durationMs: 1100,
      lines: [
        {
          kind: 'instant',
          text: t.statusConnected,
          className: 'text-[var(--color-accent)]'
        },
        { kind: 'type', text: 'htop' }
      ]
    },
    {
      prompt,
      activeTab: 'prod',
      durationMs: 2000,
      lines: [
        {
          kind: 'instant',
          text: t.statusConnected,
          className: 'text-[var(--color-accent)]'
        },
        { kind: 'instant', text: 'htop' },
        { kind: 'htop' }
      ]
    },
    {
      prompt,
      activeTab: 'prod',
      durationMs: 1200,
      lines: [
        {
          kind: 'instant',
          text: '^C',
          className: 'text-[var(--color-text-muted)]'
        },
        { kind: 'type', text: 'sftp put release.tar.gz' }
      ]
    },
    {
      prompt,
      activeTab: 'prod',
      durationMs: 1800,
      lines: [
        { kind: 'instant', text: 'sftp put release.tar.gz' },
        { kind: 'progress', label: 'release.tar.gz' }
      ]
    },
    {
      prompt,
      activeTab: 'staging',
      durationMs: 1500,
      toast: t.toastSync,
      lines: [
        {
          kind: 'instant',
          text: 'sftp put release.tar.gz',
          className: 'text-[var(--color-text-muted)]'
        },
        {
          kind: 'instant',
          text: '✓ uploaded · 24.6 MB',
          className: 'text-[var(--color-accent)]'
        }
      ]
    },
    {
      prompt,
      activeTab: 'staging',
      durationMs: 1500,
      lines: []
    }
  ]
}
