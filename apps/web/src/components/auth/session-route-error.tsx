import { Button } from '@/components/ui/button'
import { SessionVerificationError } from '@/lib/route-auth'

export function SessionRouteError({ error }: { error: unknown }) {
  if (!(error instanceof SessionVerificationError)) {
    throw error
  }

  return (
    <div className="flex h-svh items-center justify-center p-6">
      <div className="flex max-w-md flex-col gap-4 rounded-xl border bg-background p-6 shadow-sm">
        <div>
          <h1 className="font-semibold text-lg">Session verification failed</h1>
          <p className="mt-2 text-muted-foreground text-sm">{error.message}</p>
        </div>

        <Button onClick={() => window.location.reload()} type="button">
          Retry
        </Button>
      </div>
    </div>
  )
}
