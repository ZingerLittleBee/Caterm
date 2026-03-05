import { Dialog } from "@base-ui/react/dialog";
import { Loader2 } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useSftp } from "./sftp-provider";

interface SftpPreviewDialogProps {
	onClose: () => void;
	open: boolean;
	path: string;
	sessionId: string;
}

export function SftpPreviewDialog({
	onClose,
	open,
	path,
	sessionId,
}: SftpPreviewDialogProps) {
	const { readFile } = useSftp();
	const [content, setContent] = useState<string | null>(null);
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState<string | null>(null);

	const loadContent = useCallback(async () => {
		setLoading(true);
		setError(null);
		setContent(null);
		try {
			const text = await readFile(sessionId, path, 1024 * 1024);
			setContent(text);
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			setError(message);
			toast.error("Failed to load file", { description: message });
		} finally {
			setLoading(false);
		}
	}, [readFile, sessionId, path]);

	useEffect(() => {
		if (open) {
			loadContent();
		}
	}, [open, loadContent]);

	const fileName = path.split("/").pop() ?? path;

	return (
		<Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
			<Dialog.Portal>
				<Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
				<Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-2xl -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
					<Dialog.Title className="font-medium text-base">
						{fileName}
					</Dialog.Title>
					<Dialog.Description className="mt-1 text-muted-foreground text-xs">
						{path}
					</Dialog.Description>

					<div className="mt-4">
						{loading && (
							<div className="flex h-32 items-center justify-center">
								<Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
							</div>
						)}
						{error && (
							<div className="rounded-md bg-destructive/10 p-3 text-destructive text-sm">
								{error}
							</div>
						)}
						{content !== null && (
							<ScrollArea className="max-h-96">
								<pre className="whitespace-pre-wrap break-all rounded-md bg-muted p-3 font-mono text-sm">
									{content}
								</pre>
							</ScrollArea>
						)}
					</div>

					<div className="mt-4 flex justify-end">
						<Dialog.Close
							render={
								<Button onClick={onClose} variant="outline">
									Close
								</Button>
							}
						/>
					</div>
				</Dialog.Popup>
			</Dialog.Portal>
		</Dialog.Root>
	);
}
