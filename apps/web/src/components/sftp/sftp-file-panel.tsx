import { Dialog } from "@base-ui/react/dialog";
import { Loader2, Monitor } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { FileEntry } from "@/types/sftp";
import { SftpBreadcrumb } from "./sftp-breadcrumb";
import { SftpFileTable } from "./sftp-file-table";
import { useSftp } from "./sftp-provider";
import { SftpToolbar } from "./sftp-toolbar";

interface SftpFilePanelProps {
	onDownload?: (entries: FileEntry[]) => void;
	onUpload?: () => void;
	sftpSessionId?: string;
	source: "local" | "remote";
}

export function SftpFilePanel({
	source,
	sftpSessionId,
	onUpload,
	onDownload,
}: SftpFilePanelProps) {
	const { listDir, mkdir, remove, rmdir } = useSftp();
	const [currentPath, setCurrentPath] = useState("/");
	const [entries, setEntries] = useState<FileEntry[]>([]);
	const [selectedEntries, setSelectedEntries] = useState<FileEntry[]>([]);
	const [loading, setLoading] = useState(false);
	const [newFolderDialogOpen, setNewFolderDialogOpen] = useState(false);
	const [newFolderName, setNewFolderName] = useState("");
	const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
	const newFolderInputRef = useRef<HTMLInputElement>(null);

	const loadDirectory = useCallback(
		async (path: string) => {
			if (source !== "remote" || !sftpSessionId) {
				return;
			}
			setLoading(true);
			try {
				const result = await listDir(sftpSessionId, path);
				setEntries(result);
				setCurrentPath(path);
				setSelectedEntries([]);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Failed to list directory", { description: message });
			} finally {
				setLoading(false);
			}
		},
		[source, sftpSessionId, listDir]
	);

	useEffect(() => {
		if (source === "remote" && sftpSessionId) {
			loadDirectory("/");
		}
	}, [source, sftpSessionId, loadDirectory]);

	const handleOpen = useCallback(
		(entry: FileEntry) => {
			if (entry.isDir) {
				loadDirectory(entry.path);
			}
		},
		[loadDirectory]
	);

	const handleNavigate = useCallback(
		(path: string) => {
			loadDirectory(path);
		},
		[loadDirectory]
	);

	const handleRefresh = useCallback(() => {
		loadDirectory(currentPath);
	}, [loadDirectory, currentPath]);

	const handleNewFolderOpen = useCallback(() => {
		setNewFolderName("");
		setNewFolderDialogOpen(true);
	}, []);

	const handleNewFolderConfirm = useCallback(async () => {
		if (!(sftpSessionId && newFolderName.trim())) {
			return;
		}
		const name = newFolderName.trim();
		const newPath = currentPath === "/" ? `/${name}` : `${currentPath}/${name}`;
		setNewFolderDialogOpen(false);
		try {
			await mkdir(sftpSessionId, newPath);
			await loadDirectory(currentPath);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to create folder", { description: message });
		}
	}, [sftpSessionId, newFolderName, currentPath, mkdir, loadDirectory]);

	const handleDeleteOpen = useCallback(() => {
		if (selectedEntries.length === 0) {
			return;
		}
		setDeleteDialogOpen(true);
	}, [selectedEntries.length]);

	const handleDeleteConfirm = useCallback(async () => {
		if (!sftpSessionId || selectedEntries.length === 0) {
			return;
		}
		setDeleteDialogOpen(false);
		try {
			for (const entry of selectedEntries) {
				if (entry.isDir) {
					await rmdir(sftpSessionId, entry.path);
				} else {
					await remove(sftpSessionId, entry.path);
				}
			}
			await loadDirectory(currentPath);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to delete", { description: message });
		}
	}, [
		sftpSessionId,
		selectedEntries,
		currentPath,
		rmdir,
		remove,
		loadDirectory,
	]);

	if (source === "local") {
		return (
			<div className="flex h-full flex-col items-center justify-center gap-2 text-muted-foreground">
				<Monitor className="h-8 w-8" />
				<p className="text-sm">Local panel - coming soon</p>
			</div>
		);
	}

	return (
		<div className="flex h-full flex-col">
			<div className="flex items-center gap-2 border-b px-2 py-1">
				<div className="min-w-0 flex-1">
					<SftpBreadcrumb onNavigate={handleNavigate} path={currentPath} />
				</div>
				<SftpToolbar
					onDelete={handleDeleteOpen}
					onDownload={
						onDownload && selectedEntries.length > 0
							? () => onDownload(selectedEntries)
							: undefined
					}
					onNewFolder={handleNewFolderOpen}
					onRefresh={handleRefresh}
					onUpload={onUpload}
				/>
			</div>
			<ScrollArea className="flex-1">
				{loading ? (
					<div className="flex h-32 items-center justify-center">
						<Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
					</div>
				) : (
					<SftpFileTable
						entries={entries}
						onOpen={handleOpen}
						onSelect={setSelectedEntries}
					/>
				)}
			</ScrollArea>

			{/* New Folder Dialog */}
			<Dialog.Root
				onOpenChange={setNewFolderDialogOpen}
				open={newFolderDialogOpen}
			>
				<Dialog.Portal>
					<Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
					<Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
						<Dialog.Title className="font-medium text-base">
							New Folder
						</Dialog.Title>
						<div className="mt-4">
							<Input
								autoFocus
								onChange={(e) => setNewFolderName(e.target.value)}
								onKeyDown={(e) => {
									if (e.key === "Enter") {
										handleNewFolderConfirm();
									}
								}}
								placeholder="Folder name"
								ref={newFolderInputRef}
								value={newFolderName}
							/>
						</div>
						<div className="mt-4 flex justify-end gap-2">
							<Dialog.Close
								render={
									<Button
										onClick={() => setNewFolderDialogOpen(false)}
										variant="outline"
									>
										Cancel
									</Button>
								}
							/>
							<Button
								disabled={!newFolderName.trim()}
								onClick={handleNewFolderConfirm}
							>
								Create
							</Button>
						</div>
					</Dialog.Popup>
				</Dialog.Portal>
			</Dialog.Root>

			{/* Delete Confirmation Dialog */}
			<Dialog.Root onOpenChange={setDeleteDialogOpen} open={deleteDialogOpen}>
				<Dialog.Portal>
					<Dialog.Backdrop className="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
					<Dialog.Popup className="fixed top-1/2 left-1/2 z-50 w-full max-w-sm -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-background p-6 shadow-lg">
						<Dialog.Title className="font-medium text-base">
							Confirm Delete
						</Dialog.Title>
						<Dialog.Description className="mt-2 text-muted-foreground text-sm">
							Delete {selectedEntries.length} item(s)? This action cannot be
							undone.
						</Dialog.Description>
						<div className="mt-4 flex justify-end gap-2">
							<Dialog.Close
								render={
									<Button
										onClick={() => setDeleteDialogOpen(false)}
										variant="outline"
									>
										Cancel
									</Button>
								}
							/>
							<Button onClick={handleDeleteConfirm} variant="destructive">
								Delete
							</Button>
						</div>
					</Dialog.Popup>
				</Dialog.Portal>
			</Dialog.Root>
		</div>
	);
}
