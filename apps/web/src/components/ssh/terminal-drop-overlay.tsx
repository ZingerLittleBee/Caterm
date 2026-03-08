import { Upload } from 'lucide-react'

interface TerminalDropOverlayProps {
  visible: boolean
}

export function TerminalDropOverlay({ visible }: TerminalDropOverlayProps) {
  if (!visible) {
    return null
  }

  return (
    <div className="pointer-events-none absolute inset-0 z-50 flex items-center justify-center bg-background/60 backdrop-blur-sm">
      <div className="flex flex-col items-center gap-3 rounded-xl border-2 border-primary border-dashed bg-background/80 px-12 py-8">
        <Upload className="h-10 w-10 text-primary" />
        <p className="font-medium text-lg text-primary">Release to upload files</p>
      </div>
    </div>
  )
}
