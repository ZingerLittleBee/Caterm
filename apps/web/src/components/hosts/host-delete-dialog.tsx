import { AlertDialog } from "@base-ui/react/alert-dialog";
import { Button } from "@/components/ui/button";
import type { SshHost } from "@/types/ssh";

interface HostDeleteDialogProps {
	host: SshHost | null;
	onCancel: () => void;
	onConfirm: (host: SshHost) => void;
	open: boolean;
}

export function HostDeleteDialog({
	open,
	host,
	onConfirm,
	onCancel,
}: HostDeleteDialogProps) {
	if (!host) {
		return null;
	}

	return (
		<AlertDialog.Root
			onOpenChange={(isOpen) => !isOpen && onCancel()}
			open={open}
		>
			<AlertDialog.Portal>
				<AlertDialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
				<AlertDialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
					<AlertDialog.Title className="font-medium text-base">
						Delete Host
					</AlertDialog.Title>
					<AlertDialog.Description className="mt-2 text-muted-foreground text-sm">
						Are you sure you want to delete &ldquo;{host.name}&rdquo;? This
						action cannot be undone.
					</AlertDialog.Description>
					<div className="mt-6 flex justify-end gap-2">
						<AlertDialog.Close
							render={
								<Button onClick={onCancel} variant="outline">
									Cancel
								</Button>
							}
						/>
						<AlertDialog.Close
							render={
								<Button onClick={() => onConfirm(host)} variant="destructive">
									Delete
								</Button>
							}
						/>
					</div>
				</AlertDialog.Popup>
			</AlertDialog.Portal>
		</AlertDialog.Root>
	);
}
