import { Dialog } from '@base-ui/react/dialog'
import Editor from '@monaco-editor/react'
import { Loader2 } from 'lucide-react'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { toast } from 'sonner'
import { useTheme } from '@/components/theme-provider'
import { Button } from '@/components/ui/button'

const EXTENSION_LANGUAGE_MAP: Record<string, string> = {
  bash: 'shell',
  c: 'c',
  cc: 'cpp',
  conf: 'ini',
  cpp: 'cpp',
  cs: 'csharp',
  css: 'css',
  dart: 'dart',
  diff: 'diff',
  dockerfile: 'dockerfile',
  go: 'go',
  graphql: 'graphql',
  h: 'c',
  hpp: 'cpp',
  html: 'html',
  ini: 'ini',
  java: 'java',
  js: 'javascript',
  json: 'json',
  jsx: 'javascript',
  kt: 'kotlin',
  less: 'less',
  lua: 'lua',
  md: 'markdown',
  mjs: 'javascript',
  mts: 'typescript',
  php: 'php',
  pl: 'perl',
  py: 'python',
  r: 'r',
  rb: 'ruby',
  rs: 'rust',
  sass: 'scss',
  scala: 'scala',
  scss: 'scss',
  sh: 'shell',
  sql: 'sql',
  swift: 'swift',
  toml: 'ini',
  ts: 'typescript',
  tsx: 'typescript',
  txt: 'plaintext',
  xml: 'xml',
  yaml: 'yaml',
  yml: 'yaml',
  zsh: 'shell'
}

function detectLanguage(filePath: string): string {
  const ext = filePath.split('.').pop()?.toLowerCase() ?? ''
  const baseName = filePath.split('/').pop()?.toLowerCase() ?? ''
  if (baseName === 'dockerfile') {
    return 'dockerfile'
  }
  if (baseName === 'makefile') {
    return 'makefile'
  }
  return EXTENSION_LANGUAGE_MAP[ext] ?? 'plaintext'
}

const COMMON_LANGUAGES = [
  'plaintext',
  'typescript',
  'javascript',
  'json',
  'html',
  'css',
  'python',
  'rust',
  'go',
  'java',
  'c',
  'cpp',
  'shell',
  'sql',
  'markdown',
  'yaml',
  'xml',
  'dockerfile',
  'ini'
]

interface FileEditorDialogProps {
  onClose: () => void
  onSaved?: () => void
  open: boolean
  path: string
  readFile: (path: string, maxSize?: number) => Promise<string>
  readOnly?: boolean
  writeFile?: (path: string, content: string) => Promise<void>
}

export function FileEditorDialog({
  onClose,
  onSaved,
  open,
  path,
  readFile,
  readOnly: initialReadOnly = true,
  writeFile
}: FileEditorDialogProps) {
  const { resolvedTheme } = useTheme()
  const [content, setContent] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [readOnly, setReadOnly] = useState(initialReadOnly)
  const [language, setLanguage] = useState(() => detectLanguage(path))
  const editorContentRef = useRef('')

  useEffect(() => {
    setReadOnly(initialReadOnly)
  }, [initialReadOnly])

  useEffect(() => {
    setLanguage(detectLanguage(path))
  }, [path])

  const loadContent = useCallback(async () => {
    setLoading(true)
    setError(null)
    setContent(null)
    try {
      const text = await readFile(path, 2 * 1024 * 1024)
      setContent(text)
      editorContentRef.current = text
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setError(message)
      toast.error('Failed to load file', { description: message })
    } finally {
      setLoading(false)
    }
  }, [readFile, path])

  useEffect(() => {
    if (open) {
      loadContent()
    }
  }, [open, loadContent])

  const handleSave = useCallback(async () => {
    if (!writeFile) {
      return
    }
    setSaving(true)
    try {
      await writeFile(path, editorContentRef.current)
      toast.success('File saved')
      onSaved?.()
      onClose()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      toast.error('Failed to save file', { description: message })
    } finally {
      setSaving(false)
    }
  }, [writeFile, path, onSaved, onClose])

  const fileName = path.split('/').pop() ?? path
  const monacoTheme = resolvedTheme === 'dark' ? 'vs-dark' : 'light'
  const canEdit = !!writeFile

  const editorOptions = useMemo(
    () => ({
      readOnly,
      minimap: { enabled: false },
      fontSize: 13,
      lineNumbers: 'on' as const,
      scrollBeyondLastLine: false,
      wordWrap: 'on' as const,
      automaticLayout: true,
      renderLineHighlight: readOnly ? ('none' as const) : ('line' as const),
      cursorStyle: readOnly ? ('line-thin' as const) : ('line' as const)
    }),
    [readOnly]
  )

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-4xl -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg outline-none">
          {/* Absorb auto-focus so no visible element gets the focus ring */}
          <span aria-hidden className="fixed opacity-0" tabIndex={0} />
          <div className="flex items-center justify-between">
            <div className="min-w-0">
              <Dialog.Title className="truncate font-medium text-base">
                {readOnly ? fileName : `Edit: ${fileName}`}
              </Dialog.Title>
              <Dialog.Description className="mt-0.5 truncate text-muted-foreground text-xs">{path}</Dialog.Description>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <select
                className="h-8 rounded-md border bg-background px-2 text-xs"
                onChange={(e) => setLanguage(e.target.value)}
                value={language}
              >
                {COMMON_LANGUAGES.map((lang) => (
                  <option key={lang} value={lang}>
                    {lang}
                  </option>
                ))}
              </select>
              {canEdit && (
                <Button
                  className="h-8 text-xs"
                  onClick={() => setReadOnly((v) => !v)}
                  size="sm"
                  variant={readOnly ? 'outline' : 'default'}
                >
                  {readOnly ? 'Read Only' : 'Editing'}
                </Button>
              )}
            </div>
          </div>

          <div className="mt-4 overflow-hidden rounded-md border">
            {loading && (
              <div className="flex h-[28rem] items-center justify-center">
                <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
              </div>
            )}
            {error && (
              <div className="flex h-[28rem] items-center justify-center">
                <div className="rounded-md bg-destructive/10 p-3 text-destructive text-sm">{error}</div>
              </div>
            )}
            {content !== null && !loading && !error && (
              <Editor
                defaultValue={content}
                height="28rem"
                language={language}
                onChange={(value) => {
                  editorContentRef.current = value ?? ''
                }}
                options={editorOptions}
                theme={monacoTheme}
              />
            )}
          </div>

          <div className="mt-4 flex justify-end gap-2">
            <Dialog.Close
              render={
                <Button onClick={onClose} variant="outline">
                  {readOnly ? 'Close' : 'Cancel'}
                </Button>
              }
            />
            {canEdit && !readOnly && (
              <Button disabled={loading || saving || !!error} onClick={handleSave}>
                {saving ? 'Saving...' : 'Save'}
              </Button>
            )}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
