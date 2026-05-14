import type { SVGProps } from 'react'

type Props = SVGProps<SVGSVGElement>

const base: Props = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.5,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
  viewBox: '0 0 24 24',
  'aria-hidden': 'true'
}

export function SwiftIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M5 5l4.5 4.5M19 5l-6.5 6.5L7 6m12 6c-2 4-6 7-12 7" />
    </svg>
  )
}

export function GhosttyIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M5 11a7 7 0 0114 0v8l-3-2-3 2-3-2-3 2-2-2v-6z" />
      <circle cx="10" cy="11" fill="currentColor" r="0.8" />
      <circle cx="14" cy="11" fill="currentColor" r="0.8" />
    </svg>
  )
}

export function ICloudIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M7 18a4 4 0 010-8 5 5 0 019.6-1.4A4 4 0 0117 18H7z" />
    </svg>
  )
}

export function SftpIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M4 7h7l2 2h7v10H4z" />
      <path d="M12 12v6m0 0l-2-2m2 2l2-2" />
    </svg>
  )
}

export function BookmarkIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M7 4h10v17l-5-3-5 3V4z" />
    </svg>
  )
}

export function SnippetIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M4 6h16M4 12h10M4 18h16" />
    </svg>
  )
}

export function PortForwardIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M3 12h12m0 0l-4-4m4 4l-4 4M19 5v14" />
    </svg>
  )
}

export function JumpHostIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <circle cx="5" cy="12" r="2" />
      <circle cx="12" cy="6" r="2" />
      <circle cx="19" cy="12" r="2" />
      <circle cx="12" cy="18" r="2" />
      <path d="M6.5 11l4-3.5M13.5 7.5l4 3M13.5 16.5l4-3M10.5 16l-4-3" />
    </svg>
  )
}

export function KeychainIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <circle cx="8" cy="14" r="3" />
      <path d="M10.5 12l8-8 2 2-2 2 2 2-3 1" />
    </svg>
  )
}

export function ControlMasterIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <path d="M4 7h16M4 12h16M4 17h10" />
      <circle cx="18" cy="17" r="2" />
    </svg>
  )
}

export function ThemeIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <circle cx="12" cy="12" r="8" />
      <path d="M12 4a8 8 0 010 16 4 4 0 010-8 4 4 0 000-8z" />
    </svg>
  )
}

export function AskpassIcon(props: Props) {
  return (
    <svg aria-hidden="true" {...base} {...props}>
      <rect height="10" rx="2" width="14" x="5" y="11" />
      <path d="M8 11V7a4 4 0 018 0v4" />
      <circle cx="12" cy="16" fill="currentColor" r="0.8" />
    </svg>
  )
}
