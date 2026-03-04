import { createFileRoute } from "@tanstack/react-router";
import Database from "@tauri-apps/plugin-sql";
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
import { loadCredential, saveCredential } from "@/lib/stronghold";
import type { SshHost } from "@/types/ssh";

export const Route = createFileRoute("/ssh")({
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
	const [refreshKey, setRefreshKey] = useState(0);

	const activeSession = activeSessionId
		? (sessions.get(activeSessionId) ?? null)
		: null;

	const handleConnectRequest = useCallback(
		async (host: SshHost) => {
			try {
				const stored = await loadCredential(host.id, host.authType);
				if (
					(host.authType === "password" && stored.password) ||
					(host.authType === "key" && stored.privateKey)
				) {
					// Credentials found in Stronghold — connect directly
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
				const db = await Database.load("sqlite:caterm.db");
				let hostId: string;

				if (editingHost) {
					hostId = editingHost.id;
					await db.execute(
						"UPDATE ssh_hosts SET name = ?, hostname = ?, port = ?, username = ?, auth_type = ?, updated_at = datetime('now') WHERE id = ?",
						[
							values.name,
							values.hostname,
							values.port,
							values.username,
							values.authType,
							editingHost.id,
						]
					);
				} else {
					hostId = crypto.randomUUID();
					await db.execute(
						"INSERT INTO ssh_hosts (id, name, hostname, port, username, auth_type, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))",
						[
							hostId,
							values.name,
							values.hostname,
							values.port,
							values.username,
							values.authType,
						]
					);
				}

				// Save credentials to Stronghold
				const hasCredentials =
					(values.authType === "password" && values.password) ||
					(values.authType === "key" && values.privateKey);
				if (hasCredentials) {
					await saveCredential(
						hostId,
						values.authType,
						values.password || undefined,
						values.privateKey || undefined,
						values.keyPassphrase || undefined
					);
				}

				setFormOpen(false);
				setEditingHost(undefined);
				setRefreshKey((k) => k + 1);
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
					key={refreshKey}
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
