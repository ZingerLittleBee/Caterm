import { useMutation, useQuery } from "@tanstack/react-query";
import { createFileRoute, redirect } from "@tanstack/react-router";
import type * as React from "react";
import { useCallback, useState } from "react";
import { toast } from "sonner";
import { AppSidebar } from "@/components/app-sidebar";
import { HostForm } from "@/components/hosts/host-form";
import { HostList } from "@/components/hosts/host-list";
import { SiteHeader } from "@/components/site-header";
import {
	type ConnectCredentials,
	ConnectDialog,
} from "@/components/ssh/connect-dialog";
import {
	SshSessionProvider,
	useSshSessions,
} from "@/components/ssh/ssh-session-provider";
import { SshStatusBar } from "@/components/ssh/ssh-status-bar";
import { SshTabBar } from "@/components/ssh/ssh-tab-bar";
import { SshTerminal } from "@/components/ssh/ssh-terminal";
import {
	Sheet,
	SheetContent,
	SheetDescription,
	SheetHeader,
	SheetTitle,
} from "@/components/ui/sheet";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { authClient } from "@/lib/auth-client";
import { client, orpc, queryClient } from "@/lib/orpc";
import type { SshHost } from "@/types/ssh";

interface TerminalSettings {
	cursorBlink: boolean;
	cursorStyle: "block" | "underline" | "bar";
	fontFamily: string;
	fontSize: number;
	scrollback: number;
}

const DEFAULT_TERMINAL_SETTINGS: TerminalSettings = {
	fontFamily: "monospace",
	fontSize: 14,
	cursorStyle: "block",
	cursorBlink: true,
	scrollback: 1000,
};

export const Route = createFileRoute("/ssh")({
	beforeLoad: async () => {
		const session = await authClient.getSession();
		if (!session.data) {
			throw redirect({ to: "/login" });
		}
	},
	component: SshRouteWrapper,
});

function SshRouteWrapper() {
	return (
		<SshSessionProvider>
			<SshLayout />
		</SshSessionProvider>
	);
}

function SshLayout() {
	const { sessions, activeSessionId, connect, disconnect, retry, setActive } =
		useSshSessions();
	const [formOpen, setFormOpen] = useState(false);
	const [editingHost, setEditingHost] = useState<SshHost | undefined>(
		undefined
	);
	const [connectTarget, setConnectTarget] = useState<SshHost | null>(null);

	const { data: terminalSettings = DEFAULT_TERMINAL_SETTINGS } = useQuery(
		orpc.terminalSettings.get.queryOptions()
	);

	const activeSession = activeSessionId
		? (sessions.get(activeSessionId) ?? null)
		: null;

	const createHostMutation = useMutation(orpc.sshHost.create.mutationOptions());
	const updateHostMutation = useMutation(orpc.sshHost.update.mutationOptions());

	const handleConnectRequest = useCallback(
		async (host: SshHost) => {
			try {
				const fullHost = await client.sshHost.getById({ id: host.id });
				await connect({
					hostId: fullHost.id,
					hostName: fullHost.name,
					hostname: fullHost.hostname,
					port: fullHost.port,
					username: fullHost.username,
					authType: fullHost.authType as "password" | "key",
					password: fullHost.password,
					privateKey: fullHost.privateKey,
					keyPassphrase: fullHost.keyPassphrase,
				});
			} catch {
				setConnectTarget(host);
			}
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
					await updateHostMutation.mutateAsync({
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
					await createHostMutation.mutateAsync({
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
		[editingHost, createHostMutation, updateHostMutation]
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
				<SiteHeader title="SSH Terminal" />

				<SshTabBar
					activeSessionId={activeSessionId}
					onAddSession={handleNewHost}
					onCloseSession={disconnect}
					onSelectSession={setActive}
					sessions={sessions}
				/>

				{/* Terminal area */}
				<div className="relative min-h-0 flex-1">
					{sessions.size === 0 ? (
						<div className="flex h-full items-center justify-center text-muted-foreground">
							<p>Select a host to connect or add a new one.</p>
						</div>
					) : (
						Array.from(sessions.values()).map((session) => (
							<SshTerminal
								cursorBlink={terminalSettings.cursorBlink}
								cursorStyle={
									terminalSettings.cursorStyle as "block" | "underline" | "bar"
								}
								fontFamily={terminalSettings.fontFamily}
								fontSize={terminalSettings.fontSize}
								isActive={session.id === activeSessionId}
								key={session.id}
								onRetry={() => retry(session.id)}
								scrollback={terminalSettings.scrollback}
								sessionId={session.id}
								status={session.status}
							/>
						))
					)}
				</div>

				<SshStatusBar session={activeSession} />
			</SidebarInset>

			{/* Connect credentials dialog */}
			<ConnectDialog
				host={connectTarget}
				onCancel={handleConnectCancel}
				onConnect={handleConnectConfirm}
				open={connectTarget !== null}
			/>

			{/* Host form sheet */}
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
