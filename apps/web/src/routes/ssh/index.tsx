import { createFileRoute } from "@tanstack/react-router";
import { FolderTree } from "lucide-react";
import type * as React from "react";
import { useCallback, useRef, useState } from "react";
import { toast } from "sonner";
import { AppSidebar } from "@/components/app-sidebar";
import { HostForm } from "@/components/hosts/host-form";
import { HostList } from "@/components/hosts/host-list";
import { useSftp } from "@/components/sftp/sftp-provider";
import { SftpSidebarTree } from "@/components/sftp/sftp-sidebar-tree";
import { SiteHeader } from "@/components/site-header";
import {
	type ConnectCredentials,
	ConnectDialog,
} from "@/components/ssh/connect-dialog";
import { useSshSessions } from "@/components/ssh/ssh-session-provider";
import { SshStatusBar } from "@/components/ssh/ssh-status-bar";
import { SshTabBar } from "@/components/ssh/ssh-tab-bar";
import { SshTerminal } from "@/components/ssh/ssh-terminal";
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

export const Route = createFileRoute("/ssh/")({
	component: SshIndexPage,
});

function SshIndexPage() {
	const { sessions, activeSessionId, connect, disconnect, retry, setActive } =
		useSshSessions();
	const { openStandalone } = useSftp();
	const [formOpen, setFormOpen] = useState(false);
	const [editingHost, setEditingHost] = useState<SshHost | undefined>(
		undefined
	);
	const [connectTarget, setConnectTarget] = useState<SshHost | null>(null);
	const [sftpPanelOpen, setSftpPanelOpen] = useState(false);
	const [sftpSessionId, setSftpSessionId] = useState<string | null>(null);
	const sftpHostIdRef = useRef<string | null>(null);
	const sftpOpeningRef = useRef(false);

	const activeSession = activeSessionId
		? (sessions.get(activeSessionId) ?? null)
		: null;

	const hasConnectedSession =
		activeSession !== null && activeSession.status === "connected";

	const handleToggleSftpPanel = useCallback(async () => {
		if (sftpPanelOpen) {
			setSftpPanelOpen(false);
			return;
		}

		if (!activeSession || activeSession.status !== "connected") {
			return;
		}

		setSftpPanelOpen(true);

		// If we already have an SFTP session for this host, reuse it
		if (sftpSessionId && sftpHostIdRef.current === activeSession.hostId) {
			return;
		}

		// Prevent concurrent openStandalone calls
		if (sftpOpeningRef.current) {
			return;
		}
		sftpOpeningRef.current = true;

		try {
			const stored = await client.sshHost.getById({
				id: activeSession.hostId,
			});
			const id = await openStandalone({
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
			setSftpSessionId(id);
			sftpHostIdRef.current = activeSession.hostId;
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Failed to open SFTP session", { description: message });
			setSftpPanelOpen(false);
		} finally {
			sftpOpeningRef.current = false;
		}
	}, [sftpPanelOpen, activeSession, sftpSessionId, openStandalone]);

	const handleConnectRequest = useCallback(
		async (host: SshHost) => {
			try {
				const stored = await client.sshHost.getById({ id: host.id });
				if (
					(host.authType === "password" && stored.password) ||
					(host.authType === "key" && stored.privateKey)
				) {
					await connect({
						hostId: host.id,
						hostName: host.name,
						hostname: host.hostname,
						port: host.port,
						username: host.username,
						authType: host.authType as "password" | "key",
						password: stored.password,
						privateKey: stored.privateKey,
						keyPassphrase: stored.keyPassphrase,
					});
					return;
				}
			} catch {
				// Failed to load credentials — fall through to dialog
			}
			setConnectTarget(host);
		},
		[connect]
	);

	const handleConnectConfirm = useCallback(
		async (credentials: ConnectCredentials) => {
			const { host } = credentials;
			setConnectTarget(null);
			try {
				await connect({
					hostId: host.id,
					hostName: host.name,
					hostname: host.hostname,
					port: host.port,
					username: host.username,
					authType: host.authType as "password" | "key",
					password: credentials.password,
					privateKey: credentials.privateKey,
					keyPassphrase: credentials.keyPassphrase,
				});
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Connection failed", { description: message });
			}
		},
		[connect]
	);

	const handleConnectCancel = useCallback(() => {
		setConnectTarget(null);
	}, []);

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
				<SiteHeader title="SSH Terminal">
					{hasConnectedSession && (
						<Button
							className="ml-auto"
							onClick={handleToggleSftpPanel}
							size="sm"
							variant={sftpPanelOpen ? "secondary" : "ghost"}
						>
							<FolderTree className="mr-1 h-4 w-4" />
							Files
						</Button>
					)}
				</SiteHeader>

				<SshTabBar
					activeSessionId={activeSessionId}
					onAddSession={handleNewHost}
					onCloseSession={disconnect}
					onSelectSession={setActive}
					sessions={sessions}
				/>

				{/* Terminal + optional file tree panel */}
				<div className="relative flex min-h-0 flex-1">
					<div className="relative min-w-0 flex-1">
						{sessions.size === 0 ? (
							<div className="flex h-full items-center justify-center text-muted-foreground">
								<p>Select a host to connect or add a new one.</p>
							</div>
						) : (
							Array.from(sessions.values()).map((session) => (
								<SshTerminal
									hostId={session.hostId}
									isActive={session.id === activeSessionId}
									key={session.id}
									onRetry={() => retry(session.id)}
									sessionId={session.id}
									status={session.status}
								/>
							))
						)}
					</div>

					{sftpPanelOpen && sftpSessionId && (
						<div className="w-64 shrink-0">
							<SftpSidebarTree sftpSessionId={sftpSessionId} />
						</div>
					)}
				</div>

				<SshStatusBar session={activeSession} />
			</SidebarInset>

			<ConnectDialog
				host={connectTarget}
				onCancel={handleConnectCancel}
				onConnect={handleConnectConfirm}
				open={connectTarget !== null}
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
