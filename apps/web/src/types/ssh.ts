export interface SshHost {
  authType: string
  createdAt: Date
  hostname: string
  id: string
  name: string
  port: number
  updatedAt: Date
  username: string
}

export type SshSessionStatus = 'connecting' | 'connected' | 'reconnecting' | 'disconnected' | 'error'

export interface SshSessionInfo {
  hostId: string
  hostName: string
  id: string
  status: SshSessionStatus
}

/** Complete xterm.js ITheme color definition — optional fields match xterm.js ITheme */
export interface TerminalThemeColors {
  background?: string
  black?: string
  blue?: string
  brightBlack?: string
  brightBlue?: string
  brightCyan?: string
  brightGreen?: string
  brightMagenta?: string
  brightRed?: string
  brightWhite?: string
  brightYellow?: string
  cursor?: string
  cursorAccent?: string
  cyan?: string
  foreground?: string
  green?: string
  magenta?: string
  red?: string
  selectionBackground?: string
  selectionForeground?: string
  selectionInactiveBackground?: string
  white?: string
  yellow?: string
}

/** A preset theme = display name + full color set */
export interface TerminalThemePreset {
  colors: TerminalThemeColors
  name: string
}

export type CursorStyle = 'block' | 'underline' | 'bar'
export type CursorInactiveStyle = 'outline' | 'block' | 'bar' | 'underline' | 'none'
export type BellStyle = 'none' | 'sound' | 'visual' | 'both'

export interface TerminalSettings {
  bellStyle: BellStyle
  cursorBlink: boolean
  cursorInactiveStyle: CursorInactiveStyle
  cursorStyle: CursorStyle
  fontFamily: string
  fontSize: number
  letterSpacing: number
  lineHeight: number
  scrollback: number
  themeName: string
  themeOverrides: Partial<TerminalThemeColors>
}

/** Per-host overrides — any subset of TerminalSettings */
export type HostTerminalOverrides = Partial<TerminalSettings>

export interface TerminalSettingsState {
  global: TerminalSettings
  hostOverrides: Map<string, HostTerminalOverrides>
}
