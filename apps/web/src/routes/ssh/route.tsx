import { createFileRoute, Outlet } from "@tanstack/react-router";
import { SshSessionProvider } from "@/components/ssh/ssh-session-provider";

export const Route = createFileRoute("/ssh")({
	component: SshRouteLayout,
});

function SshRouteLayout() {
	return (
		<SshSessionProvider>
			<Outlet />
		</SshSessionProvider>
	);
}
