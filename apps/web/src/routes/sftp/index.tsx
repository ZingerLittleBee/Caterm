import { createFileRoute } from "@tanstack/react-router";
import { SftpFileManager } from "@/components/sftp/sftp-file-manager";

export const Route = createFileRoute("/sftp/")({
	component: SftpIndexPage,
});

function SftpIndexPage() {
	return <SftpFileManager />;
}
