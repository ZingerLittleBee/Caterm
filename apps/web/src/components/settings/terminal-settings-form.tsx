import { useCallback, useEffect, useState } from 'react'
import { useTerminalSettings } from '@/components/terminal/terminal-settings-provider'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { BUILTIN_THEMES } from '@/lib/terminal-themes'
import type { BellStyle, CursorInactiveStyle, CursorStyle, TerminalSettings } from '@/types/ssh'

export function TerminalSettingsForm() {
  const { settings, updateGlobal, isLoading, isReadOnlyFallback } = useTerminalSettings()
  const [draft, setDraft] = useState<TerminalSettings>(settings)
  useEffect(() => {
    setDraft(settings)
  }, [settings])

  const handleSave = useCallback(() => {
    updateGlobal(draft)
  }, [draft, updateGlobal])

  if (isLoading) {
    return (
      <div className="flex max-w-lg flex-col gap-6">
        <p className="text-muted-foreground">Loading settings...</p>
      </div>
    )
  }

  return (
    <div className="flex max-w-lg flex-col gap-6">
      {isReadOnlyFallback ? (
        <p className="text-muted-foreground text-sm">Settings are temporarily read-only until server sync succeeds.</p>
      ) : null}

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-font-family">Font Family</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-font-family"
          onChange={(e) => setDraft((prev) => ({ ...prev, fontFamily: e.target.value }))}
          placeholder="monospace"
          value={draft.fontFamily}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-font-size">Font Size</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-font-size"
          max={32}
          min={8}
          onChange={(e) =>
            setDraft((prev) => ({
              ...prev,
              fontSize: Number.parseInt(e.target.value, 10) || 14
            }))
          }
          type="number"
          value={String(draft.fontSize)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-line-height">Line Height</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-line-height"
          max={2.0}
          min={1.0}
          onChange={(e) =>
            setDraft((prev) => ({
              ...prev,
              lineHeight: Number.parseFloat(e.target.value) || 1.0
            }))
          }
          step={0.1}
          type="number"
          value={String(draft.lineHeight)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-letter-spacing">Letter Spacing</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-letter-spacing"
          max={10}
          min={-5}
          onChange={(e) =>
            setDraft((prev) => ({
              ...prev,
              letterSpacing: Number.parseFloat(e.target.value) || 0
            }))
          }
          type="number"
          value={String(draft.letterSpacing)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label>Cursor Style</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              cursorStyle: value as CursorStyle
            }))
          }
          value={draft.cursorStyle}
        >
          <SelectTrigger className="w-full" disabled={isReadOnlyFallback}>
            <SelectValue placeholder="Select cursor style" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="block">Block</SelectItem>
            <SelectItem value="underline">Underline</SelectItem>
            <SelectItem value="bar">Bar</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex items-center gap-2">
        <Checkbox
          checked={draft.cursorBlink}
          disabled={isReadOnlyFallback}
          id="settings-cursor-blink"
          onCheckedChange={(checked) =>
            setDraft((prev) => ({
              ...prev,
              cursorBlink: Boolean(checked)
            }))
          }
        />
        <Label htmlFor="settings-cursor-blink">Cursor Blink</Label>
      </div>

      <div className="flex flex-col gap-2">
        <Label>Cursor Inactive Style</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              cursorInactiveStyle: value as CursorInactiveStyle
            }))
          }
          value={draft.cursorInactiveStyle}
        >
          <SelectTrigger className="w-full" disabled={isReadOnlyFallback}>
            <SelectValue placeholder="Select inactive cursor style" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="outline">Outline</SelectItem>
            <SelectItem value="block">Block</SelectItem>
            <SelectItem value="bar">Bar</SelectItem>
            <SelectItem value="underline">Underline</SelectItem>
            <SelectItem value="none">None</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="settings-scrollback">Scrollback Lines</Label>
        <Input
          disabled={isReadOnlyFallback}
          id="settings-scrollback"
          max={100_000}
          min={100}
          onChange={(e) =>
            setDraft((prev) => ({
              ...prev,
              scrollback: Number.parseInt(e.target.value, 10) || 1000
            }))
          }
          type="number"
          value={String(draft.scrollback)}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label>Bell Style</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              bellStyle: value as BellStyle
            }))
          }
          value={draft.bellStyle}
        >
          <SelectTrigger className="w-full" disabled={isReadOnlyFallback}>
            <SelectValue placeholder="Select bell style" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="none">None</SelectItem>
            <SelectItem value="sound">Sound</SelectItem>
            <SelectItem value="visual">Visual</SelectItem>
            <SelectItem value="both">Both</SelectItem>
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label>Theme</Label>
        <Select
          disabled={isReadOnlyFallback}
          onValueChange={(value) =>
            setDraft((prev) => ({
              ...prev,
              themeName: value ?? prev.themeName
            }))
          }
          value={draft.themeName}
        >
          <SelectTrigger className="w-full" disabled={isReadOnlyFallback}>
            <SelectValue placeholder="Select theme" />
          </SelectTrigger>
          <SelectContent>
            {Object.entries(BUILTIN_THEMES).map(([key, preset]) => (
              <SelectItem key={key} value={key}>
                {preset.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="pt-2">
        <Button disabled={isReadOnlyFallback} onClick={handleSave}>
          Save Settings
        </Button>
      </div>
    </div>
  )
}
