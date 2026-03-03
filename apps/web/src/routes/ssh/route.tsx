import { createFileRoute } from "@tanstack/react-router";
import Database from "@tauri-apps/plugin-sql";
import { useCallback, useState } from "react";
import { HostForm } from "@/components/hosts/host-form";
import { HostList } from "@/components/hosts/host-list";
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
	const { sessions, activeSessionId, connect, disconnect, setActive } =
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

	const handleConnectRequest = useCallback((host: SshHost) => {
		setConnectTarget(host);
	}, []);

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
			} catch {
				// Connection error is reflected in session status
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
			name: string;
			port: number;
			username: string;
		}) => {
			try {
				const db = await Database.load("sqlite:caterm.db");
				if (editingHost) {
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
					await db.execute(
						"INSERT INTO ssh_hosts (id, name, hostname, port, username, auth_type, created_at, updated_at) VALUES (lower(hex(randomblob(16))), ?, ?, ?, ?, ?, datetime('now'), datetime('now'))",
						[
							values.name,
							values.hostname,
							values.port,
							values.username,
							values.authType,
						]
					);
				}
				setFormOpen(false);
				setEditingHost(undefined);
				setRefreshKey((k) => k + 1);
			} catch {
				// Handle error silently for now
			}
		},
		[editingHost]
	);

	const handleFormCancel = useCallback(() => {
		setFormOpen(false);
		setEditingHost(undefined);
	}, []);

	return (
		<div className="flex h-full">
			{/* Left sidebar: host list */}
			<div className="w-64 shrink-0 border-r">
				<HostList
					key={refreshKey}
					onConnect={handleConnectRequest}
					onEdit={handleEditHost}
					onNewHost={handleNewHost}
				/>
			</div>

			{/* Right area: tabs + terminals + status bar */}
			<div className="flex min-w-0 flex-1 flex-col">
				<SshTabBar
					activeSessionId={activeSessionId}
					onAddSession={handleNewHost}
					onCloseSession={disconnect}
					onSelectSession={setActive}
					sessions={sessions}
				/>

				{/* Terminal area */}
				<div className="relative flex-1">
					{sessions.size === 0 ? (
						<div className="flex h-full items-center justify-center text-muted-foreground">
							<p>Select a host to connect or add a new one.</p>
						</div>
					) : (
						Array.from(sessions.values()).map((session) => (
							<SshTerminal
								isActive={session.id === activeSessionId}
								key={session.id}
								sessionId={session.id}
							/>
						))
					)}
				</div>

				<SshStatusBar session={activeSession} />
			</div>

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
		</div>
	);
}
