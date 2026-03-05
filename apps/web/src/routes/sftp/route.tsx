import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { SftpProvider } from "@/components/sftp/sftp-provider";
import { authClient } from "@/lib/auth-client";

export const Route = createFileRoute("/sftp")({
	beforeLoad: async () => {
		const session = await authClient.getSession();
		if (!session.data) {
			throw redirect({ to: "/login" });
		}
	},
	component: SftpRouteLayout,
});

function SftpRouteLayout() {
	return (
		<SftpProvider>
			<Outlet />
		</SftpProvider>
	);
}
