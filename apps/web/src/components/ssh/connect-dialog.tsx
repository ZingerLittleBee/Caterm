import { Dialog } from '@base-ui/react/dialog'
import { useCallback, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import type { SshHost } from '@/types/ssh'

interface ConnectDialogProps {
  host: SshHost | null
  onCancel: () => void
  onConnect: (credentials: ConnectCredentials) => void
  open: boolean
}

export interface ConnectCredentials {
  host: SshHost
  keyPassphrase?: string
  password?: string
  privateKey?: string
}

export function ConnectDialog({ open, host, onConnect, onCancel }: ConnectDialogProps) {
  const [password, setPassword] = useState('')
  const [privateKey, setPrivateKey] = useState('')
  const [keyPassphrase, setKeyPassphrase] = useState('')

  const resetForm = useCallback(() => {
    setPassword('')
    setPrivateKey('')
    setKeyPassphrase('')
  }, [])

  const handleCancel = useCallback(() => {
    resetForm()
    onCancel()
  }, [onCancel, resetForm])

  const handleConnect = useCallback(() => {
    if (!host) {
      return
    }

    const credentials: ConnectCredentials =
      host.authType === 'password'
        ? { host, password }
        : { host, privateKey, keyPassphrase: keyPassphrase || undefined }

    resetForm()
    onConnect(credentials)
  }, [host, password, privateKey, keyPassphrase, resetForm, onConnect])

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter') {
        handleConnect()
      }
    },
    [handleConnect]
  )

  if (!host) {
    return null
  }

  return (
    <Dialog.Root onOpenChange={(isOpen) => !isOpen && handleCancel()} open={open}>
      <Dialog.Portal>
        <Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
        <Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
          <Dialog.Title className="font-medium text-base">Connect to {host.name}</Dialog.Title>
          <Dialog.Description className="mt-1 text-muted-foreground text-sm">
            {host.username}@{host.hostname}:{host.port}
          </Dialog.Description>

          <div className="mt-4 flex flex-col gap-4">
            {host.authType === 'password' ? (
              <div className="flex flex-col gap-2">
                <Label htmlFor="connect-password">Password</Label>
                <Input
                  autoFocus
                  id="connect-password"
                  onChange={(e) => setPassword(e.target.value)}
                  onKeyDown={handleKeyDown}
                  placeholder="Enter password"
                  type="password"
                  value={password}
                />
              </div>
            ) : (
              <>
                <div className="flex flex-col gap-2">
                  <Label htmlFor="connect-private-key">Private Key</Label>
                  <textarea
                    autoFocus
                    className="min-h-24 w-full rounded-lg border border-input bg-transparent px-2.5 py-2 font-mono text-sm outline-none transition-colors focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
                    id="connect-private-key"
                    onChange={(e) => setPrivateKey(e.target.value)}
                    placeholder="Paste your private key here..."
                    value={privateKey}
                  />
                </div>
                <div className="flex flex-col gap-2">
                  <Label htmlFor="connect-key-passphrase">Key Passphrase (optional)</Label>
                  <Input
                    id="connect-key-passphrase"
                    onChange={(e) => setKeyPassphrase(e.target.value)}
                    onKeyDown={handleKeyDown}
                    placeholder="Passphrase for private key"
                    type="password"
                    value={keyPassphrase}
                  />
                </div>
              </>
            )}
          </div>

          <div className="mt-6 flex justify-end gap-2">
            <Dialog.Close
              render={
                <Button onClick={handleCancel} variant="outline">
                  Cancel
                </Button>
              }
            />
            <Button onClick={handleConnect}>Connect</Button>
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
