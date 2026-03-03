import type { SshSessionInfo, SshSessionStatus } from "@/types/ssh";

interface SshStatusBarProps {
	session: SshSessionInfo | null;
}

const STATUS_LABELS: Record<SshSessionStatus, string> = {
	connected: "Connected",
	connecting: "Connecting...",
	disconnected: "Disconnected",
	error: "Error",
};

const STATUS_COLORS: Record<SshSessionStatus, string> = {
	connected: "text-green-500",
	connecting: "text-yellow-500",
	disconnected: "text-red-500",
	error: "text-red-500",
};

export function SshStatusBar({ session }: SshStatusBarProps) {
	return (
		<div className="flex items-center gap-3 border-t bg-muted/30 px-3 py-1 text-muted-foreground text-xs">
			{session ? (
				<>
					<span className={STATUS_COLORS[session.status]}>
						{STATUS_LABELS[session.status]}
					</span>
					<span className="truncate">{session.hostName}</span>
					<span className="ml-auto font-mono">{session.id.slice(0, 8)}</span>
				</>
			) : (
				<span>No active session</span>
			)}
		</div>
	);
}
