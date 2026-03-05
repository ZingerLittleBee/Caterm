import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { SshSessionProvider } from "@/components/ssh/ssh-session-provider";
import { TerminalSettingsProvider } from "@/components/terminal/terminal-settings-provider";
import { authClient } from "@/lib/auth-client";

export const Route = createFileRoute("/ssh")({
	beforeLoad: async () => {
		const session = await authClient.getSession();
		if (!session.data) {
			throw redirect({ to: "/login" });
		}
	},
	component: SshRouteLayout,
});

function SshRouteLayout() {
	return (
		<TerminalSettingsProvider>
			<SshSessionProvider>
				<Outlet />
			</SshSessionProvider>
		</TerminalSettingsProvider>
	);
}
