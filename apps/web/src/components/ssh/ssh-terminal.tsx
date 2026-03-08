import '@xterm/xterm/css/xterm.css'

import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import { Terminal } from '@xterm/xterm'
import { useEffect, useRef } from 'react'
import { useTerminalSettings } from '@/components/terminal/terminal-settings-provider'
import { resolveTheme } from '@/lib/terminal-themes'
import type { SshSessionStatus } from '@/types/ssh'

interface SshTerminalProps {
  hostId: string
  isActive: boolean
  onCwdChange?: (cwd: string) => void
  onRetry?: () => void
  sessionId: string
  status: SshSessionStatus
}

export function SshTerminal({ sessionId, hostId, isActive, status, onRetry, onCwdChange }: SshTerminalProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const statusRef = useRef(status)
  statusRef.current = status
  const onRetryRef = useRef(onRetry)
  onRetryRef.current = onRetry
  const onCwdChangeRef = useRef(onCwdChange)
  onCwdChangeRef.current = onCwdChange
  const terminalRef = useRef<Terminal | null>(null)
  const fitAddonRef = useRef<FitAddon | null>(null)
  const rafIdRef = useRef<number>(0)

  const { getSettingsForHost } = useTerminalSettings()
  const settings = getSettingsForHost(hostId)

  // Store terminal options in a ref so the initialization effect does not
  // need them in its dependency array. Re-creating the terminal on every
  // option change would be wasteful and disruptive.
  const optionsRef = useRef(settings)
  optionsRef.current = settings

  // Initialize terminal on mount and clean up on unmount.
  useEffect(() => {
    const container = containerRef.current
    if (!container) {
      return
    }

    const options = optionsRef.current
    const theme = resolveTheme(options)
    const terminal = new Terminal({
      allowProposedApi: true,
      cursorBlink: options.cursorBlink,
      cursorStyle: options.cursorStyle,
      cursorInactiveStyle: options.cursorInactiveStyle,
      fontFamily: options.fontFamily,
      fontSize: options.fontSize,
      letterSpacing: options.letterSpacing,
      lineHeight: options.lineHeight,
      scrollback: options.scrollback,
      theme
    })

    const fitAddon = new FitAddon()
    terminal.loadAddon(fitAddon)
    terminal.loadAddon(new WebLinksAddon())

    terminal.open(container)

    // Track current working directory via OSC 7 escape sequences.
    // Shells emit: \x1b]7;file://hostname/path\x07
    const osc7Disposable = terminal.parser.registerOscHandler(7, (data) => {
      try {
        const url = new URL(data)
        if (url.protocol === 'file:') {
          const cwd = decodeURIComponent(url.pathname)
          onCwdChangeRef.current?.(cwd)
        }
      } catch {
        // Malformed URI — ignore
      }
      return false
    })

    // Try to load the WebGL renderer for better performance.
    // Falls back to the default canvas renderer if WebGL is unavailable.
    try {
      terminal.loadAddon(new WebglAddon())
    } catch {
      // WebGL not available, canvas renderer is used automatically.
    }

    terminalRef.current = terminal
    fitAddonRef.current = fitAddon

    // Initial fit after the terminal is attached to the DOM.
    requestAnimationFrame(() => {
      fitAddon.fit()
    })

    // Forward user input to the SSH backend as base64-encoded data.
    // Use TextEncoder for binary-safe base64 encoding.
    const dataDisposable = terminal.onData((data: string) => {
      // Intercept Enter key when disconnected for manual retry.
      if (statusRef.current === 'disconnected' && data === '\r') {
        onRetryRef.current?.()
        return
      }

      const bytes = new TextEncoder().encode(data)
      // Build binary string in chunks to avoid call stack limits
      // with large paste operations.
      const chunks: string[] = []
      const CHUNK_SIZE = 8192
      for (let i = 0; i < bytes.length; i += CHUNK_SIZE) {
        const slice = bytes.subarray(i, i + CHUNK_SIZE)
        chunks.push(String.fromCodePoint(...slice))
      }
      const encoded = btoa(chunks.join(''))
      invoke('ssh_write', { sessionId, data: encoded }).catch(() => {
        // Write failures are expected when the session disconnects.
      })
    })

    // Forward terminal resize events to the SSH backend.
    const resizeDisposable = terminal.onResize(({ cols, rows }: { cols: number; rows: number }) => {
      invoke('ssh_resize', { sessionId, cols, rows }).catch(() => {
        // Resize failures are expected when the session disconnects.
      })
    })

    // Listen for SSH output from the backend.
    // Use binary-safe base64 decoding to avoid corruption of non-ASCII data.
    let outputUnlisten: (() => void) | null = null
    const outputListenerPromise = listen<string>(`ssh-output-${sessionId}`, (event) => {
      const binary = atob(event.payload)
      const bytes = Uint8Array.from(binary, (c) => c.codePointAt(0) ?? 0)
      const decoded = new TextDecoder().decode(bytes)
      terminal.write(decoded)
    }).then((unlisten) => {
      outputUnlisten = unlisten
    })

    // Listen for reconnecting events — show inline status.
    let reconnectingUnlisten: (() => void) | null = null
    const reconnectingListenerPromise = listen<string>(`ssh-reconnecting-${sessionId}`, (event) => {
      const { attempt, maxAttempts } = event.payload as unknown as {
        attempt: number
        maxAttempts: number
      }
      terminal.write(`\r\n\x1b[33mConnection lost. Reconnecting (${attempt}/${maxAttempts})...\x1b[0m`)
    }).then((unlisten) => {
      reconnectingUnlisten = unlisten
    })

    // Listen for reconnected events — confirm success.
    let reconnectedUnlisten: (() => void) | null = null
    const reconnectedListenerPromise = listen(`ssh-reconnected-${sessionId}`, () => {
      terminal.write('\r\n\x1b[32mReconnected.\x1b[0m\r\n')
    }).then((unlisten) => {
      reconnectedUnlisten = unlisten
    })

    // Listen for disconnect events — show failure or normal disconnect.
    let disconnectUnlisten: (() => void) | null = null
    const disconnectListenerPromise = listen<string>(`ssh-disconnect-${sessionId}`, (event) => {
      const { reason } = event.payload as unknown as { reason: string }
      if (reason === 'failed') {
        terminal.write(
          '\r\n\x1b[31mReconnection failed.\x1b[0m\r\n\x1b[31mPress Enter to retry or close this tab.\x1b[0m\r\n'
        )
      } else {
        terminal.write('\r\n\x1b[31mDisconnected.\x1b[0m\r\n')
      }
    }).then((unlisten) => {
      disconnectUnlisten = unlisten
    })

    // Handle window resize by re-fitting the terminal.
    const handleWindowResize = () => {
      cancelAnimationFrame(rafIdRef.current)
      rafIdRef.current = requestAnimationFrame(() => {
        fitAddon.fit()
      })
    }

    window.addEventListener('resize', handleWindowResize)

    // Cleanup on unmount.
    return () => {
      window.removeEventListener('resize', handleWindowResize)
      cancelAnimationFrame(rafIdRef.current)

      dataDisposable.dispose()
      resizeDisposable.dispose()
      osc7Disposable.dispose()

      // Clean up async event listeners.
      outputListenerPromise.then(() => {
        outputUnlisten?.()
      })
      reconnectingListenerPromise.then(() => {
        reconnectingUnlisten?.()
      })
      reconnectedListenerPromise.then(() => {
        reconnectedUnlisten?.()
      })
      disconnectListenerPromise.then(() => {
        disconnectUnlisten?.()
      })

      terminal.dispose()
      terminalRef.current = null
      fitAddonRef.current = null
    }
  }, [sessionId])

  // Apply settings changes to a live terminal without re-creating it.
  useEffect(() => {
    const terminal = terminalRef.current
    if (!terminal) {
      return
    }
    const theme = resolveTheme(settings)
    terminal.options.fontSize = settings.fontSize
    terminal.options.fontFamily = settings.fontFamily
    terminal.options.cursorStyle = settings.cursorStyle
    terminal.options.cursorBlink = settings.cursorBlink
    terminal.options.cursorInactiveStyle = settings.cursorInactiveStyle
    terminal.options.letterSpacing = settings.letterSpacing
    terminal.options.lineHeight = settings.lineHeight
    terminal.options.scrollback = settings.scrollback
    terminal.options.theme = theme
    fitAddonRef.current?.fit()
  }, [settings])

  // Re-fit terminal when it becomes the active tab.
  useEffect(() => {
    if (!isActive) {
      return
    }

    const id = requestAnimationFrame(() => {
      const fitAddon = fitAddonRef.current
      const terminal = terminalRef.current
      if (fitAddon && terminal) {
        fitAddon.fit()
        terminal.focus()
      }
    })

    return () => {
      cancelAnimationFrame(id)
    }
  }, [isActive])

  return (
    <div
      aria-label={`SSH terminal session ${sessionId}`}
      className="h-full w-full"
      ref={containerRef}
      role="application"
      style={{ display: isActive ? 'block' : 'none' }}
    />
  )
}
