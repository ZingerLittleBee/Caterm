import type { TerminalSettings, TerminalSettingsState, TerminalThemeColors, TerminalThemePreset } from '@/types/ssh'

export const DEFAULT_TERMINAL_SETTINGS: TerminalSettings = {
  bellStyle: 'none',
  cursorBlink: true,
  cursorInactiveStyle: 'outline',
  cursorStyle: 'block',
  fontFamily: 'monospace',
  fontSize: 14,
  letterSpacing: 0,
  lineHeight: 1.0,
  scrollback: 1000,
  themeName: 'default',
  themeOverrides: {}
}

export const BUILTIN_THEMES: Record<string, TerminalThemePreset> = {
  default: {
    name: 'Default',
    colors: {
      foreground: '#ffffff',
      background: '#000000',
      cursor: '#ffffff',
      cursorAccent: '#000000',
      selectionBackground: '#ffffff40',
      selectionForeground: undefined,
      selectionInactiveBackground: '#ffffff20',
      black: '#2e3436',
      red: '#cc0000',
      green: '#4e9a06',
      yellow: '#c4a000',
      blue: '#3465a4',
      magenta: '#75507b',
      cyan: '#06989a',
      white: '#d3d7cf',
      brightBlack: '#555753',
      brightRed: '#ef2929',
      brightGreen: '#8ae234',
      brightYellow: '#fce94f',
      brightBlue: '#729fcf',
      brightMagenta: '#ad7fa8',
      brightCyan: '#34e2e2',
      brightWhite: '#eeeeec'
    }
  },
  dracula: {
    name: 'Dracula',
    colors: {
      foreground: '#f8f8f2',
      background: '#282a36',
      cursor: '#f8f8f2',
      cursorAccent: '#282a36',
      selectionBackground: '#44475a',
      selectionForeground: '#f8f8f2',
      selectionInactiveBackground: '#44475a80',
      black: '#21222c',
      red: '#ff5555',
      green: '#50fa7b',
      yellow: '#f1fa8c',
      blue: '#bd93f9',
      magenta: '#ff79c6',
      cyan: '#8be9fd',
      white: '#f8f8f2',
      brightBlack: '#6272a4',
      brightRed: '#ff6e6e',
      brightGreen: '#69ff94',
      brightYellow: '#ffffa5',
      brightBlue: '#d6acff',
      brightMagenta: '#ff92df',
      brightCyan: '#a4ffff',
      brightWhite: '#ffffff'
    }
  },
  'one-dark': {
    name: 'One Dark',
    colors: {
      foreground: '#abb2bf',
      background: '#282c34',
      cursor: '#528bff',
      cursorAccent: '#282c34',
      selectionBackground: '#3e4451',
      selectionForeground: '#abb2bf',
      selectionInactiveBackground: '#3e445180',
      black: '#282c34',
      red: '#e06c75',
      green: '#98c379',
      yellow: '#e5c07b',
      blue: '#61afef',
      magenta: '#c678dd',
      cyan: '#56b6c2',
      white: '#abb2bf',
      brightBlack: '#5c6370',
      brightRed: '#e06c75',
      brightGreen: '#98c379',
      brightYellow: '#e5c07b',
      brightBlue: '#61afef',
      brightMagenta: '#c678dd',
      brightCyan: '#56b6c2',
      brightWhite: '#ffffff'
    }
  },
  'solarized-dark': {
    name: 'Solarized Dark',
    colors: {
      foreground: '#839496',
      background: '#002b36',
      cursor: '#839496',
      cursorAccent: '#002b36',
      selectionBackground: '#073642',
      selectionForeground: '#93a1a1',
      selectionInactiveBackground: '#07364280',
      black: '#073642',
      red: '#dc322f',
      green: '#859900',
      yellow: '#b58900',
      blue: '#268bd2',
      magenta: '#d33682',
      cyan: '#2aa198',
      white: '#eee8d5',
      brightBlack: '#002b36',
      brightRed: '#cb4b16',
      brightGreen: '#586e75',
      brightYellow: '#657b83',
      brightBlue: '#839496',
      brightMagenta: '#6c71c4',
      brightCyan: '#93a1a1',
      brightWhite: '#fdf6e3'
    }
  },
  'solarized-light': {
    name: 'Solarized Light',
    colors: {
      foreground: '#657b83',
      background: '#fdf6e3',
      cursor: '#657b83',
      cursorAccent: '#fdf6e3',
      selectionBackground: '#eee8d5',
      selectionForeground: '#586e75',
      selectionInactiveBackground: '#eee8d580',
      black: '#073642',
      red: '#dc322f',
      green: '#859900',
      yellow: '#b58900',
      blue: '#268bd2',
      magenta: '#d33682',
      cyan: '#2aa198',
      white: '#eee8d5',
      brightBlack: '#002b36',
      brightRed: '#cb4b16',
      brightGreen: '#586e75',
      brightYellow: '#657b83',
      brightBlue: '#839496',
      brightMagenta: '#6c71c4',
      brightCyan: '#93a1a1',
      brightWhite: '#fdf6e3'
    }
  },
  monokai: {
    name: 'Monokai',
    colors: {
      foreground: '#f8f8f2',
      background: '#272822',
      cursor: '#f8f8f0',
      cursorAccent: '#272822',
      selectionBackground: '#49483e',
      selectionForeground: '#f8f8f2',
      selectionInactiveBackground: '#49483e80',
      black: '#272822',
      red: '#f92672',
      green: '#a6e22e',
      yellow: '#f4bf75',
      blue: '#66d9ef',
      magenta: '#ae81ff',
      cyan: '#a1efe4',
      white: '#f8f8f2',
      brightBlack: '#75715e',
      brightRed: '#f92672',
      brightGreen: '#a6e22e',
      brightYellow: '#f4bf75',
      brightBlue: '#66d9ef',
      brightMagenta: '#ae81ff',
      brightCyan: '#a1efe4',
      brightWhite: '#f9f8f5'
    }
  },
  nord: {
    name: 'Nord',
    colors: {
      foreground: '#d8dee9',
      background: '#2e3440',
      cursor: '#d8dee9',
      cursorAccent: '#2e3440',
      selectionBackground: '#434c5e',
      selectionForeground: '#d8dee9',
      selectionInactiveBackground: '#434c5e80',
      black: '#3b4252',
      red: '#bf616a',
      green: '#a3be8c',
      yellow: '#ebcb8b',
      blue: '#81a1c1',
      magenta: '#b48ead',
      cyan: '#88c0d0',
      white: '#e5e9f0',
      brightBlack: '#4c566a',
      brightRed: '#bf616a',
      brightGreen: '#a3be8c',
      brightYellow: '#ebcb8b',
      brightBlue: '#81a1c1',
      brightMagenta: '#b48ead',
      brightCyan: '#8fbcbb',
      brightWhite: '#eceff4'
    }
  },
  'github-dark': {
    name: 'GitHub Dark',
    colors: {
      foreground: '#c9d1d9',
      background: '#0d1117',
      cursor: '#c9d1d9',
      cursorAccent: '#0d1117',
      selectionBackground: '#264f78',
      selectionForeground: '#c9d1d9',
      selectionInactiveBackground: '#264f7880',
      black: '#484f58',
      red: '#ff7b72',
      green: '#3fb950',
      yellow: '#d29922',
      blue: '#58a6ff',
      magenta: '#bc8cff',
      cyan: '#39c5cf',
      white: '#b1bac4',
      brightBlack: '#6e7681',
      brightRed: '#ffa198',
      brightGreen: '#56d364',
      brightYellow: '#e3b341',
      brightBlue: '#79c0ff',
      brightMagenta: '#d2a8ff',
      brightCyan: '#56d4dd',
      brightWhite: '#f0f6fc'
    }
  },
  'github-light': {
    name: 'GitHub Light',
    colors: {
      foreground: '#24292f',
      background: '#ffffff',
      cursor: '#044289',
      cursorAccent: '#ffffff',
      selectionBackground: '#0969da33',
      selectionForeground: '#24292f',
      selectionInactiveBackground: '#0969da1a',
      black: '#24292f',
      red: '#cf222e',
      green: '#116329',
      yellow: '#4d2d00',
      blue: '#0969da',
      magenta: '#8250df',
      cyan: '#1b7c83',
      white: '#6e7781',
      brightBlack: '#57606a',
      brightRed: '#a40e26',
      brightGreen: '#1a7f37',
      brightYellow: '#633c01',
      brightBlue: '#218bff',
      brightMagenta: '#a475f9',
      brightCyan: '#3192aa',
      brightWhite: '#8c959f'
    }
  },
  'catppuccin-mocha': {
    name: 'Catppuccin Mocha',
    colors: {
      foreground: '#cdd6f4',
      background: '#1e1e2e',
      cursor: '#f5e0dc',
      cursorAccent: '#1e1e2e',
      selectionBackground: '#585b70',
      selectionForeground: '#cdd6f4',
      selectionInactiveBackground: '#585b7080',
      black: '#45475a',
      red: '#f38ba8',
      green: '#a6e3a1',
      yellow: '#f9e2af',
      blue: '#89b4fa',
      magenta: '#f5c2e7',
      cyan: '#94e2d5',
      white: '#bac2de',
      brightBlack: '#585b70',
      brightRed: '#f38ba8',
      brightGreen: '#a6e3a1',
      brightYellow: '#f9e2af',
      brightBlue: '#89b4fa',
      brightMagenta: '#f5c2e7',
      brightCyan: '#94e2d5',
      brightWhite: '#a6adc8'
    }
  }
}

/** Merge global settings with optional host overrides */
export function resolveSettings(state: TerminalSettingsState, hostId?: string): TerminalSettings {
  if (!hostId) {
    return state.global
  }
  const overrides = state.hostOverrides.get(hostId)
  if (!overrides) {
    return state.global
  }
  return { ...state.global, ...overrides }
}

/** Resolve the final xterm.js ITheme object from settings */
export function resolveTheme(settings: TerminalSettings): Partial<TerminalThemeColors> {
  const preset = BUILTIN_THEMES[settings.themeName] ?? BUILTIN_THEMES.default
  return { ...preset.colors, ...settings.themeOverrides }
}
