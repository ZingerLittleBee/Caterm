import Database from "@tauri-apps/plugin-sql";
import { PlusIcon } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { SshHost } from "@/types/ssh";
import { HostCard } from "./host-card";
import { HostDeleteDialog } from "./host-delete-dialog";

interface HostListProps {
	onConnect: (host: SshHost) => void;
	onEdit: (host: SshHost) => void;
	onNewHost: () => void;
}

export function HostList({ onConnect, onEdit, onNewHost }: HostListProps) {
	const [hosts, setHosts] = useState<SshHost[]>([]);
	const [deleteTarget, setDeleteTarget] = useState<SshHost | null>(null);

	const loadHosts = useCallback(async () => {
		try {
			const db = await Database.load("sqlite:caterm.db");
			const rows = await db.select<SshHost[]>(
				"SELECT * FROM ssh_hosts ORDER BY name"
			);
			setHosts(rows);
		} catch {
			// Database may not be initialized yet
			setHosts([]);
		}
	}, []);

	useEffect(() => {
		loadHosts();
	}, [loadHosts]);

	const handleDelete = useCallback(
		async (host: SshHost) => {
			try {
				const db = await Database.load("sqlite:caterm.db");
				await db.execute("DELETE FROM ssh_hosts WHERE id = ?", [host.id]);
				setDeleteTarget(null);
				await loadHosts();
			} catch {
				// Handle error silently for now
			}
		},
		[loadHosts]
	);

	return (
		<div className="flex h-full flex-col">
			<div className="flex items-center justify-between border-b px-3 py-2">
				<h2 className="font-medium text-sm">Hosts</h2>
				<Button onClick={onNewHost} size="icon-xs" variant="ghost">
					<PlusIcon />
					<span className="sr-only">Add host</span>
				</Button>
			</div>
			<ScrollArea className="flex-1">
				<div className="flex flex-col gap-2 p-2">
					{hosts.length === 0 ? (
						<p className="px-2 py-8 text-center text-muted-foreground text-sm">
							No hosts configured. Click + to add one.
						</p>
					) : (
						hosts.map((host) => (
							<HostCard
								host={host}
								key={host.id}
								onConnect={onConnect}
								onDelete={setDeleteTarget}
								onEdit={onEdit}
							/>
						))
					)}
				</div>
			</ScrollArea>
			<HostDeleteDialog
				host={deleteTarget}
				onCancel={() => setDeleteTarget(null)}
				onConfirm={handleDelete}
				open={deleteTarget !== null}
			/>
		</div>
	);
}
