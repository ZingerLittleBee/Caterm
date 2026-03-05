import { FolderOpen, PlugZap, Unplug } from "lucide-react";
import type * as React from "react";
import { useCallback, useState } from "react";
import { toast } from "sonner";
import { AppSidebar } from "@/components/app-sidebar";
import { HostForm } from "@/components/hosts/host-form";
import { HostList } from "@/components/hosts/host-list";
import { SiteHeader } from "@/components/site-header";
import { Button } from "@/components/ui/button";
import {
	Sheet,
	SheetContent,
	SheetDescription,
	SheetHeader,
	SheetTitle,
} from "@/components/ui/sheet";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { client, orpc, queryClient } from "@/lib/orpc";
import type { SshHost } from "@/types/ssh";
import { SftpConnectDialog } from "./sftp-connect-dialog";
import { SftpFilePanel } from "./sftp-file-panel";
import { useSftp } from "./sftp-provider";

export function SftpFileManager() {
	const { openStandalone, close, sessions, activeSftpSessionId } = useSftp();
	const [connectDialogOpen, setConnectDialogOpen] = useState(false);
	const [formOpen, setFormOpen] = useState(false);
	const [editingHost, setEditingHost] = useState<SshHost | undefined>(
		undefined
	);

	const activeSession = activeSftpSessionId
		? (sessions.get(activeSftpSessionId) ?? null)
		: null;

	const handleConnect = useCallback((sessionId: string) => {
		setConnectDialogOpen(false);
		toast.success("SFTP connected", {
			description: `Session ${sessionId.slice(0, 8)}...`,
		});
	}, []);

	const handleDisconnect = useCallback(async () => {
		if (!activeSftpSessionId) {
			return;
		}
		try {
			await close(activeSftpSessionId);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to disconnect", { description: message });
		}
	}, [activeSftpSessionId, close]);

	const handleConnectRequest = useCallback(
		async (host: SshHost) => {
			try {
				const stored = await client.sshHost.getById({ id: host.id });
				await openStandalone({
					authType: stored.authType as "password" | "key",
					hostId: stored.id,
					hostName: stored.name,
					hostname: stored.hostname,
					keyPassphrase: stored.keyPassphrase ?? undefined,
					password: stored.password ?? undefined,
					port: stored.port,
					privateKey: stored.privateKey ?? undefined,
					username: stored.username,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Failed to connect SFTP", { description: message });
			}
		},
		[openStandalone]
	);

	const handleNewHost = useCallback(() => {
		setEditingHost(undefined);
		setFormOpen(true);
	}, []);

	const handleEditHost = useCallback((host: SshHost) => {
		setEditingHost(host);
		setFormOpen(true);
	}, []);

	const handleFormSubmit = useCallback(
		async (values: {
			authType: "password" | "key";
			hostname: string;
			keyPassphrase: string;
			name: string;
			password: string;
			port: number;
			privateKey: string;
			username: string;
		}) => {
			try {
				if (editingHost) {
					await client.sshHost.update({
						id: editingHost.id,
						name: values.name,
						hostname: values.hostname,
						port: values.port,
						username: values.username,
						authType: values.authType,
						password: values.password || undefined,
						privateKey: values.privateKey || undefined,
						keyPassphrase: values.keyPassphrase || undefined,
					});
				} else {
					await client.sshHost.create({
						name: values.name,
						hostname: values.hostname,
						port: values.port,
						username: values.username,
						authType: values.authType,
						password: values.password || undefined,
						privateKey: values.privateKey || undefined,
						keyPassphrase: values.keyPassphrase || undefined,
					});
				}

				setFormOpen(false);
				setEditingHost(undefined);
				queryClient.invalidateQueries({
					queryKey: orpc.sshHost.list.queryOptions().queryKey,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Failed to save host", { description: message });
			}
		},
		[editingHost]
	);

	const handleFormCancel = useCallback(() => {
		setFormOpen(false);
		setEditingHost(undefined);
	}, []);

	return (
		<SidebarProvider
			style={
				{
					"--sidebar-width": "calc(var(--spacing) * 72)",
					"--header-height": "calc(var(--spacing) * 12)",
				} as React.CSSProperties
			}
		>
			<AppSidebar variant="inset">
				<HostList
					onConnect={handleConnectRequest}
					onEdit={handleEditHost}
					onNewHost={handleNewHost}
				/>
			</AppSidebar>
			<SidebarInset>
				<SiteHeader title="SFTP File Manager">
					<div className="ml-auto flex items-center gap-2">
						{activeSession ? (
							<>
								<span className="text-muted-foreground text-sm">
									Connected: {activeSession.hostName}
								</span>
								<Button onClick={handleDisconnect} size="sm" variant="ghost">
									<Unplug className="mr-1 h-4 w-4" />
									Disconnect
								</Button>
							</>
						) : (
							<Button
								onClick={() => setConnectDialogOpen(true)}
								size="sm"
								variant="outline"
							>
								<PlugZap className="mr-1 h-4 w-4" />
								Connect
							</Button>
						)}
					</div>
				</SiteHeader>

				{activeSession ? (
					<div className="flex min-h-0 flex-1">
						<div className="flex min-h-0 w-1/2 flex-col border-r">
							<div className="border-b px-3 py-1.5">
								<h2 className="font-medium text-sm">Local</h2>
							</div>
							<SftpFilePanel source="local" />
						</div>
						<div className="flex min-h-0 w-1/2 flex-col">
							<div className="border-b px-3 py-1.5">
								<h2 className="font-medium text-sm">Remote</h2>
							</div>
							<SftpFilePanel
								sftpSessionId={activeSftpSessionId ?? undefined}
								source="remote"
							/>
						</div>
					</div>
				) : (
					<div className="flex flex-1 flex-col items-center justify-center gap-4 text-muted-foreground">
						<FolderOpen className="h-12 w-12" />
						<p>Connect to a host to browse files.</p>
						<Button
							onClick={() => setConnectDialogOpen(true)}
							variant="outline"
						>
							<PlugZap className="mr-1 h-4 w-4" />
							Connect to SFTP
						</Button>
					</div>
				)}
			</SidebarInset>

			<SftpConnectDialog
				onClose={() => setConnectDialogOpen(false)}
				onConnect={handleConnect}
				open={connectDialogOpen}
				openStandalone={openStandalone}
			/>

			<Sheet
				onOpenChange={(isOpen) => !isOpen && handleFormCancel()}
				open={formOpen}
			>
				<SheetContent>
					<SheetHeader>
						<SheetTitle>{editingHost ? "Edit Host" : "New Host"}</SheetTitle>
						<SheetDescription>
							{editingHost
								? "Update the SSH host connection details."
								: "Add a new SSH host to connect to."}
						</SheetDescription>
					</SheetHeader>
					<div className="p-4">
						<HostForm
							host={editingHost}
							onCancel={handleFormCancel}
							onSubmit={handleFormSubmit}
						/>
					</div>
				</SheetContent>
			</Sheet>
		</SidebarProvider>
	);
}
