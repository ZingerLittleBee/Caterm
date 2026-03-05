import { Dialog } from "@base-ui/react/dialog";
import { useQuery } from "@tanstack/react-query";
import { Bookmark, FolderOpen, Loader2, Plus, Trash2 } from "lucide-react";
import { useCallback, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { client, orpc, queryClient } from "@/lib/orpc";

interface SftpBookmarkListProps {
	currentPath: string;
	hostId: string | undefined;
	onClose: () => void;
	onNavigate: (path: string) => void;
	open: boolean;
}

export function SftpBookmarkList({
	currentPath,
	hostId,
	onClose,
	onNavigate,
	open,
}: SftpBookmarkListProps) {
	const [addLabel, setAddLabel] = useState("");
	const [adding, setAdding] = useState(false);

	const bookmarksQuery = useQuery(
		orpc.sftpBookmark.list.queryOptions({
			input: { hostId },
		})
	);

	const bookmarks = bookmarksQuery.data ?? [];

	const handleAdd = useCallback(async () => {
		if (!(hostId && addLabel.trim())) {
			return;
		}
		setAdding(true);
		try {
			await client.sftpBookmark.create({
				hostId,
				label: addLabel.trim(),
				remotePath: currentPath,
			});
			setAddLabel("");
			queryClient.invalidateQueries({
				queryKey: orpc.sftpBookmark.list.queryOptions({ input: { hostId } })
					.queryKey,
			});
			toast.success("Bookmark added");
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to add bookmark", { description: message });
		} finally {
			setAdding(false);
		}
	}, [hostId, addLabel, currentPath]);

	const handleDelete = useCallback(
		async (id: string) => {
			try {
				await client.sftpBookmark.delete({ id });
				queryClient.invalidateQueries({
					queryKey: orpc.sftpBookmark.list.queryOptions({
						input: { hostId },
					}).queryKey,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Failed to delete bookmark", { description: message });
			}
		},
		[hostId]
	);

	const handleBookmarkClick = useCallback(
		(remotePath: string) => {
			onNavigate(remotePath);
			onClose();
		},
		[onNavigate, onClose]
	);

	return (
		<Dialog.Root onOpenChange={(isOpen) => !isOpen && onClose()} open={open}>
			<Dialog.Portal>
				<Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
				<Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
					<Dialog.Title className="flex items-center gap-2 font-medium text-base">
						<Bookmark className="h-4 w-4" />
						Bookmarks
					</Dialog.Title>

					{/* Add bookmark */}
					<div className="mt-4 flex gap-2">
						<Input
							onChange={(e) => setAddLabel(e.target.value)}
							onKeyDown={(e) => {
								if (e.key === "Enter") {
									handleAdd();
								}
							}}
							placeholder="Label for current path..."
							value={addLabel}
						/>
						<Button
							disabled={adding || !addLabel.trim() || !hostId}
							onClick={handleAdd}
							size="icon"
						>
							{adding ? (
								<Loader2 className="h-4 w-4 animate-spin" />
							) : (
								<Plus className="h-4 w-4" />
							)}
						</Button>
					</div>
					<p className="mt-1 text-muted-foreground text-xs">
						Bookmarking: {currentPath}
					</p>

					{/* Bookmark list */}
					<ScrollArea className="mt-4 max-h-64">
						{bookmarksQuery.isLoading && (
							<div className="flex h-16 items-center justify-center">
								<Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
							</div>
						)}
						{bookmarks.length === 0 && !bookmarksQuery.isLoading && (
							<p className="py-4 text-center text-muted-foreground text-sm">
								No bookmarks yet.
							</p>
						)}
						<div className="space-y-0.5">
							{bookmarks.map((bm) => (
								<div
									className="flex items-center gap-2 rounded-sm px-2 py-1.5 hover:bg-accent"
									key={bm.id}
								>
									<button
										className="flex min-w-0 flex-1 items-center gap-2 text-left text-sm"
										onClick={() => handleBookmarkClick(bm.remotePath)}
										type="button"
									>
										<FolderOpen className="h-4 w-4 shrink-0 text-muted-foreground" />
										<div className="min-w-0 flex-1">
											<div className="truncate font-medium">{bm.label}</div>
											<div className="truncate text-muted-foreground text-xs">
												{bm.remotePath}
											</div>
										</div>
									</button>
									<Button
										onClick={() => handleDelete(bm.id)}
										size="icon"
										variant="ghost"
									>
										<Trash2 className="h-3.5 w-3.5" />
										<span className="sr-only">Delete</span>
									</Button>
								</div>
							))}
						</div>
					</ScrollArea>

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
