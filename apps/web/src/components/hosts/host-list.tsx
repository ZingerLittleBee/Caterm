import { useMutation, useQuery } from "@tanstack/react-query";
import { PlusIcon } from "lucide-react";
import { useCallback, useState } from "react";
import { toast } from "sonner";
import {
	SidebarGroup,
	SidebarGroupAction,
	SidebarGroupContent,
	SidebarGroupLabel,
	SidebarMenu,
} from "@/components/ui/sidebar";
import { orpc, queryClient } from "@/lib/orpc";
import type { SshHost } from "@/types/ssh";
import { HostCard } from "./host-card";
import { HostDeleteDialog } from "./host-delete-dialog";

interface HostListProps {
	onConnect: (host: SshHost) => void;
	onEdit: (host: SshHost) => void;
	onNewHost: () => void;
}

export function HostList({ onConnect, onEdit, onNewHost }: HostListProps) {
	const [deleteTarget, setDeleteTarget] = useState<SshHost | null>(null);

	const { data: hosts = [] } = useQuery(orpc.sshHost.list.queryOptions());

	const deleteMutation = useMutation({
		...orpc.sshHost.delete.mutationOptions(),
		onSuccess: () => {
			queryClient.invalidateQueries({
				queryKey: orpc.sshHost.list.queryOptions().queryKey,
			});
			setDeleteTarget(null);
		},
	});

	const handleDelete = useCallback(
		async (host: SshHost) => {
			try {
				await deleteMutation.mutateAsync({ id: host.id });
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Failed to delete host", { description: message });
			}
		},
		[deleteMutation]
	);

	return (
		<SidebarGroup>
			<SidebarGroupLabel>Hosts</SidebarGroupLabel>
			<SidebarGroupAction onClick={onNewHost}>
				<PlusIcon />
				<span className="sr-only">Add host</span>
			</SidebarGroupAction>
			<SidebarGroupContent>
				<SidebarMenu>
					{hosts.length === 0 ? (
						<p className="px-2 py-8 text-center text-muted-foreground text-sm">
							No hosts configured. Click + to add one.
						</p>
					) : (
						hosts.map((host) => (
							<HostCard
								host={host as SshHost}
								key={host.id}
								onConnect={onConnect}
								onDelete={setDeleteTarget}
								onEdit={onEdit}
							/>
						))
					)}
				</SidebarMenu>
			</SidebarGroupContent>
			<HostDeleteDialog
				host={deleteTarget}
				onCancel={() => setDeleteTarget(null)}
				onConfirm={handleDelete}
				open={deleteTarget !== null}
			/>
		</SidebarGroup>
	);
}
