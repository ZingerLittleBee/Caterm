import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/sftp/")({
	component: SftpIndexPage,
});

function SftpIndexPage() {
	return (
		<div className="flex h-screen items-center justify-center">
			<div className="text-center">
				<h1 className="font-bold text-2xl">SFTP File Manager</h1>
				<p className="mt-2 text-muted-foreground">Coming soon</p>
			</div>
		</div>
	);
}
