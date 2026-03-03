import { createFileRoute } from "@tanstack/react-router";
import { DownloadIcon, UploadIcon } from "lucide-react";
import { useCallback, useRef } from "react";
import { toast } from "sonner";
import { AppSidebar } from "@/components/app-sidebar";
import { TerminalSettingsForm } from "@/components/settings/terminal-settings-form";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { downloadJson, exportConfig, importConfig } from "@/lib/config-sync";

export const Route = createFileRoute("/ssh/settings")({
	component: SshSettingsPage,
});

function SshSettingsPage() {
	const fileInputRef = useRef<HTMLInputElement>(null);

	const handleExport = useCallback(async () => {
		try {
			const json = await exportConfig();
			const timestamp = new Date().toISOString().slice(0, 10);
			downloadJson(json, `caterm-config-${timestamp}.json`);
			toast.success("Configuration exported");
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			toast.error("Export failed", { description: message });
		}
	}, []);

	const handleImport = useCallback(
		async (e: React.ChangeEvent<HTMLInputElement>) => {
			const file = e.target.files?.[0];
			if (!file) {
				return;
			}
			try {
				const text = await file.text();
				const result = await importConfig(text);
				toast.success(
					`Imported ${result.hostsImported} hosts, ${result.credentialsImported} credentials`
				);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				toast.error("Import failed", { description: message });
			}
			// Reset input so the same file can be imported again
			if (fileInputRef.current) {
				fileInputRef.current.value = "";
			}
		},
		[]
	);

	return (
		<SidebarProvider
			style={
				{
					"--sidebar-width": "calc(var(--spacing) * 72)",
					"--header-height": "calc(var(--spacing) * 12)",
				} as React.CSSProperties
			}
		>
			<AppSidebar variant="inset" />
			<SidebarInset>
				<div className="flex items-center border-b px-4 py-3">
					<h1 className="font-semibold text-lg">Terminal Settings</h1>
				</div>
				<ScrollArea className="flex-1 overflow-hidden">
					<div className="p-6">
						<TerminalSettingsForm />

						<div className="mt-10 max-w-lg border-t pt-6">
							<h2 className="mb-4 font-medium text-base">Configuration Sync</h2>
							<p className="mb-4 text-muted-foreground text-sm">
								Export all hosts, credentials, and settings to a JSON file, or
								import from a previously exported file.
							</p>
							<div className="flex gap-3">
								<Button onClick={handleExport} variant="outline">
									<DownloadIcon />
									Export Config
								</Button>
								<Button
									onClick={() => fileInputRef.current?.click()}
									variant="outline"
								>
									<UploadIcon />
									Import Config
								</Button>
								<input
									accept=".json"
									className="hidden"
									onChange={handleImport}
									ref={fileInputRef}
									type="file"
								/>
							</div>
						</div>
					</div>
				</ScrollArea>
			</SidebarInset>
		</SidebarProvider>
	);
}
